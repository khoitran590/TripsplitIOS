-- Server-owned budget settings. Amounts are conservative reserved US cents, not
-- actual provider invoices. Adjust estimates when changing models/token/search caps.
create table public.ai_budget_settings (
 id boolean primary key default true check (id),
 user_daily_cents integer not null default 500 check (user_daily_cents >= 0),
 global_daily_cents integer not null default 10000 check (global_daily_cents >= 0),
 global_monthly_cents integer not null default 100000 check (global_monthly_cents >= 0),
 user_daily_attempts integer not null default 100 check (user_daily_attempts >= 0),
 global_daily_attempts integer not null default 5000 check (global_daily_attempts >= 0),
 user_concurrent integer not null default 2 check (user_concurrent between 1 and 100),
 global_concurrent integer not null default 20 check (global_concurrent between 1 and 1000),
 request_attempts integer not null default 6 check (request_attempts between 1 and 20)
);
insert into public.ai_budget_settings (id) values (true);
create table public.ai_provider_costs (
 kind text not null check (kind in ('ocr','parse','itinerary')),
 provider text not null check (provider in ('vision','claude','gemini')),
 reserved_cents integer not null check (reserved_cents between 1 and 10000),
 primary key (kind, provider)
);
insert into public.ai_provider_costs values
 ('ocr','vision',1), ('parse','claude',25), ('parse','gemini',25),
 ('itinerary','claude',150), ('itinerary','gemini',150);
create table public.ai_provider_attempts (
 id uuid primary key default gen_random_uuid(),
 -- Deliberately no cascading Auth FK: deleting an account cannot reset global spend.
 -- Retain only pseudonymous accounting metadata, never prompts, images, or tokens.
 user_id uuid not null,
 reservation_id uuid not null,
 kind text not null,
 provider text not null,
 model text not null check (length(model) between 1 and 100),
 reserved_cents integer not null check (reserved_cents > 0),
 created_at timestamptz not null default clock_timestamp()
);
create index ai_attempts_time_idx on public.ai_provider_attempts(created_at);
create index ai_attempts_user_time_idx on public.ai_provider_attempts(user_id,created_at);
create index ai_attempts_reservation_idx on public.ai_provider_attempts(reservation_id);
alter table public.ai_budget_settings enable row level security;
alter table public.ai_provider_costs enable row level security;
alter table public.ai_provider_attempts enable row level security;
revoke all on public.ai_budget_settings, public.ai_provider_costs, public.ai_provider_attempts from public, anon, authenticated;
grant select, update on public.ai_budget_settings, public.ai_provider_costs to service_role;
grant select on public.ai_provider_attempts to service_role;

-- Version admission so an old runtime cannot call paid providers without the new
-- per-attempt gate. Deploy the three AI functions together with this migration.
create or replace function public.reserve_ai_usage_v2(
    p_user_id uuid,
    p_kind text,
    p_limit int,
    p_window_seconds int
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_settings public.ai_budget_settings%rowtype;
    v_now timestamptz := clock_timestamp();
    v_active integer;
    v_count int;
    v_id uuid;
    v_retry_after int := 0;
    v_reservation_seconds int;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'Service role required.' using errcode = '42501';
    end if;
    if p_user_id is null
       or p_kind is null or p_kind not in ('ocr', 'parse', 'itinerary')
       or p_limit is null or p_limit < 1 or p_limit > 100
       or p_window_seconds is null or p_window_seconds < 10 or p_window_seconds > 3600 then
        raise exception 'Invalid AI usage reservation arguments' using errcode = '22023';
    end if;

    -- One short transaction serializes admission with global budget permits.
    select * into strict v_settings from public.ai_budget_settings where id for update;
    select count(*) into v_active from public.receipt_scan_events
      where status = 'reserved' and reservation_expires_at > v_now;
    if v_active >= v_settings.global_concurrent or
       (select count(*) from public.receipt_scan_events where user_id = p_user_id
         and status = 'reserved' and reservation_expires_at > v_now) >= v_settings.user_concurrent then
        return jsonb_build_object('allowed', false, 'reason', 'concurrency',
          'feature', p_kind, 'retryAfterSeconds', 30);
    end if;

    v_reservation_seconds := case when p_kind = 'itinerary' then 600 else 180 end;
    perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':' || p_kind, 0));

    delete from public.receipt_scan_events
     where user_id = p_user_id
       and kind = p_kind
       and ((status = 'reserved' and reservation_expires_at <= now())
         or (status = 'succeeded' and coalesce(committed_at, created_at) < now() - interval '30 days'));

    select count(*) into v_count
      from public.receipt_scan_events
     where user_id = p_user_id
       and kind = p_kind
       and ((status = 'succeeded'
             and coalesce(committed_at, created_at) > now() - make_interval(secs => p_window_seconds))
         or (status = 'reserved' and reservation_expires_at > now()));

    if v_count >= p_limit then
        select greatest(1, ceil(extract(epoch from min(
            case
                when status = 'reserved' then reservation_expires_at
                else coalesce(committed_at, created_at) + make_interval(secs => p_window_seconds)
            end
        ) - now()))::int)
          into v_retry_after
          from public.receipt_scan_events
         where user_id = p_user_id
           and kind = p_kind
           and ((status = 'succeeded'
                 and coalesce(committed_at, created_at) > now() - make_interval(secs => p_window_seconds))
             or (status = 'reserved' and reservation_expires_at > now()));

        return jsonb_build_object(
            'allowed', false,
            'feature', p_kind,
            'limit', p_limit,
            'remaining', 0,
            'windowSeconds', p_window_seconds,
            'retryAfterSeconds', coalesce(v_retry_after, 1)
        );
    end if;

    insert into public.receipt_scan_events (
        user_id, kind, status, reservation_expires_at
    ) values (
        p_user_id, p_kind, 'reserved', now() + make_interval(secs => v_reservation_seconds)
    ) returning id into v_id;

    return jsonb_build_object(
        'allowed', true,
        'reservationId', v_id,
        'feature', p_kind,
        'limit', p_limit,
        'remaining', greatest(p_limit - v_count - 1, 0),
        'windowSeconds', p_window_seconds,
        'retryAfterSeconds', 0
    );
end;
$$;

create or replace function public.begin_ai_provider_attempt(p_reservation_id uuid, p_provider text, p_model text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
 v_settings public.ai_budget_settings%rowtype;
 v_request public.receipt_scan_events%rowtype;
 v_cost integer;
 v_now timestamptz;
 v_day timestamptz;
 v_month timestamptz;
 v_user_cost bigint;
 v_day_cost bigint;
 v_month_cost bigint;
 v_user_attempts bigint;
 v_global_attempts bigint;
 v_reason text;
 v_id uuid;
begin
 if auth.role() is distinct from 'service_role' then
  raise exception 'Service role required.' using errcode = '42501';
 end if;
 if p_provider is null or p_provider not in ('claude','gemini','vision')
    or p_model is null or length(p_model) not between 1 and 100 then
  raise exception 'Invalid provider attempt.' using errcode = '22023';
 end if;
 select * into strict v_settings from public.ai_budget_settings where id for update;
 select * into v_request from public.receipt_scan_events where id = p_reservation_id for update;
 v_now := clock_timestamp();
 v_day := date_trunc('day', v_now at time zone 'UTC') at time zone 'UTC';
 v_month := date_trunc('month', v_now at time zone 'UTC') at time zone 'UTC';
 if not found or v_request.status <> 'reserved' or v_request.reservation_expires_at <= v_now then
  return jsonb_build_object('allowed',false,'reason','expired_reservation','retryAfterSeconds',1);
 end if;
 select reserved_cents into v_cost from public.ai_provider_costs
  where kind = v_request.kind and provider = p_provider;
 if v_cost is null then
  return jsonb_build_object('allowed',false,'reason','unconfigured_provider','retryAfterSeconds',60);
 end if;
 if (select count(*) from public.ai_provider_attempts where reservation_id = p_reservation_id) >= v_settings.request_attempts then
  return jsonb_build_object('allowed',false,'reason','request_attempts','retryAfterSeconds',60);
 end if;
 select coalesce(sum(reserved_cents) filter (where user_id = v_request.user_id and created_at >= v_day),0),
        coalesce(sum(reserved_cents) filter (where created_at >= v_day),0),
        coalesce(sum(reserved_cents),0),
        count(*) filter (where user_id = v_request.user_id and created_at >= v_day),
        count(*) filter (where created_at >= v_day)
 into v_user_cost,v_day_cost,v_month_cost,v_user_attempts,v_global_attempts
 from public.ai_provider_attempts where created_at >= v_month;
 v_reason := case
  when v_user_cost + v_cost > v_settings.user_daily_cents then 'user_daily_budget'
  when v_day_cost + v_cost > v_settings.global_daily_cents then 'global_daily_budget'
  when v_month_cost + v_cost > v_settings.global_monthly_cents then 'global_monthly_budget'
  when v_user_attempts >= v_settings.user_daily_attempts then 'user_daily_attempts'
  when v_global_attempts >= v_settings.global_daily_attempts then 'global_daily_attempts'
 end;
 if v_reason is not null then
  return jsonb_build_object('allowed',false,'reason',v_reason,'retryAfterSeconds',
   greatest(1,ceil(extract(epoch from
    ((case when v_reason = 'global_monthly_budget' then v_month + interval '1 month'
      else v_day + interval '1 day' end) - v_now)))::integer));
 end if;
 insert into public.ai_provider_attempts(user_id,reservation_id,kind,provider,model,reserved_cents)
 values(v_request.user_id,p_reservation_id,v_request.kind,p_provider,p_model,v_cost) returning id into v_id;
 -- A provider permit permanently charges the daily ledger even on timeout/crash.
 return jsonb_build_object('allowed',true,'attemptId',v_id,'reservedCents',v_cost,
  'budgetWarning', case when v_day_cost + v_cost >= v_settings.global_daily_cents * 0.8
    or v_month_cost + v_cost >= v_settings.global_monthly_cents * 0.8 then 'global_budget_near_limit' end);
end;
$$;

-- Completion releases concurrency but never refunds paid permits, including explicit
-- failure completion by older runtimes. The ledger is independent of request rows.
revoke all on function public.begin_ai_provider_attempt(uuid,text,text) from public,anon,authenticated;
grant execute on function public.begin_ai_provider_attempt(uuid,text,text) to service_role;
revoke all on function public.reserve_ai_usage_v2(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.reserve_ai_usage_v2(uuid,text,integer,integer) to service_role;

-- Protect EVERY invitation insertion, including legacy RPCs. A row counter rather
-- than a snapshot/count query makes admission atomic under concurrent transactions.
create table public.invitation_rate_counters (
 actor_id uuid primary key references auth.users(id) on delete cascade,
 recent_attempts timestamptz[] not null default '{}'
);
alter table public.invitation_rate_counters enable row level security;
revoke all on public.invitation_rate_counters from public,anon,authenticated;
insert into public.invitation_rate_counters(actor_id,recent_attempts)
 select invited_by,array_agg(created_at order by created_at)
 from public.trip_invitations where created_at > now() - interval '1 hour' group by invited_by;
create or replace function public.enforce_invitation_quota()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_count integer;
begin
 insert into public.invitation_rate_counters(actor_id) values(new.invited_by) on conflict do nothing;
 -- Lock first, then trim/append from the latest locked tuple (including concurrent
 -- commits). Failed/deleted invitations never refund successful insert admissions.
 perform 1 from public.invitation_rate_counters where actor_id = new.invited_by for update;
 update public.invitation_rate_counters set recent_attempts =
  array(select t from unnest(recent_attempts) t where t > clock_timestamp() - interval '1 hour')
  where actor_id = new.invited_by;
 select cardinality(recent_attempts) into v_count from public.invitation_rate_counters where actor_id = new.invited_by;
 if v_count >= 30 then raise exception 'Invitation limit reached. Try again later.' using errcode = 'P0001'; end if;
 update public.invitation_rate_counters set recent_attempts = array_append(recent_attempts,clock_timestamp())
  where actor_id = new.invited_by;
 return new;
end;
$$;
create trigger enforce_invitation_quota_trigger before insert on public.trip_invitations
 for each row execute function public.enforce_invitation_quota();
revoke all on function public.enforce_invitation_quota() from public,anon,authenticated;

-- Storage metadata is not available until after the upload starts. Reserve the full
-- bucket object maximum for missing sizes, then settle to bounded actual metadata.
-- Atomic counters cover INSERT, upsert/UPDATE, DELETE and orphan objects equally.
create table public.storage_quota_counters (
 owner_prefix text primary key,
 object_count bigint not null check(object_count >= 0),
 allocated_bytes bigint not null check(allocated_bytes >= 0)
);
alter table public.storage_quota_counters enable row level security;
revoke all on public.storage_quota_counters from public,anon,authenticated;
insert into public.storage_quota_counters
 select split_part(name,'/',1),count(*),sum(coalesce((metadata->>'size')::bigint,5000000))
 from storage.objects where bucket_id = 'receipts' group by split_part(name,'/',1);
create or replace function public.enforce_storage_quota()
returns trigger language plpgsql security definer set search_path = public, storage, pg_temp
as $$
declare
 v_prefix text;
 v_old_size bigint := 0;
 v_new_size bigint := 0;
 v_count_delta integer := 0;
 v_bytes_delta bigint;
 v_count bigint;
 v_bytes bigint;
begin
 if tg_op <> 'INSERT' and old.bucket_id = 'receipts' then
  v_prefix := split_part(old.name,'/',1);
  v_old_size := coalesce((old.metadata->>'size')::bigint,5000000);
  v_count_delta := -1;
 end if;
 if tg_op <> 'DELETE' and new.bucket_id = 'receipts' then
  if v_prefix is not null and v_prefix <> split_part(new.name,'/',1) then
   raise exception 'Storage owner prefix is immutable.' using errcode = '42501';
  end if;
  v_prefix := split_part(new.name,'/',1);
  v_new_size := coalesce((new.metadata->>'size')::bigint,5000000);
  if v_new_size < 0 or v_new_size > 5000000 then
   raise exception 'Storage object size is invalid.' using errcode = '22023';
  end if;
  v_count_delta := v_count_delta + 1;
 end if;
 if v_prefix is null then
  if tg_op = 'DELETE' then return old; else return new; end if;
 end if;
 v_bytes_delta := v_new_size - v_old_size;
 insert into public.storage_quota_counters values(v_prefix,0,0) on conflict do nothing;
 update public.storage_quota_counters
 set object_count = object_count + v_count_delta, allocated_bytes = allocated_bytes + v_bytes_delta
 where owner_prefix = v_prefix
 returning object_count,allocated_bytes into v_count,v_bytes;
 if (v_count_delta > 0 and v_count > 250) or (v_bytes_delta > 0 and v_bytes > 500000000) then
  raise exception 'Storage quota exceeded.' using errcode = 'P0001';
 end if;
 if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
create trigger enforce_storage_quota_trigger after insert or update or delete on storage.objects
 for each row execute function public.enforce_storage_quota();
revoke all on function public.enforce_storage_quota() from public,anon,authenticated;

-- Authorization remains in RLS; aggregate admission is now the atomic trigger above.
create or replace function public.can_upload_storage_object(p_bucket_id text,p_name text)
returns boolean language sql stable security definer set search_path = public, storage, pg_temp
as $$
 select auth.uid() is not null and p_bucket_id = 'receipts'
  and auth.uid()::text = (storage.foldername(p_name))[1];
$$;

-- Fail closed during deployment: old function versions must upgrade before spending.
create or replace function public.reserve_ai_usage(p_user_id uuid,p_kind text,p_limit integer,p_window_seconds integer)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select jsonb_build_object('allowed',false,'reason','function_upgrade_required','retryAfterSeconds',60); $$;
revoke all on function public.reserve_ai_usage(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.reserve_ai_usage(uuid,text,integer,integer) to service_role;
;

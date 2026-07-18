-- Track D: fair, success-charged AI usage limits.
-- Deploy ocr-receipt, parse-receipt, and suggest-itinerary immediately after applying.

alter table public.receipt_scan_events add column if not exists kind text not null default 'unknown';
alter table public.receipt_scan_events add column if not exists status text not null default 'succeeded';
alter table public.receipt_scan_events add column if not exists committed_at timestamptz;
alter table public.receipt_scan_events add column if not exists reservation_expires_at timestamptz;

update public.receipt_scan_events
   set committed_at = created_at
 where status = 'succeeded' and committed_at is null;

do $$
begin
    if not exists (
        select 1 from pg_constraint
         where conrelid = 'public.receipt_scan_events'::regclass
           and conname = 'receipt_scan_events_kind_check'
    ) then
        alter table public.receipt_scan_events
            add constraint receipt_scan_events_kind_check
            check (kind in ('unknown', 'receipt', 'ocr', 'parse', 'itinerary'));
    end if;
    if not exists (
        select 1 from pg_constraint
         where conrelid = 'public.receipt_scan_events'::regclass
           and conname = 'receipt_scan_events_status_check'
    ) then
        alter table public.receipt_scan_events
            add constraint receipt_scan_events_status_check
            check (status in ('reserved', 'succeeded'));
    end if;
end;
$$;

drop index if exists public.receipt_scan_events_user_time_idx;
create index if not exists receipt_scan_events_user_kind_time_idx
    on public.receipt_scan_events (user_id, kind, committed_at desc, created_at desc);

alter table public.receipt_scan_events enable row level security;

create or replace function public.reserve_ai_usage(
    p_user_id uuid,
    p_kind text,
    p_limit int,
    p_window_seconds int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_count int;
    v_id uuid;
    v_retry_after int := 0;
    v_reservation_seconds int;
begin
    if p_user_id is null
       or p_kind not in ('ocr', 'parse', 'itinerary')
       or p_limit < 1 or p_limit > 100
       or p_window_seconds < 10 or p_window_seconds > 3600 then
        raise exception 'Invalid AI usage reservation arguments' using errcode = '22023';
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

create or replace function public.complete_ai_usage(
    p_reservation_id uuid,
    p_succeeded boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_status text;
begin
    select status into v_status
      from public.receipt_scan_events
     where id = p_reservation_id
     for update;

    if v_status is distinct from 'reserved' then
        return false;
    end if;

    if p_succeeded then
        update public.receipt_scan_events
           set status = 'succeeded', committed_at = now(), reservation_expires_at = null
         where id = p_reservation_id;
    else
        delete from public.receipt_scan_events where id = p_reservation_id;
    end if;
    return true;
end;
$$;

drop function if exists public.record_receipt_scan(int, int);
revoke all on function public.reserve_ai_usage(uuid, text, int, int) from public, anon, authenticated;
revoke all on function public.complete_ai_usage(uuid, boolean) from public, anon, authenticated;
grant execute on function public.reserve_ai_usage(uuid, text, int, int) to service_role;
grant execute on function public.complete_ai_usage(uuid, boolean) to service_role;

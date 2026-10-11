-- First-party onboarding measurement. No names, trip IDs, amounts or freeform metadata.
create table public.onboarding_events (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    event text not null check (event in ('setup_started','setup_completed','setup_skipped','setup_deferred','guide_opened','guide_topic_opened','guide_topic_completed','guide_action','guide_dismissed','return_dismissed','return_resumed','first_expense_saved','invitation_accepted')),
    guide_version integer not null check (guide_version between 1 and 100),
    source text not null check (source in ('setup','guide','return','trip')),
    topic text check (topic in ('trips','expenses','balances','practice','createTrip','openTrip','addExpense','members')),
    occurred_at timestamptz not null,
    received_at timestamptz not null default now(),
    elapsed_seconds integer check (elapsed_seconds between 0 and 7776000)
);
alter table public.onboarding_events enable row level security;
revoke all on public.onboarding_events from public, anon, authenticated;
grant all on public.onboarding_events to service_role;
create index onboarding_events_time on public.onboarding_events(occurred_at);
create index onboarding_events_user on public.onboarding_events(user_id);
create unique index onboarding_first_expense on public.onboarding_events(user_id) where event = 'first_expense_saved';
create unique index onboarding_setup_start on public.onboarding_events(user_id, guide_version) where event = 'setup_started';

-- Only this narrow RPC can write; the server supplies the authenticated identity.
create function public.record_onboarding_events_v1(p_events jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare entry jsonb; identity uuid := auth.uid();
begin
    if identity is null then raise exception 'Authentication required' using errcode = '42501'; end if;
    if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 50 then
        raise exception 'Expected at most 50 events' using errcode = '22023';
    end if;
    for entry in select value from jsonb_array_elements(p_events) loop
        if jsonb_typeof(entry) <> 'object' or exists (
            select 1 from jsonb_object_keys(entry) k
            where k not in ('id','event','guide_version','source','topic','occurred_at','elapsed_seconds')
        ) then raise exception 'Unsupported event fields' using errcode = '22023'; end if;
        if (entry->>'occurred_at')::timestamptz not between now() - interval '90 days' and now() + interval '5 minutes' then
            raise exception 'Event time outside retention window' using errcode = '22023';
        end if;
        insert into public.onboarding_events(id,user_id,event,guide_version,source,topic,occurred_at,elapsed_seconds)
        values ((entry->>'id')::uuid, identity, entry->>'event', (entry->>'guide_version')::integer,
                entry->>'source', entry->>'topic', (entry->>'occurred_at')::timestamptz, (entry->>'elapsed_seconds')::integer)
        on conflict do nothing;
    end loop;
end;
$$;
revoke all on function public.record_onboarding_events_v1(jsonb) from public, anon;
grant execute on function public.record_onboarding_events_v1(jsonb) to authenticated;

-- Aggregate access is restricted to administrators/service-role tooling.
-- Activation means a first real expense, independent of setup or guide completion.
create function public.onboarding_metrics_v1(p_since timestamptz default now() - interval '30 days')
returns jsonb language sql stable security definer set search_path = '' as $$
with events as (
    select event, guide_version, source, topic, count(*) as event_count,
           count(distinct user_id) as users,
           percentile_cont(0.5) within group (order by elapsed_seconds) as median_seconds,
           percentile_cont(0.9) within group (order by elapsed_seconds) as p90_seconds
    from public.onboarding_events where occurred_at >= p_since
    group by event, guide_version, source, topic
), cohorts as (
    select s.guide_version, count(*) as started_users,
           count(a.user_id) as activated_users,
           percentile_cont(0.5) within group (order by a.elapsed_seconds) as median_time_to_first_expense_seconds,
           percentile_cont(0.9) within group (order by a.elapsed_seconds) as p90_time_to_first_expense_seconds
    from public.onboarding_events s left join public.onboarding_events a
      on a.user_id = s.user_id and a.event = 'first_expense_saved' and a.occurred_at >= s.occurred_at
    where s.event = 'setup_started' and s.occurred_at >= p_since group by s.guide_version
)
select jsonb_build_object('since', p_since,
    'events', coalesce((select jsonb_agg(to_jsonb(events)) from events), '[]'::jsonb),
    'activation_cohorts', coalesce((select jsonb_agg(to_jsonb(cohorts)) from cohorts), '[]'::jsonb));
$$;
revoke all on function public.onboarding_metrics_v1(timestamptz) from public, anon, authenticated;
grant execute on function public.onboarding_metrics_v1(timestamptz) to service_role;
notify pgrst, 'reload schema';

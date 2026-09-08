-- Small membership-scoped manifest pages let clients reuse unchanged complete
-- snapshots. UUID pagination is stable when updated_at changes during a refresh.
create or replace function public.fetch_trip_summaries_v1(p_after_id uuid default null, p_limit integer default 100)
returns table(id uuid, updated_at timestamptz, name text, currency_code text)
language sql stable security definer set search_path = public
as $$
    select t.id, t.updated_at, t.name, t.currency_code
    from public.trip_members tm join public.trips t on t.id = tm.trip_id
    where tm.user_id = (select auth.uid()) and (p_after_id is null or t.id > p_after_id)
    order by t.id
    limit least(greatest(coalesce(p_limit, 100), 1), 100);
$$;

create or replace function public.fetch_trip_details_v1(p_ids uuid[])
returns table(id uuid, data jsonb, updated_at timestamptz)
language sql stable security definer set search_path = public
as $$
    select t.id, public.trip_document(t.id), t.updated_at
    from public.trip_members tm join public.trips t on t.id = tm.trip_id
    where tm.user_id = (select auth.uid())
      and t.id = any(p_ids[1:25])
    order by t.id;
$$;

revoke all on function public.fetch_trip_summaries_v1(uuid, integer) from public, anon;
revoke all on function public.fetch_trip_details_v1(uuid[]) from public, anon;
grant execute on function public.fetch_trip_summaries_v1(uuid, integer) to authenticated;
grant execute on function public.fetch_trip_details_v1(uuid[]) to authenticated;

-- The feed cursor includes id to make equal-timestamp pages deterministic.
create index if not exists trip_feed_posts_trip_created_id_idx
    on public.trip_feed_posts (trip_id, created_at desc, id desc);
-- The new index covers the old two-column prefix as well.
drop index if exists public.trip_feed_posts_trip_created_idx;

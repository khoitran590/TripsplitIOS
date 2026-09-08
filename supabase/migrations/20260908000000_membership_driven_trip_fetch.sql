-- Start with the caller's memberships (indexed by user_id) instead of invoking a
-- PL/pgSQL membership check for every trip in the database. The composite primary
-- key guarantees one result per trip; trip_document still reads normalized rows.
create or replace function public.fetch_normalized_trips()
returns table(data jsonb, updated_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
    select public.trip_document(t.id), t.updated_at
    from public.trip_members tm
    join public.trips t on t.id = tm.trip_id
    where tm.user_id = (select auth.uid())
    order by t.updated_at desc;
$$;

revoke all on function public.fetch_normalized_trips() from public, anon;
grant execute on function public.fetch_normalized_trips() to authenticated;

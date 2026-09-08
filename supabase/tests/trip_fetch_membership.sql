-- Transactional fixtures: no persistent users or trips. Run with `supabase test db`.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, email) values
    ('a1000000-0000-0000-0000-000000000001', 'trip-fetch-owner@example.com'),
    ('a1000000-0000-0000-0000-000000000002', 'trip-fetch-member@example.com'),
    ('a1000000-0000-0000-0000-000000000003', 'trip-fetch-outsider@example.com');

select set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-0000-0000-000000000001","role":"service_role"}', true);
insert into public.trips (id, user_id, data, metadata, updated_at) values
    ('b1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', '{}',
     '{"id":"b1000000-0000-0000-0000-000000000001"}', '2026-09-01'),
    ('b1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', '{}',
     '{"id":"b1000000-0000-0000-0000-000000000002"}', '2026-09-02');

select set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-0000-0000-000000000003","role":"service_role"}', true);
insert into public.trips (id, user_id, data, metadata) values
    ('b1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000003', '{}',
     '{"id":"b1000000-0000-0000-0000-000000000003"}');
insert into public.trip_members (trip_id, user_id) values
    ('b1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002');

-- Membership side effects update the parent timestamp during setup. Give the
-- ordering fixture distinct timestamps after all memberships have been inserted.
alter table public.trips disable trigger trips_set_updated_at;
update public.trips set updated_at = case id
    when 'b1000000-0000-0000-0000-000000000001'::uuid then '2026-09-01'::timestamptz
    else '2026-09-02'::timestamptz end
where id in ('b1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002');
alter table public.trips enable trigger trips_set_updated_at;

select set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select results_eq(
    $$select data->>'id' from public.fetch_normalized_trips()$$,
    $$values ('b1000000-0000-0000-0000-000000000002'::text),
             ('b1000000-0000-0000-0000-000000000001'::text)$$,
    'owner sees only owned memberships, newest first without duplicates');
select is((select data->'expenses' from public.fetch_normalized_trips() limit 1), '[]'::jsonb,
    'fetch reconstructs normalized children instead of returning the stale data blob');

select results_eq(
    $$select id::text from public.fetch_trip_summaries_v1(null, 1)$$,
    $$values ('b1000000-0000-0000-0000-000000000001'::text)$$,
    'summary page respects its size');
select results_eq(
    $$select id::text from public.fetch_trip_summaries_v1('b1000000-0000-0000-0000-000000000001', 1)$$,
    $$values ('b1000000-0000-0000-0000-000000000002'::text)$$,
    'summary cursor advances without duplicates');
select is((select count(*) from public.fetch_trip_summaries_v1('b1000000-0000-0000-0000-000000000002', 100)),
    0::bigint, 'last summary page excludes unrelated trips');
select results_eq(
    $$select id::text from public.fetch_trip_details_v1(array[
        'b1000000-0000-0000-0000-000000000001'::uuid, 'b1000000-0000-0000-0000-000000000003'::uuid])$$,
    $$values ('b1000000-0000-0000-0000-000000000001'::text)$$,
    'detail batch cannot expose a non-member trip');

select set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select results_eq(
    $$select data->>'id' from public.fetch_normalized_trips()$$,
    $$values ('b1000000-0000-0000-0000-000000000001'::text)$$,
    'invited member sees only their shared trip');

select is((select count(*) from public.fetch_trip_summaries_v1()), 1::bigint,
    'member summary scope matches full-trip scope');
reset role;
delete from public.trip_members
where user_id = 'a1000000-0000-0000-0000-000000000002';
set local role authenticated;
select is((select count(*) from public.fetch_normalized_trips()), 0::bigint,
    'removed member cannot read the trip');

select set_config('request.jwt.claims',
    '{"sub":"a1000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select results_eq(
    $$select data->>'id' from public.fetch_normalized_trips()$$,
    $$values ('b1000000-0000-0000-0000-000000000003'::text)$$,
    'unrelated account sees only its own trip');

select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select is((select count(*) from public.fetch_normalized_trips()), 0::bigint,
    'missing identity returns no trips');
reset role;
select ok(not has_function_privilege('anon', 'public.fetch_normalized_trips()', 'EXECUTE'),
    'anonymous callers cannot execute the function');
select ok(not has_function_privilege('anon', 'public.fetch_trip_details_v1(uuid[])', 'EXECUTE'),
    'anonymous callers cannot execute detail reads');
select * from finish();
rollback;

begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

insert into auth.users (id, email) values
    ('a2000000-0000-0000-0000-000000000001', 'delta-owner@example.com'),
    ('a2000000-0000-0000-0000-000000000002', 'delta-member@example.com'),
    ('a2000000-0000-0000-0000-000000000003', 'delta-outsider@example.com');

create function pg_temp.expense(p_id text, p_payer text, p_amount integer) returns jsonb language sql as $$
    select jsonb_build_object('id', p_id, 'title', 'Test meal', 'amount', p_amount,
        'payerID', p_payer, 'date', '2026-09-01T12:00:00Z',
        'participantIDs', jsonb_build_array(p_payer));
$$;
create function pg_temp.save(p_delta jsonb) returns void language sql as $$
    select public.sync_trip_delta_v1('b2000000-0000-0000-0000-000000000001',
        'a2000000-0000-0000-0000-000000000001', p_delta);
$$;

select set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok($$select pg_temp.save(jsonb_build_object('metadata', jsonb_build_object(
    'id', 'b2000000-0000-0000-0000-000000000001', 'name', 'Delta trip', 'currencyCode', 'USD',
    'creatorID', 'a2000000-0000-0000-0000-000000000001',
    'members', '[{"id":"a2000000-0000-0000-0000-000000000001"},{"id":"a2000000-0000-0000-0000-000000000002"},{"id":"a2000000-0000-0000-0000-000000000004"}]'::jsonb),
    'expenses', jsonb_build_array(pg_temp.expense('c2000000-0000-0000-0000-000000000001',
        'a2000000-0000-0000-0000-000000000001', 10))))$$, 'delta creates a trip and expense');
reset role;
select is((select count(*) from public.trip_expenses where trip_id = 'b2000000-0000-0000-0000-000000000001'),
    1::bigint, 'first expense persisted');
set local role authenticated;
reset role;
insert into public.trip_members (trip_id, user_id) values
    ('b2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002');

select set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
set local role authenticated;
select lives_ok($$select pg_temp.save(jsonb_build_object('expenses', jsonb_build_array(pg_temp.expense(
    'c2000000-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000002', 20))))$$,
    'member adds their own expense without resending metadata');
select throws_ok($$select pg_temp.save(jsonb_build_object('expenses', jsonb_build_array(pg_temp.expense(
    'c2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 99))))$$,
    '42501', null, 'member cannot edit the owner expense');
select throws_ok($$select pg_temp.save('{"removedExpenses":["c2000000-0000-0000-0000-000000000001"]}')$$,
    '42501', null, 'member cannot delete the owner expense');

select set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok($$select pg_temp.save(jsonb_build_object('expenses', jsonb_build_array(pg_temp.expense(
    'c2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 15))))$$,
    'owner saves a stale client delta');
reset role;
select is((select amount from public.trip_expenses where id = 'c2000000-0000-0000-0000-000000000002'),
    20::double precision, 'unseen concurrent member expense survives');
set local role authenticated;
reset role;
select is((select name from public.trips where id = 'b2000000-0000-0000-0000-000000000001'),
    'Delta trip', 'omitted metadata stays unchanged');
set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000002->a2000000-0000-0000-0000-000000000001":[
    {"id":"e2000000-0000-0000-0000-000000000001","amount":12,"method":"Cash","note":"Paid","status":"pending","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'debtor creates a pending settlement');
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000002->a2000000-0000-0000-0000-000000000001":[
    {"id":"e2000000-0000-0000-0000-000000000001","amount":12,"method":"Cash","note":"Changed on retry","status":"pending","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'retrying a pending settlement is idempotent');
reset role;
select is((select payload->>'note' from public.settlement_records where id = 'e2000000-0000-0000-0000-000000000001'),
    'Paid', 'a same-state retry cannot change settlement details');

set local role authenticated;
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000002->a2000000-0000-0000-0000-000000000004":[
    {"id":"e2000000-0000-0000-0000-000000000005","amount":6,"method":"Cash App","note":"Guest is offline","status":"pending","selfApproved":false,"date":"2026-09-01T12:00:00Z"}]}}')$$,
    'debtor records a payment for an unavailable creditor');
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000002->a2000000-0000-0000-0000-000000000004":[
    {"id":"e2000000-0000-0000-0000-000000000005","amount":6,"method":"Cash App","note":"Guest is offline","status":"confirmed","selfApproved":true,"date":"2026-09-01T12:00:00Z"}]}}')$$,
    'debtor explicitly self-approves after group agreement');
reset role;
select is((select payload->>'selfApprovedBy' from public.settlement_records where id = 'e2000000-0000-0000-0000-000000000005'),
    'a2000000-0000-0000-0000-000000000002', 'self-approval records debtor provenance');

select set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000002->a2000000-0000-0000-0000-000000000001":[
    {"id":"e2000000-0000-0000-0000-000000000001","amount":12,"method":"Cash","note":"Paid","status":"confirmed","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'creditor confirms a pending settlement');
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000002->a2000000-0000-0000-0000-000000000001":[
    {"id":"e2000000-0000-0000-0000-000000000001","amount":12,"method":"Cash","note":"Paid","status":"confirmed","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'retrying a confirmed settlement is idempotent');
reset role;
select is((select status from public.settlement_records where id = 'e2000000-0000-0000-0000-000000000001'),
    'confirmed', 'confirmed settlement persists');

set local role authenticated;
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000004->a2000000-0000-0000-0000-000000000001":[
    {"id":"e2000000-0000-0000-0000-000000000002","amount":8,"method":"Venmo","note":"Guest paid owner","status":"confirmed","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'creditor records payment from a manual tripmate');
select lives_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000001->a2000000-0000-0000-0000-000000000004":[
    {"id":"e2000000-0000-0000-0000-000000000003","amount":7,"method":"PayPal","note":"Owner paid guest","status":"pending","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'debtor records payment to a manual tripmate');
reset role;
select is((select count(*) from public.settlement_records where trip_id = 'b2000000-0000-0000-0000-000000000001'),
    4::bigint, 'account-backed, manual-tripmate, and self-approved settlements persist together');
set local role authenticated;

select lives_ok($$select pg_temp.save('{"comments":{"c2000000-0000-0000-0000-000000000001":[
    {"id":"d2000000-0000-0000-0000-000000000001","authorID":"a2000000-0000-0000-0000-000000000001","text":"Hello","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'comment delta is accepted');
select lives_ok($$select pg_temp.save('{"comments":{"c2000000-0000-0000-0000-000000000001":[
    {"id":"d2000000-0000-0000-0000-000000000001","authorID":"a2000000-0000-0000-0000-000000000001","text":"Edited","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'comment update uses existing identity checks');
reset role;
select is((select payload->>'text' from public.expense_comments where id = 'd2000000-0000-0000-0000-000000000001'),
    'Edited', 'comment update persists');
set local role authenticated;
select lives_ok($$select pg_temp.save('{"removedComments":["D2000000-0000-0000-0000-000000000001"]}')$$,
    'uppercase UUID tombstone removes the requested comment');
reset role;
select is((select count(*) from public.expense_comments where trip_id = 'b2000000-0000-0000-0000-000000000001'),
    0::bigint, 'comment was removed');
set local role authenticated;
select lives_ok($$select pg_temp.save('{"removedExpenses":["C2000000-0000-0000-0000-000000000001"]}')$$,
    'owner can remove an expense explicitly');
reset role;
select is((select count(*) from public.trip_expenses where trip_id = 'b2000000-0000-0000-0000-000000000001'),
    1::bigint, 'only the explicitly removed expense is deleted');
set local role authenticated;

select lives_ok($$select public.sync_trip_normalized('b2000000-0000-0000-0000-000000000001',
    'a2000000-0000-0000-0000-000000000001', data, data) from public.fetch_normalized_trips()
    where data->>'id' = 'b2000000-0000-0000-0000-000000000001'$$,
    'legacy full-snapshot RPC still accepts unchanged snapshots');

select set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok($$select pg_temp.save('{"settlements":{"a2000000-0000-0000-0000-000000000003->a2000000-0000-0000-0000-000000000001":[
    {"id":"e2000000-0000-0000-0000-000000000004","amount":5,"method":"Cash","note":"Invalid","status":"pending","date":"2026-09-01T12:00:00Z"}]}}')$$,
    'P0001', 'You are not a member of this trip.', 'outsider cannot create a settlement');
select throws_ok($$select pg_temp.save('{}')$$, 'P0001', 'You are not a member of this trip.', 'outsider cannot sync a trip');
select throws_ok($$select public.sync_trip_delta_v1('b2000000-0000-0000-0000-000000000099',
    'a2000000-0000-0000-0000-000000000003', '{}')$$, 'P0001',
    'A new trip requires its owner and metadata.', 'missing metadata cannot create a partial trip');
reset role;
select ok(not has_function_privilege('anon', 'public.sync_trip_delta_v1(uuid,uuid,jsonb)', 'EXECUTE'),
    'anonymous callers cannot execute delta sync');
select * from finish();
rollback;

-- Safe to run on the linked database: all fixtures and writes are rolled back.
begin;
insert into auth.users(id,email) values ('a6101000-0000-0000-0000-000000000001','onboarding-verification@example.invalid');
select set_config('request.jwt.claims','{"sub":"a6101000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.record_onboarding_events_v1(jsonb_build_array(jsonb_build_object(
 'id','b6101000-0000-0000-0000-000000000001','event','setup_started','guide_version',1,'source','setup','occurred_at',now())));
select public.record_onboarding_events_v1(jsonb_build_array(jsonb_build_object(
 'id','b6101000-0000-0000-0000-000000000001','event','setup_started','guide_version',1,'source','setup','occurred_at',now())));
select public.record_onboarding_events_v1(jsonb_build_array(jsonb_build_object(
 'id','b6101000-0000-0000-0000-000000000002','event','first_expense_saved','guide_version',1,'source','trip','occurred_at',now(),'elapsed_seconds',60)));
select public.record_onboarding_events_v1(jsonb_build_array(jsonb_build_object(
 'id','b6101000-0000-0000-0000-000000000003','event','first_expense_saved','guide_version',1,'source','trip','occurred_at',now(),'elapsed_seconds',61)));
do $$ begin
 begin
  perform * from public.onboarding_events;
  raise exception 'FAIL: client can read events';
 exception when insufficient_privilege then null; end;
 begin
  perform public.onboarding_metrics_v1();
  raise exception 'FAIL: client can read shared aggregates';
 exception when insufficient_privilege then null; end;
 begin
  perform public.record_onboarding_events_v1(jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'event','guide_opened','guide_version',1,'source','guide','occurred_at',now(),'user_id',gen_random_uuid())));
  raise exception 'FAIL: caller can provide identity';
 exception when invalid_parameter_value then null; end;
 begin
  perform public.record_onboarding_events_v1(jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'event','arbitrary_data','guide_version',1,'source','guide','occurred_at',now())));
  raise exception 'FAIL: arbitrary event accepted';
 exception when check_violation then null; end;
end $$;
reset role;
do $$ begin
 if (select count(*) from public.onboarding_events where user_id='a6101000-0000-0000-0000-000000000001') <> 2 then raise exception 'FAIL: replay or milestone deduplication'; end if;
 if exists(select 1 from public.onboarding_events where id='b6101000-0000-0000-0000-000000000001' and user_id <> 'a6101000-0000-0000-0000-000000000001') then raise exception 'FAIL: incorrect server identity'; end if;
 if not (public.onboarding_metrics_v1(now()-interval '1 minute')->'activation_cohorts') @> '[{"guide_version":1}]'::jsonb then raise exception 'FAIL: no activation cohort'; end if;
end $$;
set local role anon;
do $$ begin
 begin
  perform public.record_onboarding_events_v1('[]');
  raise exception 'FAIL: anonymous event writer';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
delete from auth.users where id='a6101000-0000-0000-0000-000000000001';
do $$ begin
 if exists(select 1 from public.onboarding_events where user_id='a6101000-0000-0000-0000-000000000001') then raise exception 'FAIL: account deletion leaves events'; end if;
end $$;
rollback;
select 'Passed: identity, replay, milestone deduplication, private reads, private aggregates, field validation, anonymous denial, deletion cascade; fixtures rolled back' as verification;

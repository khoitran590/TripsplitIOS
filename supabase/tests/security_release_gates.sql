-- Structural release-gate regression tests. Run with `supabase test db` after a clean
-- local reset. Behavioral multi-user fixtures remain a required staging test because
-- they exercise JWT/RLS identities and Storage signing end to end.

begin;

create extension if not exists pgtap with schema extensions;
select plan(28);

select has_table('public', 'financial_audit_events', 'financial audit table exists');
select has_table('public', 'storage_attachments', 'storage attachment ACL table exists');
select has_table('public', 'ai_processing_consents', 'AI consent receipts exist');
select has_table('public', 'user_blocks', 'user block table exists');
select has_table('public', 'content_reports', 'protected report queue exists');
select has_table('public', 'trip_removed_members', 'removed-member capability tombstones exist');

select col_not_null('public', 'trip_expenses', 'created_by', 'expense creator is immutable/non-null');
select col_not_null('public', 'settlement_records', 'created_by', 'settlement creator is immutable/non-null');
select col_not_null('public', 'expense_comments', 'created_by', 'comment creator is immutable/non-null');

select ok(not has_table_privilege('authenticated', 'public.trip_expenses', 'INSERT'),
          'authenticated cannot insert expenses directly');
select ok(not has_table_privilege('authenticated', 'public.settlement_records', 'UPDATE'),
          'authenticated cannot update settlements directly');
select ok(not has_table_privilege('authenticated', 'public.expense_comments', 'DELETE'),
          'authenticated cannot delete comments directly');

select is((select count(*)::integer from pg_policies
           where schemaname = 'public' and tablename = 'trip_expenses'
             and policyname = 'Trip members can write expenses'), 0,
          'legacy broad expense policy is absent');
select is((select count(*)::integer from pg_policies
           where schemaname = 'public' and tablename = 'settlement_records'
             and policyname = 'Trip members can write settlements'), 0,
          'legacy broad settlement policy is absent');
select is((select count(*)::integer from pg_policies
           where schemaname = 'public' and tablename = 'expense_comments'
             and policyname = 'Trip members can write expense comments'), 0,
          'legacy broad comment policy is absent');

select has_function('public', 'prepare_account_deletion', array['uuid', 'text'],
                    'account-deletion preparation RPC exists');
select has_function('public', 'register_storage_attachment', array['text', 'text', 'uuid', 'uuid'],
    'attachment registration RPC exists');
select has_function('public', 'can_read_storage_attachment', array['text', 'text'],
    'storage policy reads private attachment metadata through a security boundary');
select has_function('public', 'set_ai_consent', array['text', 'text', 'boolean'],
                    'purpose-specific AI consent RPC exists');
select has_function('public', 'report_content', array['text', 'uuid', 'text', 'text'],
                    'protected reporting RPC exists');
select has_function('public', 'preview_trip_invitation', array['text'],
                    'non-mutating invitation preview RPC exists');
select has_function('public', 'remove_trip_member', array['uuid', 'uuid'],
                    'owner-only member removal RPC exists');
select has_function('public', 'leave_trip', array['uuid'],
                    'member leave RPC exists');
select has_function('public', 'decline_trip_invitation', array['text'],
                    'recipient invitation decline RPC exists');
select has_function('public', 'revoke_trip_invitation', array['uuid'],
                    'owner invitation revocation RPC exists');

select ok(
    not has_table_privilege('authenticated', 'public.content_reports', 'SELECT')
    and not has_table_privilege('authenticated', 'public.content_reports', 'INSERT')
    and not has_table_privilege('authenticated', 'public.content_reports', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.content_reports', 'DELETE'),
    'ordinary users cannot inspect or mutate moderation reports'
);

select is((select count(*)::integer from pg_policies
           where schemaname = 'storage' and tablename = 'objects'
             and policyname = 'Attachment-authorized reads' and cmd = 'SELECT'), 1,
          'object reads use the attachment authorization policy');

select col_not_null('public', 'trip_invitations', 'token_hash',
                    'invitation tokens are represented by a required hash');

select * from finish();
rollback;

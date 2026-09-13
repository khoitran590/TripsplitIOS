-- Structural release-gate regression tests. Run with `supabase test db` after a clean
-- local reset. Behavioral multi-user fixtures remain a required staging test because
-- they exercise JWT/RLS identities and Storage signing end to end.

begin;

create extension if not exists pgtap with schema extensions;
select plan(49);

select has_table('public', 'financial_audit_events', 'financial audit table exists');
select has_table('public', 'storage_attachments', 'storage attachment ACL table exists');
select has_table('public', 'ai_processing_consents', 'AI consent receipts exist');
select has_table('public', 'user_blocks', 'user block table exists');
select has_table('public', 'content_reports', 'protected report queue exists');
select has_table('public', 'trip_removed_members', 'removed-member capability tombstones exist');
select has_table('public', 'community_trip_guides', 'community trip guides exist');

select col_not_null('public', 'trip_expenses', 'created_by', 'expense creator is immutable/non-null');
select col_not_null('public', 'settlement_records', 'created_by', 'settlement creator is immutable/non-null');
select col_not_null('public', 'expense_comments', 'created_by', 'comment creator is immutable/non-null');

select ok(not has_table_privilege('authenticated', 'public.trip_expenses', 'INSERT'),
          'authenticated cannot insert expenses directly');
select ok(not has_table_privilege('authenticated', 'public.settlement_records', 'UPDATE'),
          'authenticated cannot update settlements directly');
select ok(not has_table_privilege('authenticated', 'public.expense_comments', 'DELETE'),
          'authenticated cannot delete comments directly');

select has_trigger('public', 'trip_expenses', 'enforce_expense_delete_trigger',
                   'expense deletion has a dedicated cascade-aware guard');
select has_trigger('public', 'expense_comments', 'enforce_comment_delete_trigger',
                   'comment deletion has a dedicated cascade-aware guard');
select has_trigger('public', 'settlement_records', 'enforce_settlement_delete_trigger',
                   'settlement deletion has a dedicated cascade-aware guard');

select ok(has_table_privilege('authenticated', 'public.profiles', 'SELECT'),
          'authenticated can read profiles through RLS');
select ok(has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
          'authenticated can update profiles through RLS');
select ok(has_table_privilege('authenticated', 'public.trips', 'DELETE'),
          'authenticated owners can delete trips through RLS');
select ok(has_table_privilege('authenticated', 'public.trip_invitations', 'SELECT'),
          'authenticated owners can list invitations through RLS');
select ok(has_table_privilege('authenticated', 'public.trip_feed_posts', 'SELECT'),
          'authenticated trip members can read feed posts through RLS');
select ok(
    has_column_privilege('authenticated', 'public.trip_feed_posts', 'id', 'INSERT')
    and has_column_privilege('authenticated', 'public.trip_feed_posts', 'body', 'INSERT')
    and not has_column_privilege('authenticated', 'public.trip_feed_posts', 'comments', 'INSERT'),
    'feed insert access remains column-scoped'
);
select ok(has_table_privilege('authenticated', 'public.trip_feed_posts', 'DELETE'),
          'authenticated authors and owners can delete feed posts through RLS');
select ok(has_table_privilege('anon', 'public.community_trip_guides', 'SELECT'),
          'anonymous users can browse community guides through RLS');
select ok(has_column_privilege('authenticated', 'public.community_trip_guides', 'title', 'INSERT'),
          'authenticated users can publish community guides with scoped columns');
select col_not_null('public', 'community_trip_guides', 'best_base',
                    'community guides require a best-base recommendation');
select col_not_null('public', 'community_trip_guides', 'getting_around',
                    'community guides require local transportation guidance');
select col_not_null('public', 'community_trip_guides', 'book_first',
                    'community guides require booking guidance');
select ok(
    has_column_privilege('authenticated', 'public.community_trip_guides', 'best_base', 'UPDATE')
    and has_table_privilege('authenticated', 'public.community_trip_guides', 'DELETE'),
    'authenticated authors receive scoped guide-management privileges'
);
select ok(
    (select count(*) from pg_policies
      where schemaname = 'public'
        and tablename = 'community_trip_guides'
        and policyname in (
            'Authors update their community guides',
            'Authors delete their community guides'
        )) = 2,
    'community guides retain owner-only update and delete policies'
);
select ok(not has_function_privilege('anon', 'public.has_block_between(uuid,uuid)', 'EXECUTE'),
          'anonymous users cannot inspect private block relationships');
select ok(has_function_privilege('authenticated', 'public.has_block_between(uuid,uuid)', 'EXECUTE'),
          'authenticated policies can enforce reciprocal blocks');
select ok(
    (select count(*) from pg_policies
      where schemaname = 'public'
        and tablename = 'community_trip_guides'
        and cmd = 'SELECT'
        and policyname in (
            'Anonymous users read community guides',
            'Authenticated users read unblocked community guides'
        )) = 2,
    'community-guide reads use separate anonymous and authenticated policies'
);

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

-- Restore reviewed ordinary-role CRUD grants after hosted schema/history drift.
-- Service-role access and application data are preserved.
-- This is idempotent on a clean database and reconciles the deployed permissions.

-- ai_processing_consents
revoke select, insert, update, delete on public."ai_processing_consents" from public, anon, authenticated;
revoke select ("consent_version", "granted_at", "providers", "purpose", "revoked_at", "updated_at", "user_id"), insert ("consent_version", "granted_at", "providers", "purpose", "revoked_at", "updated_at", "user_id"), update ("consent_version", "granted_at", "providers", "purpose", "revoked_at", "updated_at", "user_id") on public."ai_processing_consents" from public, anon, authenticated;

-- expense_comments
revoke select, insert, update, delete on public."expense_comments" from public, anon, authenticated;
revoke select ("author_id", "created_at", "created_by", "edited_at", "expense_id", "id", "payload", "trip_id", "updated_at"), insert ("author_id", "created_at", "created_by", "edited_at", "expense_id", "id", "payload", "trip_id", "updated_at"), update ("author_id", "created_at", "created_by", "edited_at", "expense_id", "id", "payload", "trip_id", "updated_at") on public."expense_comments" from public, anon, authenticated;

-- friendships
revoke select, insert, update, delete on public."friendships" from public, anon, authenticated;
revoke select ("addressee_id", "created_at", "id", "requester_id", "responded_at", "status"), insert ("addressee_id", "created_at", "id", "requester_id", "responded_at", "status"), update ("addressee_id", "created_at", "id", "requester_id", "responded_at", "status") on public."friendships" from public, anon, authenticated;

-- profiles
revoke select, insert, update, delete on public."profiles" from public, anon, authenticated;
revoke select ("avatar_path", "bio", "date_of_birth", "display_name", "email", "profile_visibility", "saved_destination_ids", "saved_map_places", "saved_place_keys", "share_token", "showcase", "updated_at", "user_id", "visited_places"), insert ("avatar_path", "bio", "date_of_birth", "display_name", "email", "profile_visibility", "saved_destination_ids", "saved_map_places", "saved_place_keys", "share_token", "showcase", "updated_at", "user_id", "visited_places"), update ("avatar_path", "bio", "date_of_birth", "display_name", "email", "profile_visibility", "saved_destination_ids", "saved_map_places", "saved_place_keys", "share_token", "showcase", "updated_at", "user_id", "visited_places") on public."profiles" from public, anon, authenticated;
grant select on public."profiles" to authenticated;
grant update ("avatar_path", "bio", "date_of_birth", "display_name", "profile_visibility", "saved_destination_ids", "saved_map_places", "saved_place_keys", "showcase", "visited_places") on public."profiles" to authenticated;

-- receipt_scan_events
revoke select, insert, update, delete on public."receipt_scan_events" from public, anon, authenticated;
revoke select ("committed_at", "created_at", "id", "kind", "reservation_expires_at", "status", "user_id"), insert ("committed_at", "created_at", "id", "kind", "reservation_expires_at", "status", "user_id"), update ("committed_at", "created_at", "id", "kind", "reservation_expires_at", "status", "user_id") on public."receipt_scan_events" from public, anon, authenticated;

-- settlement_records
revoke select, insert, update, delete on public."settlement_records" from public, anon, authenticated;
revoke select ("amount", "created_by", "creditor_id", "debtor_id", "id", "payload", "record_date", "settlement_key", "status", "trip_id", "updated_at"), insert ("amount", "created_by", "creditor_id", "debtor_id", "id", "payload", "record_date", "settlement_key", "status", "trip_id", "updated_at"), update ("amount", "created_by", "creditor_id", "debtor_id", "id", "payload", "record_date", "settlement_key", "status", "trip_id", "updated_at") on public."settlement_records" from public, anon, authenticated;

-- trip_expenses
revoke select, insert, update, delete on public."trip_expenses" from public, anon, authenticated;
revoke select ("amount", "created_by", "deleted_at", "expense_date", "id", "payer_id", "payload", "trip_id", "updated_at"), insert ("amount", "created_by", "deleted_at", "expense_date", "id", "payer_id", "payload", "trip_id", "updated_at"), update ("amount", "created_by", "deleted_at", "expense_date", "id", "payer_id", "payload", "trip_id", "updated_at") on public."trip_expenses" from public, anon, authenticated;

-- trip_feed_posts
revoke select, insert, update, delete on public."trip_feed_posts" from public, anon, authenticated;
revoke select ("author_id", "author_name", "body", "comments", "created_at", "id", "location_address", "location_latitude", "location_longitude", "location_name", "photo_paths", "reactions", "trip_id", "updated_at"), insert ("author_id", "author_name", "body", "comments", "created_at", "id", "location_address", "location_latitude", "location_longitude", "location_name", "photo_paths", "reactions", "trip_id", "updated_at"), update ("author_id", "author_name", "body", "comments", "created_at", "id", "location_address", "location_latitude", "location_longitude", "location_name", "photo_paths", "reactions", "trip_id", "updated_at") on public."trip_feed_posts" from public, anon, authenticated;
grant select on public."trip_feed_posts" to authenticated;
grant insert ("author_id", "author_name", "body", "id", "location_address", "location_latitude", "location_longitude", "location_name", "photo_paths", "trip_id") on public."trip_feed_posts" to authenticated;
grant update ("body", "location_address", "location_latitude", "location_longitude", "location_name") on public."trip_feed_posts" to authenticated;
grant delete on public."trip_feed_posts" to authenticated;

-- trip_invitations
revoke select, insert, update, delete on public."trip_invitations" from public, anon, authenticated;
revoke select ("accepted_at", "created_at", "email", "expires_at", "id", "invited_by", "status", "token", "token_hash", "trip_id"), insert ("accepted_at", "created_at", "email", "expires_at", "id", "invited_by", "status", "token", "token_hash", "trip_id"), update ("accepted_at", "created_at", "email", "expires_at", "id", "invited_by", "status", "token", "token_hash", "trip_id") on public."trip_invitations" from public, anon, authenticated;
grant select on public."trip_invitations" to authenticated;

-- trip_members
revoke select, insert, update, delete on public."trip_members" from public, anon, authenticated;
revoke select ("created_at", "role", "trip_id", "user_id"), insert ("created_at", "role", "trip_id", "user_id"), update ("created_at", "role", "trip_id", "user_id") on public."trip_members" from public, anon, authenticated;

-- trips
revoke select, insert, update, delete on public."trips" from public, anon, authenticated;
revoke select ("currency_code", "data", "id", "metadata", "name", "updated_at", "user_id"), insert ("currency_code", "data", "id", "metadata", "name", "updated_at", "user_id"), update ("currency_code", "data", "id", "metadata", "name", "updated_at", "user_id") on public."trips" from public, anon, authenticated;
grant select on public."trips" to authenticated;
grant delete on public."trips" to authenticated;

-- user_blocks
revoke select, insert, update, delete on public."user_blocks" from public, anon, authenticated;
revoke select ("blocked_id", "blocker_id", "created_at"), insert ("blocked_id", "blocker_id", "created_at"), update ("blocked_id", "blocker_id", "created_at") on public."user_blocks" from public, anon, authenticated;

-- Match the baseline UNIQUE constraint; the separate unique token index already
-- enforces uniqueness in production, so this repairs metadata without rewriting rows.
do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.trip_invitations'::regclass and conname='trip_invitations_token_key') then
  alter table public.trip_invitations add constraint trip_invitations_token_key unique(token);
 end if;
end;
$$;
notify pgrst, 'reload schema';
;

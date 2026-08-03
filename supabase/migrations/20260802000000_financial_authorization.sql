-- Release hardening: server-enforced trip and financial authorization.
--
-- The compatibility sync RPC still accepts a complete Codable Trip document, but it is
-- no longer trusted as authorization evidence. BEFORE triggers compare every attempted
-- mutation with the authoritative database row and auth.uid(); direct child-table DML is
-- revoked. This safely protects current clients while narrow RPCs replace the sync API.

alter table public.trip_expenses
    add column if not exists created_by uuid;
alter table public.settlement_records
    add column if not exists created_by uuid,
    add column if not exists debtor_id uuid,
    add column if not exists creditor_id uuid;
alter table public.expense_comments
    add column if not exists created_by uuid;

create table if not exists public.trip_removed_members (
    trip_id uuid not null references public.trips(id) on delete cascade,
    user_id uuid not null,
    reason text not null check (reason in ('removed', 'left', 'deleted')),
    removed_at timestamptz not null default now(),
    primary key (trip_id, user_id)
);
alter table public.trip_removed_members enable row level security;
revoke all on table public.trip_removed_members from public, anon, authenticated;

update public.trip_expenses e
set created_by = coalesce(
    (select e.payer_id where exists (
        select 1 from public.trip_members tm
        where tm.trip_id = e.trip_id and tm.user_id = e.payer_id
    )),
    (select t.user_id from public.trips t where t.id = e.trip_id)
)
where created_by is null;

update public.expense_comments c
set created_by = coalesce(
    (select c.author_id where exists (
        select 1 from public.trip_members tm
        where tm.trip_id = c.trip_id and tm.user_id = c.author_id
    )),
    (select t.user_id from public.trips t where t.id = c.trip_id)
)
where created_by is null;

update public.settlement_records s
set debtor_id = case
        when split_part(s.settlement_key, '->', 1)
             ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then split_part(s.settlement_key, '->', 1)::uuid
    end,
    creditor_id = case
        when split_part(s.settlement_key, '->', 2)
             ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then split_part(s.settlement_key, '->', 2)::uuid
    end
where debtor_id is null or creditor_id is null;

update public.settlement_records s
set created_by = coalesce(
    (select s.debtor_id where exists (
        select 1 from public.trip_members tm
        where tm.trip_id = s.trip_id and tm.user_id = s.debtor_id
    )),
    (select t.user_id from public.trips t where t.id = s.trip_id)
)
where created_by is null;

alter table public.trip_expenses alter column created_by set not null;
alter table public.settlement_records alter column created_by set not null;
alter table public.expense_comments alter column created_by set not null;

create or replace function public.is_trip_owner(p_trip_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select p_user_id is not null and exists (
        select 1 from public.trips t
        where t.id = p_trip_id and t.user_id = p_user_id
    );
$$;

create or replace function public.trip_metadata_has_person(p_trip_id uuid, p_person_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1
        from public.trips t,
             jsonb_array_elements(coalesce(t.metadata->'members', '[]'::jsonb)) member
        where t.id = p_trip_id
          and lower(member->>'id') = p_person_id::text
          and not exists (
              select 1 from public.trip_removed_members removed
              where removed.trip_id = p_trip_id and removed.user_id = p_person_id
          )
    );
$$;

create or replace function public.enforce_trip_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_old_archived jsonb;
    v_new_archived jsonb;
begin
    if v_uid is null and auth.role() is distinct from 'service_role' then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if auth.role() = 'service_role' then return new; end if;

    if tg_op = 'INSERT' then
        if new.user_id is distinct from v_uid then
            raise exception 'Trip owner must be the signed-in user.' using errcode = '42501';
        end if;
        return new;
    end if;

    if new.id is distinct from old.id or new.user_id is distinct from old.user_id then
        raise exception 'Trip identity and owner are immutable.' using errcode = '42501';
    end if;
    if not public.is_trip_member(old.id) then
        raise exception 'You are not a member of this trip.' using errcode = '42501';
    end if;

    if jsonb_typeof(new.metadata) is distinct from 'object'
       or pg_column_size(new.metadata) > 1048576
       or length(coalesce(new.name, '')) not between 1 and 200
       or coalesce(new.currency_code, '') !~ '^[A-Z]{3}$' then
        raise exception 'Trip metadata is invalid.' using errcode = '22023';
    end if;
    if lower(coalesce(new.metadata->>'creatorID', '')) <> new.user_id::text then
        raise exception 'Trip creator identity is immutable.' using errcode = '42501';
    end if;
    if jsonb_typeof(coalesce(new.metadata->'members', '[]'::jsonb)) <> 'array'
       or jsonb_array_length(coalesce(new.metadata->'members', '[]'::jsonb)) > 100 then
        raise exception 'Trip membership metadata is invalid.' using errcode = '22023';
    end if;

    if not public.is_trip_owner(old.id, v_uid) then
        -- Members may collaborate on the itinerary/map and toggle only their own archive
        -- state. Owner, member list, budgets, permissions, name, dates, and currency stay
        -- under organizer control.
        if (new.metadata - 'archivedBy' - 'itinerary' - 'sharedMapPlaces')
           is distinct from
           (old.metadata - 'archivedBy' - 'itinerary' - 'sharedMapPlaces')
           or new.name is distinct from old.name
           or new.currency_code is distinct from old.currency_code then
            raise exception 'Only the trip owner can change protected trip fields.' using errcode = '42501';
        end if;

        if jsonb_typeof(coalesce(new.metadata->'archivedBy', '[]'::jsonb)) <> 'array'
           or jsonb_array_length(coalesce(new.metadata->'archivedBy', '[]'::jsonb)) > 100 then
            raise exception 'Archive state is invalid.' using errcode = '22023';
        end if;
        select coalesce(jsonb_agg(value order by lower(value #>> '{}')), '[]'::jsonb)
          into v_old_archived
          from jsonb_array_elements(coalesce(old.metadata->'archivedBy', '[]'::jsonb))
         where lower(value #>> '{}') <> v_uid::text;
        select coalesce(jsonb_agg(value order by lower(value #>> '{}')), '[]'::jsonb)
          into v_new_archived
          from jsonb_array_elements(coalesce(new.metadata->'archivedBy', '[]'::jsonb))
         where lower(value #>> '{}') <> v_uid::text;
        if v_new_archived is distinct from v_old_archived then
            raise exception 'A member can only change their own archive state.' using errcode = '42501';
        end if;
    end if;

    -- The compatibility projection may only be rebuilt from normalized server rows.
    if new.data is distinct from old.data
       and new.data is distinct from public.trip_document(old.id) then
        raise exception 'Trip data must be generated by the server.' using errcode = '42501';
    end if;
    return new;
end;
$$;

drop trigger if exists enforce_trip_mutation_trigger on public.trips;
create trigger enforce_trip_mutation_trigger
    before insert or update on public.trips
    for each row execute function public.enforce_trip_mutation();

create or replace function public.enforce_expense_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_owner boolean;
    v_allow_other_payers boolean;
    v_participant jsonb;
begin
    if v_uid is null and auth.role() is distinct from 'service_role' then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if auth.role() = 'service_role' then
        if tg_op = 'DELETE' then return old; else return new; end if;
    end if;

    if tg_op = 'DELETE' then
        if not public.is_trip_member(old.trip_id)
           or (not public.is_trip_owner(old.trip_id, v_uid) and old.payer_id is distinct from v_uid) then
            raise exception 'Only the trip owner or payer can delete this expense.' using errcode = '42501';
        end if;
        return old;
    end if;

    if not public.is_trip_member(new.trip_id) then
        raise exception 'You are not a member of this trip.' using errcode = '42501';
    end if;
    v_owner := public.is_trip_owner(new.trip_id, v_uid);
    select coalesce((t.metadata->>'allowMembersToPayForOthers')::boolean, false)
      into v_allow_other_payers from public.trips t where t.id = new.trip_id;

    if tg_op = 'INSERT' then
        new.created_by := v_uid;
        if not v_owner and not v_allow_other_payers and new.payer_id is distinct from v_uid then
            raise exception 'Members may only create expenses they paid.' using errcode = '42501';
        end if;
    else
        if new.id is distinct from old.id or new.trip_id is distinct from old.trip_id then
            raise exception 'Expense identity is immutable.' using errcode = '42501';
        end if;
        if not v_owner and old.payer_id is distinct from v_uid then
            raise exception 'Only the trip owner or payer can edit this expense.' using errcode = '42501';
        end if;
        if not v_owner and new.payer_id is distinct from old.payer_id then
            raise exception 'Only the trip owner can transfer an expense to another payer.' using errcode = '42501';
        end if;
        new.created_by := old.created_by;
    end if;

    if new.payer_id is null
       or not public.trip_metadata_has_person(new.trip_id, new.payer_id)
       or new.amount::text in ('NaN', 'Infinity', '-Infinity')
       or new.amount <= 0 or new.amount > 1000000000
       or jsonb_typeof(new.payload) is distinct from 'object'
       or pg_column_size(new.payload) > 524288
       or lower(coalesce(new.payload->>'id', '')) <> new.id::text
       or lower(coalesce(new.payload->>'payerID', '')) <> new.payer_id::text
       or length(btrim(coalesce(new.payload->>'title', ''))) not between 1 and 500
       or jsonb_typeof(coalesce(new.payload->'participantIDs', '[]'::jsonb)) <> 'array'
       or jsonb_array_length(coalesce(new.payload->'participantIDs', '[]'::jsonb)) not between 1 and 100
       or jsonb_typeof(coalesce(new.payload->'items', '[]'::jsonb)) <> 'array'
       or jsonb_array_length(coalesce(new.payload->'items', '[]'::jsonb)) > 500 then
        raise exception 'Expense data is invalid.' using errcode = '22023';
    end if;

    for v_participant in
        select value from jsonb_array_elements(new.payload->'participantIDs')
    loop
        if (v_participant #>> '{}') !~* '^[0-9a-f-]{36}$'
           or not public.trip_metadata_has_person(new.trip_id, (v_participant #>> '{}')::uuid) then
            raise exception 'Every expense participant must belong to the trip.' using errcode = '22023';
        end if;
    end loop;
    return new;
end;
$$;

drop trigger if exists enforce_expense_mutation_trigger on public.trip_expenses;
create trigger enforce_expense_mutation_trigger
    before insert or update or delete on public.trip_expenses
    for each row execute function public.enforce_expense_mutation();

create or replace function public.enforce_comment_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_author_name text;
begin
    if v_uid is null and auth.role() is distinct from 'service_role' then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if auth.role() = 'service_role' then
        if tg_op = 'DELETE' then return old; else return new; end if;
    end if;

    if tg_op = 'DELETE' then
        if not public.is_trip_member(old.trip_id)
           or (old.author_id is distinct from v_uid and not public.is_trip_owner(old.trip_id, v_uid)) then
            raise exception 'Only the author or trip owner can delete this comment.' using errcode = '42501';
        end if;
        return old;
    end if;
    if not public.is_trip_member(new.trip_id)
       or not exists (select 1 from public.trip_expenses e where e.id = new.expense_id and e.trip_id = new.trip_id) then
        raise exception 'The comment must reference an expense in your trip.' using errcode = '42501';
    end if;
    if jsonb_typeof(new.payload) is distinct from 'object'
       or pg_column_size(new.payload) > 16384
       or lower(coalesce(new.payload->>'id', '')) <> new.id::text
       or length(btrim(coalesce(new.payload->>'text', ''))) not between 1 and 2000 then
        raise exception 'Comment data is invalid.' using errcode = '22023';
    end if;

    if tg_op = 'INSERT' then
        new.author_id := v_uid;
        new.created_by := v_uid;
        new.created_at := now();
        new.edited_at := null;
        select coalesce(nullif(btrim(p.display_name), ''), 'TripSplit User')
          into v_author_name from public.profiles p where p.user_id = v_uid;
        new.payload := new.payload || jsonb_build_object(
            'authorID', v_uid,
            'authorName', coalesce(v_author_name, 'TripSplit User'),
            'date', new.created_at,
            'editedAt', null
        );
    else
        if new.id is distinct from old.id
           or new.trip_id is distinct from old.trip_id
           or new.expense_id is distinct from old.expense_id
           or old.author_id is distinct from v_uid then
            raise exception 'Only the author can edit this comment.' using errcode = '42501';
        end if;
        new.author_id := old.author_id;
        new.created_by := old.created_by;
        new.created_at := old.created_at;
        new.edited_at := now();
        new.payload := old.payload || jsonb_build_object(
            'text', new.payload->>'text',
            'editedAt', new.edited_at
        );
    end if;
    return new;
end;
$$;

drop trigger if exists enforce_comment_mutation_trigger on public.expense_comments;
create trigger enforce_comment_mutation_trigger
    before insert or update or delete on public.expense_comments
    for each row execute function public.enforce_comment_mutation();

create or replace function public.enforce_settlement_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_debtor uuid;
    v_creditor uuid;
begin
    if v_uid is null and auth.role() is distinct from 'service_role' then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if auth.role() = 'service_role' then
        if tg_op = 'DELETE' then return old; else return new; end if;
    end if;
    if tg_op = 'DELETE' then
        raise exception 'Settlement records are append-only.' using errcode = '42501';
    end if;
    if not public.is_trip_member(new.trip_id) then
        raise exception 'You are not a member of this trip.' using errcode = '42501';
    end if;
    if new.settlement_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}->[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'Settlement parties are invalid.' using errcode = '22023';
    end if;
    v_debtor := split_part(new.settlement_key, '->', 1)::uuid;
    v_creditor := split_part(new.settlement_key, '->', 2)::uuid;
    if v_debtor = v_creditor
       or not exists (select 1 from public.trip_members where trip_id = new.trip_id and user_id = v_debtor)
       or not exists (select 1 from public.trip_members where trip_id = new.trip_id and user_id = v_creditor) then
        raise exception 'Settlement parties must be active trip members.' using errcode = '22023';
    end if;
    if new.amount::text in ('NaN', 'Infinity', '-Infinity')
       or new.amount <= 0 or new.amount > 1000000000
       or jsonb_typeof(new.payload) is distinct from 'object'
       or pg_column_size(new.payload) > 16384
       or lower(coalesce(new.payload->>'id', '')) <> new.id::text
       or length(coalesce(new.payload->>'note', '')) > 1000
       or coalesce(new.payload->>'method', '') not in ('Cash', 'Venmo', 'PayPal', 'Cash App') then
        raise exception 'Settlement data is invalid.' using errcode = '22023';
    end if;

    if tg_op = 'INSERT' then
        -- The normal flow is debtor-created pending -> creditor-confirmed. The existing
        -- one-tap "Mark Paid" UI also lets the creditor record a payment they directly
        -- observed, so a creditor may insert an already-confirmed record.
        if not (
            (v_uid = v_debtor and coalesce(new.status, '') = 'pending')
            or (v_uid = v_creditor and coalesce(new.status, '') = 'confirmed')
        ) then
            raise exception 'Only the debtor can propose payment or the creditor can confirm it.' using errcode = '42501';
        end if;
        new.created_by := v_uid;
        new.debtor_id := v_debtor;
        new.creditor_id := v_creditor;
        new.record_date := now();
        new.payload := new.payload || jsonb_build_object('status', new.status, 'date', new.record_date);
    else
        if new.id is distinct from old.id
           or new.trip_id is distinct from old.trip_id
           or new.settlement_key is distinct from old.settlement_key
           or old.status is distinct from 'pending'
           or coalesce(new.status, '') not in ('confirmed', 'rejected')
           or v_uid <> old.creditor_id
           or new.amount is distinct from old.amount then
            raise exception 'Only the creditor can confirm or reject a pending settlement.' using errcode = '42501';
        end if;
        new.created_by := old.created_by;
        new.debtor_id := old.debtor_id;
        new.creditor_id := old.creditor_id;
        new.record_date := old.record_date;
        new.payload := old.payload || jsonb_build_object('status', new.status);
    end if;
    return new;
end;
$$;

drop trigger if exists enforce_settlement_mutation_trigger on public.settlement_records;
create trigger enforce_settlement_mutation_trigger
    before insert or update or delete on public.settlement_records
    for each row execute function public.enforce_settlement_mutation();

create table if not exists public.financial_audit_events (
    id bigint generated always as identity primary key,
    trip_id uuid not null,
    actor_id uuid,
    entity_type text not null check (entity_type in ('expense', 'settlement', 'comment')),
    entity_id uuid not null,
    action text not null check (action in ('insert', 'update', 'delete')),
    before_state jsonb,
    after_state jsonb,
    occurred_at timestamptz not null default now()
);
create index if not exists financial_audit_trip_time_idx
    on public.financial_audit_events (trip_id, occurred_at desc);
alter table public.financial_audit_events enable row level security;
revoke all on table public.financial_audit_events from public, anon, authenticated;

create or replace function public.audit_financial_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
    v_type text := case tg_table_name
        when 'trip_expenses' then 'expense'
        when 'settlement_records' then 'settlement'
        else 'comment'
    end;
begin
    insert into public.financial_audit_events
        (trip_id, actor_id, entity_type, entity_id, action, before_state, after_state)
    values (
        (v_row->>'trip_id')::uuid,
        auth.uid(),
        v_type,
        (v_row->>'id')::uuid,
        lower(tg_op),
        case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
        case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
    );
    if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

drop trigger if exists audit_expense_mutation on public.trip_expenses;
create trigger audit_expense_mutation after insert or update or delete on public.trip_expenses
    for each row execute function public.audit_financial_mutation();
drop trigger if exists audit_settlement_mutation on public.settlement_records;
create trigger audit_settlement_mutation after insert or update or delete on public.settlement_records
    for each row execute function public.audit_financial_mutation();
drop trigger if exists audit_comment_mutation on public.expense_comments;
create trigger audit_comment_mutation after insert or update or delete on public.expense_comments
    for each row execute function public.audit_financial_mutation();

-- PostgREST can no longer mutate financial rows directly. The compatibility sync RPC
-- remains executable, but every row it touches is checked by the triggers above.
drop policy if exists "Trip members can write expenses" on public.trip_expenses;
drop policy if exists "Trip members can write settlements" on public.settlement_records;
drop policy if exists "Trip members can write expense comments" on public.expense_comments;
revoke insert, update, delete on table public.trip_expenses from public, anon, authenticated;
revoke insert, update, delete on table public.settlement_records from public, anon, authenticated;
revoke insert, update, delete on table public.expense_comments from public, anon, authenticated;

-- Trip creation/updates go through sync_trip_normalized, where the trigger validates the
-- authoritative old row. Keep owner DELETE available for the existing client.
drop policy if exists "Users create owned trips" on public.trips;
drop policy if exists "Trip members can update trips" on public.trips;
revoke insert, update on table public.trips from public, anon, authenticated;
revoke all on function public.upsert_trip(uuid, uuid, jsonb) from public, anon, authenticated;

-- Privileged, retry-safe application-data phase of account deletion. The Edge Function
-- calls this with the service-role JWT, deletes Storage, and deletes auth.users last.
create or replace function public.prepare_account_deletion(p_user_id uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_affected_trip_ids uuid[];
    v_trip_id uuid;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'Service role required.' using errcode = '42501';
    end if;

    select coalesce(array_agg(tm.trip_id), '{}'::uuid[])
      into v_affected_trip_ids
      from public.trip_members tm
     where tm.user_id = p_user_id
       and not exists (
           select 1 from public.trips owned
           where owned.id = tm.trip_id and owned.user_id = p_user_id
       );

    -- Trips organized by the deleting account are removed under the published product
    -- rule. Cascades remove normalized expenses, settlements, feed posts, and membership.
    delete from public.trips where user_id = p_user_id;

    -- Remove authored UGC from trips owned by somebody else.
    delete from public.expense_comments where author_id = p_user_id;
    delete from public.trip_feed_posts where author_id = p_user_id;
    update public.trip_feed_posts p
       set comments = coalesce((
               select jsonb_agg(comment order by comment->>'date')
                 from jsonb_array_elements(p.comments) comment
                where lower(coalesce(comment->>'authorID', '')) <> p_user_id::text
           ), '[]'::jsonb),
           reactions = coalesce((
               select jsonb_object_agg(reaction.key, reaction.members)
                 from (
                     select pair.key,
                            coalesce(jsonb_agg(member order by member #>> '{}')
                                filter (where lower(member #>> '{}') <> p_user_id::text), '[]'::jsonb) members
                       from jsonb_each(p.reactions) pair
                       left join lateral jsonb_array_elements(pair.value) member on true
                      group by pair.key
                 ) reaction
           ), '{}'::jsonb)
     where exists (
         select 1 from jsonb_array_elements(p.comments) comment
          where lower(coalesce(comment->>'authorID', '')) = p_user_id::text
     ) or p.reactions::text ilike '%' || p_user_id::text || '%';

    -- Keep a pseudonymous participant tombstone where shared financial history still
    -- references this UUID, while removing profile/avatar data and active access.
    update public.trips t
       set metadata = jsonb_set(
               jsonb_set(
                   t.metadata,
                   '{members}',
                   coalesce((
                       select jsonb_agg(
                           case when lower(member->>'id') = p_user_id::text
                                then (member - 'avatarURL') || jsonb_build_object('name', 'Deleted User')
                                else member end
                           order by member->>'id'
                       )
                       from jsonb_array_elements(coalesce(t.metadata->'members', '[]'::jsonb)) member
                   ), '[]'::jsonb),
                   true
               ),
               '{archivedBy}',
               coalesce((
                   select jsonb_agg(value order by value #>> '{}')
                   from jsonb_array_elements(coalesce(t.metadata->'archivedBy', '[]'::jsonb))
                   where lower(value #>> '{}') <> p_user_id::text
               ), '[]'::jsonb),
               true
           )
     where t.id = any(v_affected_trip_ids);

    insert into public.trip_removed_members (trip_id, user_id, reason, removed_at)
    select unnest(v_affected_trip_ids), p_user_id, 'deleted', now()
    on conflict (trip_id, user_id) do update set reason = 'deleted', removed_at = now();
    delete from public.trip_members where user_id = p_user_id;
    delete from public.friendships where requester_id = p_user_id or addressee_id = p_user_id;
    delete from public.trip_invitations
     where invited_by = p_user_id
        or (p_email is not null and lower(email) = lower(p_email));
    delete from public.profiles where user_id = p_user_id;

    foreach v_trip_id in array v_affected_trip_ids loop
        update public.trips set data = public.trip_document(v_trip_id) where id = v_trip_id;
    end loop;

    return jsonb_build_object(
        'prepared', true,
        'storagePrefix', p_user_id::text,
        'retainedFinancialIdentity', true
    );
end;
$$;

revoke all on function public.prepare_account_deletion(uuid, text) from public, anon, authenticated;
grant execute on function public.prepare_account_deletion(uuid, text) to service_role;

revoke all on function public.is_trip_owner(uuid, uuid) from public, anon;
revoke all on function public.trip_metadata_has_person(uuid, uuid) from public, anon;
grant execute on function public.is_trip_owner(uuid, uuid) to authenticated;
grant execute on function public.trip_metadata_has_person(uuid, uuid) to authenticated;

-- Narrow membership administration. Historical Person entries remain in trip metadata
-- so balances and expense attribution stay intelligible, but deleting the membership
-- row immediately removes every RLS/Storage capability.
create or replace function public.remove_trip_member(p_trip_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if not public.is_trip_owner(p_trip_id, auth.uid()) then
        raise exception 'Only the trip owner can remove member access.' using errcode = '42501';
    end if;
    if p_user_id is null or p_user_id = auth.uid() then
        raise exception 'The trip owner cannot be removed.' using errcode = '22023';
    end if;
    insert into public.trip_removed_members (trip_id, user_id, reason, removed_at)
    values (p_trip_id, p_user_id, 'removed', now())
    on conflict (trip_id, user_id) do update set reason = 'removed', removed_at = now();
    delete from public.trip_members
     where trip_id = p_trip_id and user_id = p_user_id and role = 'member';
    if not found then
        delete from public.trip_removed_members where trip_id = p_trip_id and user_id = p_user_id;
        raise exception 'This person does not have active account access.' using errcode = 'P0002';
    end if;
    update public.trip_invitations i
       set status = 'revoked'
     where i.trip_id = p_trip_id and i.status = 'pending'
       and lower(i.email) = (select lower(p.email) from public.profiles p where p.user_id = p_user_id);
end;
$$;

create or replace function public.leave_trip(p_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if public.is_trip_owner(p_trip_id, auth.uid()) then
        raise exception 'The owner must delete the trip instead of leaving it.' using errcode = '22023';
    end if;
    insert into public.trip_removed_members (trip_id, user_id, reason, removed_at)
    values (p_trip_id, auth.uid(), 'left', now())
    on conflict (trip_id, user_id) do update set reason = 'left', removed_at = now();
    delete from public.trip_members
     where trip_id = p_trip_id and user_id = auth.uid() and role = 'member';
    if not found then
        delete from public.trip_removed_members where trip_id = p_trip_id and user_id = auth.uid();
        raise exception 'You are no longer a member of this trip.' using errcode = 'P0002';
    end if;
end;
$$;

revoke all on function public.remove_trip_member(uuid, uuid) from public, anon;
revoke all on function public.leave_trip(uuid) from public, anon;
grant execute on function public.remove_trip_member(uuid, uuid) to authenticated;
grant execute on function public.leave_trip(uuid) to authenticated;

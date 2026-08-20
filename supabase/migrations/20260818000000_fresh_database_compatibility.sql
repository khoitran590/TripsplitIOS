-- Fresh databases do not inherit the hosted project's historical PostgREST grants.
-- Keep table privileges narrow; row-level policies remain the authorization boundary.

grant select, update on table public.profiles to authenticated;

-- Current writes use SECURITY DEFINER RPCs. Direct trip reads exist only as a short
-- migration-rollout fallback, while owners delete trips through the REST table route.
grant select, delete on table public.trips to authenticated;

-- Owners list pending invitations directly; creation and state transitions use RPCs.
grant select on table public.trip_invitations to authenticated;

-- Insert/update stay column-scoped by earlier migrations. Feed reads and deletes
-- require their own table privileges in addition to the existing RLS policies.
grant select, delete on table public.trip_feed_posts to authenticated;

-- `trip_id` is also the output column of this table-returning function. Qualify the
-- tombstone columns so PL/pgSQL does not reject invitation acceptance as ambiguous.
create or replace function public.accept_trip_invitation(p_token text)
returns table(trip_id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_invitation public.trip_invitations%rowtype;
    v_current_email text;
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if p_token is null or p_token !~ '^[a-f0-9]{36,64}$' then
        raise exception 'This invitation link is invalid or has expired.' using errcode = '22023';
    end if;
    select * into v_invitation from public.trip_invitations i
    where i.token_hash = extensions.digest(p_token, 'sha256')
      and i.status = 'pending' and i.expires_at > now()
    for update;
    if not found or public.has_block_between(auth.uid(), v_invitation.invited_by) then
        raise exception 'This invitation link is invalid or has expired.' using errcode = 'P0002';
    end if;
    select lower(p.email) into v_current_email
      from public.profiles p where p.user_id = auth.uid();
    if v_invitation.email is not null and lower(v_invitation.email) <> v_current_email then
        raise exception 'This invitation link is invalid or has expired.' using errcode = '42501';
    end if;
    insert into public.trip_members (trip_id, user_id, role)
    values (v_invitation.trip_id, auth.uid(), 'member')
    on conflict on constraint trip_members_pkey do nothing;
    delete from public.trip_removed_members removed
     where removed.trip_id = v_invitation.trip_id and removed.user_id = auth.uid();
    update public.trip_invitations i
       set status = 'accepted', accepted_at = now(),
           email = coalesce(i.email, v_current_email)
     where i.id = v_invitation.id and i.status = 'pending';
    if not found then raise exception 'This invitation link is invalid or has expired.' using errcode = 'P0002'; end if;
    return query select v_invitation.trip_id;
end;
$$;

-- Split DELETE checks from the mutation triggers. A direct child-row deletion has
-- trigger depth 1 and keeps the existing authorization rules. An FK cascade caused
-- by deleting a parent trip/expense is nested and may clean up dependent rows.

drop trigger if exists enforce_expense_mutation_trigger on public.trip_expenses;
create trigger enforce_expense_mutation_trigger
    before insert or update on public.trip_expenses
    for each row execute function public.enforce_expense_mutation();

create or replace function public.enforce_expense_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
begin
    if auth.role() = 'service_role' or pg_trigger_depth() > 1 then return old; end if;
    if v_uid is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if not public.is_trip_member(old.trip_id)
       or (not public.is_trip_owner(old.trip_id, v_uid) and old.payer_id is distinct from v_uid) then
        raise exception 'Only the trip owner or payer can delete this expense.' using errcode = '42501';
    end if;
    return old;
end;
$$;

drop trigger if exists enforce_expense_delete_trigger on public.trip_expenses;
create trigger enforce_expense_delete_trigger
    before delete on public.trip_expenses
    for each row execute function public.enforce_expense_delete();

drop trigger if exists enforce_comment_mutation_trigger on public.expense_comments;
create trigger enforce_comment_mutation_trigger
    before insert or update on public.expense_comments
    for each row execute function public.enforce_comment_mutation();

create or replace function public.enforce_comment_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
begin
    if auth.role() = 'service_role' or pg_trigger_depth() > 1 then return old; end if;
    if v_uid is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if not public.is_trip_member(old.trip_id)
       or (old.author_id is distinct from v_uid and not public.is_trip_owner(old.trip_id, v_uid)) then
        raise exception 'Only the author or trip owner can delete this comment.' using errcode = '42501';
    end if;
    return old;
end;
$$;

drop trigger if exists enforce_comment_delete_trigger on public.expense_comments;
create trigger enforce_comment_delete_trigger
    before delete on public.expense_comments
    for each row execute function public.enforce_comment_delete();

drop trigger if exists enforce_settlement_mutation_trigger on public.settlement_records;
create trigger enforce_settlement_mutation_trigger
    before insert or update on public.settlement_records
    for each row execute function public.enforce_settlement_mutation();

create or replace function public.enforce_settlement_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.role() = 'service_role' or pg_trigger_depth() > 1 then return old; end if;
    if auth.uid() is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    raise exception 'Settlement records are append-only.' using errcode = '42501';
end;
$$;

drop trigger if exists enforce_settlement_delete_trigger on public.settlement_records;
create trigger enforce_settlement_delete_trigger
    before delete on public.settlement_records
    for each row execute function public.enforce_settlement_delete();

revoke all on function public.enforce_expense_delete() from public, anon, authenticated;
revoke all on function public.enforce_comment_delete() from public, anon, authenticated;
revoke all on function public.enforce_settlement_delete() from public, anon, authenticated;

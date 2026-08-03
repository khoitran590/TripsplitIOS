-- Pending-only invitations, hashed single-use tokens, generic email responses, and
-- short expiry. Opening a token does not mutate membership; the client previews first.

alter table public.trip_invitations
    drop constraint if exists trip_invitations_status_check;
alter table public.trip_invitations
    add constraint trip_invitations_status_check
    check (status in ('pending', 'accepted', 'revoked', 'declined'));

alter table public.trip_invitations add column if not exists token_hash bytea;
update public.trip_invitations
set token_hash = extensions.digest(token, 'sha256')
where token_hash is null;
alter table public.trip_invitations alter column token_hash set not null;
create unique index if not exists trip_invitations_token_hash_idx
    on public.trip_invitations (token_hash);
update public.trip_invitations
set token = encode(token_hash, 'hex'),
    expires_at = least(expires_at, created_at + interval '72 hours')
where token <> encode(token_hash, 'hex') or expires_at > created_at + interval '72 hours';
alter table public.trip_invitations alter column expires_at set default (now() + interval '72 hours');

create or replace function public.invite_trip_member(p_trip_id uuid, p_email text)
returns table(member_user_id uuid, invitation_id uuid, accepted boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_email text := lower(btrim(p_email));
    v_id uuid;
    v_raw_token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if v_email is null or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}$'
       or length(v_email) > 254 then
        raise exception 'Enter a valid email address.' using errcode = '22023';
    end if;
    if not public.is_trip_owner(p_trip_id, auth.uid()) then
        raise exception 'Only the trip owner can invite members.' using errcode = '42501';
    end if;
    if (select count(*) from public.trip_invitations
        where invited_by = auth.uid() and created_at > now() - interval '1 hour') >= 30 then
        raise exception 'Invitation limit reached. Try again later.' using errcode = 'P0001';
    end if;

    insert into public.trip_invitations
        (trip_id, email, token, token_hash, invited_by, status, expires_at)
    values (
        p_trip_id, v_email, encode(extensions.digest(v_raw_token, 'sha256'), 'hex'),
        extensions.digest(v_raw_token, 'sha256'), auth.uid(), 'pending', now() + interval '72 hours'
    ) returning id into v_id;

    -- Deliberately generic: never reveal registration state or add membership before the
    -- recipient accepts. A production email provider can deliver v_raw_token server-side.
    return query select null::uuid, v_id, false;
end;
$$;

-- Edge-Function-only variant that returns the raw token for immediate delivery. The
-- mobile client cannot call this function and never receives the bearer token.
create or replace function public.create_email_invitation_for_delivery(
    p_actor_id uuid,
    p_trip_id uuid,
    p_email text
)
returns table(
    invitation_id uuid,
    token text,
    trip_name text,
    inviter_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_email text := lower(btrim(p_email));
    v_id uuid;
    v_raw_token text := encode(extensions.gen_random_bytes(24), 'hex');
    v_target_id uuid;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'Service role required.' using errcode = '42501';
    end if;
    if p_actor_id is null or v_email is null
       or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}$'
       or length(v_email) > 254 then
        raise exception 'Invitation data is invalid.' using errcode = '22023';
    end if;
    if not public.is_trip_owner(p_trip_id, p_actor_id) then
        raise exception 'Only the trip owner can invite members.' using errcode = '42501';
    end if;
    if (select count(*) from public.trip_invitations
        where invited_by = p_actor_id and created_at > now() - interval '1 hour') >= 30 then
        raise exception 'Invitation limit reached. Try again later.' using errcode = 'P0001';
    end if;

    -- Silently suppress delivery across a block. The Edge Function returns the same
    -- generic response, so the inviter cannot use this path to enumerate accounts.
    select p.user_id into v_target_id
      from public.profiles p where lower(p.email) = v_email;
    if v_target_id is not null and public.has_block_between(p_actor_id, v_target_id) then
        return;
    end if;

    insert into public.trip_invitations
        (trip_id, email, token, token_hash, invited_by, status, expires_at)
    values (
        p_trip_id, v_email, encode(extensions.digest(v_raw_token, 'sha256'), 'hex'),
        extensions.digest(v_raw_token, 'sha256'), p_actor_id, 'pending', now() + interval '72 hours'
    ) returning id into v_id;

    return query
    select v_id,
           v_raw_token,
           coalesce(t.name, t.metadata->>'name', 'Trip'),
           coalesce(nullif(p.display_name, ''), 'A TripSplit member')
      from public.trips t
      left join public.profiles p on p.user_id = p_actor_id
     where t.id = p_trip_id;
end;
$$;

revoke all on function public.create_email_invitation_for_delivery(uuid, uuid, text)
    from public, anon, authenticated;
grant execute on function public.create_email_invitation_for_delivery(uuid, uuid, text)
    to service_role;

create or replace function public.create_trip_invitation_link(p_trip_id uuid)
returns table(invitation_id uuid, token text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id uuid;
    v_raw_token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if not public.is_trip_owner(p_trip_id, auth.uid()) then
        raise exception 'Only the trip owner can invite members.' using errcode = '42501';
    end if;
    if (select count(*) from public.trip_invitations
        where invited_by = auth.uid() and created_at > now() - interval '1 hour') >= 30 then
        raise exception 'Invitation limit reached. Try again later.' using errcode = 'P0001';
    end if;
    insert into public.trip_invitations
        (trip_id, email, token, token_hash, invited_by, status, expires_at)
    values (
        p_trip_id, null, encode(extensions.digest(v_raw_token, 'sha256'), 'hex'),
        extensions.digest(v_raw_token, 'sha256'), auth.uid(), 'pending', now() + interval '72 hours'
    ) returning id into v_id;
    return query select v_id, v_raw_token;
end;
$$;

create or replace function public.preview_trip_invitation(p_token text)
returns table(trip_name text, inviter_name text, expires_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if p_token is null or p_token !~ '^[a-f0-9]{36,64}$' then
        raise exception 'This invitation link is invalid or has expired.' using errcode = '22023';
    end if;
    return query
    select coalesce(t.name, t.metadata->>'name', 'Trip'),
           coalesce(nullif(p.display_name, ''), 'A TripSplit member'),
           i.expires_at
    from public.trip_invitations i
    join public.trips t on t.id = i.trip_id
    left join public.profiles p on p.user_id = i.invited_by
    where i.token_hash = extensions.digest(p_token, 'sha256')
      and i.status = 'pending' and i.expires_at > now()
      and not public.has_block_between(auth.uid(), i.invited_by)
      and (i.email is null or lower(i.email) = (
          select lower(email) from public.profiles where user_id = auth.uid()
      ));
    if not found then
        raise exception 'This invitation link is invalid or has expired.' using errcode = 'P0002';
    end if;
end;
$$;

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
    select lower(email) into v_current_email from public.profiles where user_id = auth.uid();
    if v_invitation.email is not null and lower(v_invitation.email) <> v_current_email then
        raise exception 'This invitation link is invalid or has expired.' using errcode = '42501';
    end if;
    insert into public.trip_members (trip_id, user_id, role)
    values (v_invitation.trip_id, auth.uid(), 'member')
    on conflict on constraint trip_members_pkey do nothing;
    delete from public.trip_removed_members
     where trip_id = v_invitation.trip_id and user_id = auth.uid();
    update public.trip_invitations
       set status = 'accepted', accepted_at = now(),
           email = coalesce(email, v_current_email)
     where id = v_invitation.id and status = 'pending';
    if not found then raise exception 'This invitation link is invalid or has expired.' using errcode = 'P0002'; end if;
    return query select v_invitation.trip_id;
end;
$$;

create or replace function public.decline_trip_invitation(p_token text)
returns void
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
    if not found then raise exception 'This invitation link is invalid or has expired.' using errcode = 'P0002'; end if;
    select lower(email) into v_current_email from public.profiles where user_id = auth.uid();
    if v_invitation.email is not null and lower(v_invitation.email) <> v_current_email then
        raise exception 'This invitation link is invalid or has expired.' using errcode = '42501';
    end if;
    update public.trip_invitations set status = 'declined'
     where id = v_invitation.id and status = 'pending';
end;
$$;

create or replace function public.revoke_trip_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    update public.trip_invitations i
       set status = 'revoked'
     where i.id = p_invitation_id
       and i.status = 'pending'
       and exists (
           select 1 from public.trips t
           where t.id = i.trip_id and t.user_id = auth.uid()
       );
    if not found then raise exception 'This invitation is no longer available.' using errcode = 'P0002'; end if;
end;
$$;

revoke all on function public.preview_trip_invitation(text) from public, anon;
revoke all on function public.decline_trip_invitation(text) from public, anon;
revoke all on function public.revoke_trip_invitation(uuid) from public, anon;
grant execute on function public.preview_trip_invitation(text) to authenticated;
grant execute on function public.decline_trip_invitation(text) to authenticated;
grant execute on function public.revoke_trip_invitation(uuid) to authenticated;

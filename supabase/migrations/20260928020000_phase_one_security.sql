-- Phase 1: profile identity is server-owned; email invitations use verified Auth
-- identity, and every friends projection respects the bio visibility preference.
revoke update on table public.profiles from public, anon, authenticated;
-- Remove any historical column grants as well as the table-wide grant.
do $$
declare v_columns text;
begin
    select string_agg(quote_ident(attname), ', ') into v_columns
    from pg_attribute where attrelid = 'public.profiles'::regclass
      and attnum > 0 and not attisdropped;
    execute 'revoke update (' || v_columns || ') on public.profiles from public, anon, authenticated';
end;
$$;
grant update (
    display_name, date_of_birth, bio, avatar_path, visited_places,
    saved_place_keys, saved_map_places, saved_destination_ids,
    profile_visibility, showcase
) on public.profiles to authenticated;


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
          select lower(u.email) from auth.users u
          where u.id = auth.uid() and u.email_confirmed_at is not null
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
    select lower(u.email) into v_current_email
      from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
    if v_invitation.email is not null and lower(v_invitation.email) is distinct from v_current_email then
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
    select lower(u.email) into v_current_email
      from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
    if v_invitation.email is not null and lower(v_invitation.email) is distinct from v_current_email then
        raise exception 'This invitation link is invalid or has expired.' using errcode = '42501';
    end if;
    update public.trip_invitations set status = 'declined'
     where id = v_invitation.id and status = 'pending';
end;
$$;

create or replace function public.friends_overview()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select jsonb_build_object(
        'friends', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userID', p.user_id,
                'displayName', coalesce(p.display_name, ''),
                'avatarPath', p.avatar_path,
                'bio', case when coalesce((p.profile_visibility->>'bio')::boolean, true)
                            then coalesce(p.bio, '') else '' end,
                'shareToken', p.share_token
            ) order by lower(coalesce(nullif(p.display_name, ''), p.email)))
            from public.friendships f
            join public.profiles p
              on p.user_id = case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
            where f.status = 'accepted'
              and (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
        ), '[]'::jsonb),
        'incoming', coalesce((
            select jsonb_agg(jsonb_build_object(
                'friendshipID', f.id,
                'userID', p.user_id,
                'displayName', coalesce(p.display_name, ''),
                'avatarPath', p.avatar_path,
                'bio', case when coalesce((p.profile_visibility->>'bio')::boolean, true)
                            then coalesce(p.bio, '') else '' end
            ) order by f.created_at desc)
            from public.friendships f
            join public.profiles p on p.user_id = f.requester_id
            where f.status = 'pending' and f.addressee_id = auth.uid()
        ), '[]'::jsonb),
        'outgoing', coalesce((
            select jsonb_agg(jsonb_build_object(
                'friendshipID', f.id,
                'userID', p.user_id,
                'displayName', coalesce(p.display_name, ''),
                'avatarPath', p.avatar_path
            ) order by f.created_at desc)
            from public.friendships f
            join public.profiles p on p.user_id = f.addressee_id
            where f.status = 'pending' and f.requester_id = auth.uid()
        ), '[]'::jsonb)
    );
$$;

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
    select u.id into v_target_id
      from auth.users u where lower(u.email) = v_email and u.email_confirmed_at is not null;
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

revoke all on function public.preview_trip_invitation(text) from public, anon;
revoke all on function public.accept_trip_invitation(text) from public, anon;
revoke all on function public.decline_trip_invitation(text) from public, anon;
revoke all on function public.friends_overview() from public, anon;
grant execute on function public.preview_trip_invitation(text) to authenticated;
grant execute on function public.accept_trip_invitation(text) to authenticated;
grant execute on function public.decline_trip_invitation(text) to authenticated;
grant execute on function public.friends_overview() to authenticated;
revoke all on function public.create_email_invitation_for_delivery(uuid, uuid, text)
    from public, anon, authenticated;
grant execute on function public.create_email_invitation_for_delivery(uuid, uuid, text) to service_role;
;

-- Qualify the conflict target through the named primary-key constraint. The function's
-- TABLE return column is also named `trip_id`, which otherwise makes PL/pgSQL resolve
-- the unqualified ON CONFLICT column ambiguously.
create or replace function public.accept_trip_invitation(p_token text)
returns table(trip_id uuid)
security definer
set search_path = public
as $$
declare
    invite_trip_id uuid;
    invite_email text;
    current_email text;
begin
    if auth.uid() is null then
        raise exception 'You must be signed in.';
    end if;
    if p_token is null or p_token !~ '^[a-f0-9]{36}$' then
        raise exception 'This invitation link is invalid or has been revoked.';
    end if;

    select i.trip_id, lower(i.email) into invite_trip_id, invite_email
    from public.trip_invitations i
    where i.token = p_token
      and i.status = 'pending'
      and i.expires_at > now();

    if invite_trip_id is null then
        raise exception 'This invitation link is invalid or has been revoked.';
    end if;

    select lower(p.email) into current_email
    from public.profiles p
    where p.user_id = auth.uid();

    if invite_email is not null and invite_email <> current_email then
        raise exception 'This invitation link is for a different account.';
    end if;

    insert into public.trip_members (trip_id, user_id, role)
    values (invite_trip_id, auth.uid(), 'member')
    on conflict on constraint trip_members_pkey do nothing;

    update public.trip_invitations i
    set status = 'accepted',
        accepted_at = coalesce(accepted_at, now()),
        email = coalesce(email, (select email from public.profiles where user_id = auth.uid()))
    where i.token = p_token;

    return query select invite_trip_id;
end;
$$ language plpgsql;

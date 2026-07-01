-- TripSplit — Supabase schema for cloud-syncing trips.
--
-- Run this once in your Supabase project:
--   Dashboard → SQL Editor → New query → paste → Run.
--
create extension if not exists pgcrypto;

-- Each trip (with its participants, budgets, and expenses) is stored as a single
-- JSON blob in the `data` column. Cross-account access is granted through the
-- `trip_members` table: the trip creator owns the row, and invited Supabase
-- users may read/update that same row once they are members.

create table if not exists public.trips (
    id         uuid primary key,
    user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
    data       jsonb not null,
    updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
    user_id    uuid primary key references auth.users (id) on delete cascade,
    email      text unique not null,
    updated_at timestamptz not null default now()
);

create table if not exists public.trip_members (
    trip_id    uuid not null references public.trips (id) on delete cascade,
    user_id    uuid not null references auth.users (id) on delete cascade,
    role       text not null default 'member' check (role in ('owner', 'member')),
    created_at timestamptz not null default now(),
    primary key (trip_id, user_id)
);

create table if not exists public.trip_invitations (
    id          uuid primary key default gen_random_uuid(),
    trip_id     uuid not null references public.trips (id) on delete cascade,
    email       text,
    token       text unique not null default encode(gen_random_bytes(18), 'hex'),
    invited_by  uuid not null references auth.users (id) on delete cascade,
    status      text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null default (now() + interval '14 days'),
    accepted_at timestamptz
);

alter table public.trip_invitations add column if not exists token text;
alter table public.trip_invitations alter column email drop not null;
update public.trip_invitations
set token = encode(gen_random_bytes(18), 'hex')
where token is null;
alter table public.trip_invitations alter column token set not null;
alter table public.trip_invitations alter column token set default encode(gen_random_bytes(18), 'hex');
alter table public.trip_invitations add column if not exists expires_at timestamptz;
update public.trip_invitations
set expires_at = coalesce(expires_at, created_at + interval '14 days', now() + interval '14 days');
alter table public.trip_invitations alter column expires_at set default (now() + interval '14 days');
alter table public.trip_invitations alter column expires_at set not null;
create unique index if not exists trip_invitations_token_idx on public.trip_invitations (token);

create index if not exists trip_members_user_id_idx on public.trip_members (user_id);
create index if not exists trip_invitations_email_idx on public.trip_invitations (lower(email));

-- Keep updated_at fresh on every upsert so fetches can order newest-first.
create or replace function public.set_trips_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trips_set_updated_at on public.trips;
create trigger trips_set_updated_at
    before insert or update on public.trips
    for each row execute function public.set_trips_updated_at();

create or replace function public.set_profiles_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
    before update on public.profiles
    for each row execute function public.set_profiles_updated_at();

create or replace function public.handle_new_user_profile()
returns trigger
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id, email)
    values (new.id, lower(new.email))
    on conflict (user_id) do update set email = excluded.email;
    return new;
end;
$$ language plpgsql;

drop trigger if exists auth_users_create_profile on auth.users;
create trigger auth_users_create_profile
    after insert or update of email on auth.users
    for each row execute function public.handle_new_user_profile();

insert into public.profiles (user_id, email)
select id, lower(email)
from auth.users
where email is not null
on conflict (user_id) do update set email = excluded.email;

create or replace function public.is_trip_member(p_trip_id uuid)
returns boolean
security definer
set search_path = public
as $$
begin
    return exists (
        select 1
        from public.trip_members tm
        where tm.trip_id = p_trip_id
          and tm.user_id = auth.uid()
    );
end;
$$ language plpgsql stable;

create or replace function public.ensure_trip_owner_membership()
returns trigger
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'You must be signed in.';
    end if;

    insert into public.trip_members (trip_id, user_id, role)
    values (new.id, new.user_id, 'owner')
    on conflict (trip_id, user_id) do update set role = 'owner';
    return new;
end;
$$ language plpgsql;

drop trigger if exists trips_create_owner_membership on public.trips;
create trigger trips_create_owner_membership
    after insert on public.trips
    for each row execute function public.ensure_trip_owner_membership();

insert into public.trip_members (trip_id, user_id, role)
select id, user_id, 'owner'
from public.trips
on conflict (trip_id, user_id) do update set role = 'owner';

create or replace function public.invite_trip_member(p_trip_id uuid, p_email text)
returns table(member_user_id uuid, invitation_id uuid, accepted boolean)
security definer
set search_path = public
as $$
declare
    normalized_email text := lower(trim(p_email));
    target_user_id uuid;
    invite_id uuid;
begin
    if auth.uid() is null then
        raise exception 'You must be signed in.';
    end if;
    if normalized_email is null
       or normalized_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
       or length(normalized_email) > 254 then
        raise exception 'Enter a valid email address.';
    end if;

    if not exists (
        select 1
        from public.trips t
        where t.id = p_trip_id
          and t.user_id = auth.uid()
    ) then
        raise exception 'Only the trip owner can invite members.';
    end if;

    select user_id into target_user_id
    from public.profiles
    where email = normalized_email;

    insert into public.trip_invitations (trip_id, email, invited_by, status, accepted_at)
    values (
        p_trip_id,
        normalized_email,
        auth.uid(),
        case when target_user_id is null then 'pending' else 'accepted' end,
        case when target_user_id is null then null else now() end
    )
    returning id into invite_id;

    if target_user_id is not null then
        insert into public.trip_members (trip_id, user_id, role)
        values (p_trip_id, target_user_id, 'member')
        on conflict (trip_id, user_id) do nothing;
    end if;

    return query select target_user_id, invite_id, target_user_id is not null;
end;
$$ language plpgsql;

create or replace function public.create_trip_invitation_link(p_trip_id uuid)
returns table(invitation_id uuid, token text)
security definer
set search_path = public
as $$
declare
    invite_id uuid;
    invite_token text;
begin
    if auth.uid() is null then
        raise exception 'You must be signed in.';
    end if;

    if not exists (
        select 1
        from public.trips t
        where t.id = p_trip_id
          and t.user_id = auth.uid()
    ) then
        raise exception 'Only the trip owner can invite members.';
    end if;

    insert into public.trip_invitations (trip_id, email, invited_by, status)
    values (p_trip_id, null, auth.uid(), 'pending')
    returning trip_invitations.id, trip_invitations.token into invite_id, invite_token;

    return query select invite_id, invite_token;
end;
$$ language plpgsql;

create or replace function public.accept_trip_invitation(p_token text)
returns table(trip_id uuid)
security definer
set search_path = public
as $$
declare
    invite_trip_id uuid;
begin
    if auth.uid() is null then
        raise exception 'You must be signed in.';
    end if;
    if p_token is null or p_token !~ '^[a-f0-9]{36}$' then
        raise exception 'This invitation link is invalid or has been revoked.';
    end if;

    select i.trip_id into invite_trip_id
    from public.trip_invitations i
    where i.token = p_token
      and i.status = 'pending'
      and i.expires_at > now();

    if invite_trip_id is null then
        raise exception 'This invitation link is invalid or has been revoked.';
    end if;

    insert into public.trip_members (trip_id, user_id, role)
    values (invite_trip_id, auth.uid(), 'member')
    on conflict (trip_id, user_id) do nothing;

    update public.trip_invitations i
    set status = 'accepted',
        accepted_at = coalesce(accepted_at, now()),
        email = coalesce(email, (select email from public.profiles where user_id = auth.uid()))
    where i.token = p_token;

    return query select invite_trip_id;
end;
$$ language plpgsql;

-- Row-level security: users may read/write trips through membership.
alter table public.trips enable row level security;
alter table public.profiles enable row level security;
alter table public.trip_members enable row level security;
alter table public.trip_invitations enable row level security;

drop policy if exists "Users manage their own trips" on public.trips;
drop policy if exists "Trip members can read trips" on public.trips;
create policy "Trip members can read trips"
    on public.trips for select
    using (public.is_trip_member(id));

drop policy if exists "Users create owned trips" on public.trips;
create policy "Users create owned trips"
    on public.trips for insert
    with check (auth.uid() = user_id);

drop policy if exists "Trip members can update trips" on public.trips;
create policy "Trip members can update trips"
    on public.trips for update
    using (public.is_trip_member(id))
    with check (public.is_trip_member(id));

drop policy if exists "Owners can delete trips" on public.trips;
create policy "Owners can delete trips"
    on public.trips for delete
    using (auth.uid() = user_id);

drop policy if exists "Authenticated users can find profiles by email" on public.profiles;
drop policy if exists "Users can view their own profile" on public.profiles;
create policy "Users can view their own profile"
    on public.profiles for select
    using (auth.uid() = user_id);

drop policy if exists "Users update their own profile" on public.profiles;
create policy "Users update their own profile"
    on public.profiles for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "Trip members can view memberships" on public.trip_members;
create policy "Trip members can view memberships"
    on public.trip_members for select
    using (public.is_trip_member(trip_id));

drop policy if exists "Trip members can add memberships" on public.trip_members;

drop policy if exists "Trip members can view invitations" on public.trip_invitations;
create policy "Trip members can view invitations"
    on public.trip_invitations for select
    using (public.is_trip_member(trip_id));

drop policy if exists "Trip members can create invitations" on public.trip_invitations;
create policy "Trip members can create invitations"
    on public.trip_invitations for insert
    with check (public.is_trip_member(trip_id) and auth.uid() = invited_by);

-- Receipt image storage ------------------------------------------------------
--
-- Receipt photos, trip covers, and avatars are uploaded to a PRIVATE `receipts` bucket;
-- each file is namespaced under the uploader's user id ("<auth.uid()>/<file>.jpg"). The
-- bucket is not public, so nothing is world-readable: the client stores the object path
-- and mints a short-lived signed URL on demand to display an image. Reads are limited to
-- authenticated users (so any trip member can sign another member's cover/avatar/receipt),
-- while writes/updates/deletes remain restricted to the owner via the leading-folder
-- convention.

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do update set public = false;

-- Older deployments created this bucket as public with an "Anyone can view" policy; drop
-- it so anonymous, permanent access is revoked.
drop policy if exists "Anyone can view receipts" on storage.objects;

drop policy if exists "Authenticated users can view receipts" on storage.objects;
create policy "Authenticated users can view receipts"
    on storage.objects for select
    to authenticated
    using (bucket_id = 'receipts');

drop policy if exists "Users upload their own receipts" on storage.objects;
create policy "Users upload their own receipts"
    on storage.objects for insert
    with check (
        bucket_id = 'receipts'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

drop policy if exists "Users update their own receipts" on storage.objects;
create policy "Users update their own receipts"
    on storage.objects for update
    using (
        bucket_id = 'receipts'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

drop policy if exists "Users delete their own receipts" on storage.objects;
create policy "Users delete their own receipts"
    on storage.objects for delete
    using (
        bucket_id = 'receipts'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- Receipt-scan rate limiting -------------------------------------------------
--
-- The `parse-receipt` Edge Function proxies the receipt-parsing LLM call with a
-- server-side Gemini key. To bound cost/abuse, each call records an event and is rejected
-- once a user exceeds the per-window limit. The events table has NO RLS policies, so it is
-- inaccessible to clients directly; the only way in is the SECURITY DEFINER function below,
-- which is scoped to `auth.uid()` and granted to authenticated users only.

create table if not exists public.receipt_scan_events (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users (id) on delete cascade,
    created_at timestamptz not null default now()
);

create index if not exists receipt_scan_events_user_time_idx
    on public.receipt_scan_events (user_id, created_at desc);

alter table public.receipt_scan_events enable row level security;
-- Intentionally no policies: RLS denies all direct client access. Only
-- record_receipt_scan() (security definer) reads/writes this table.

create or replace function public.record_receipt_scan(p_limit int, p_window_seconds int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid   uuid := auth.uid();
    v_count int;
begin
    -- Only a signed-in user has a uid; anonymous/anon-key callers are denied.
    if v_uid is null then
        return false;
    end if;

    -- Opportunistic cleanup so the table stays small (rows well outside the window are
    -- no longer relevant to the limit).
    delete from public.receipt_scan_events
    where user_id = v_uid
      and created_at < now() - make_interval(secs => p_window_seconds * 4);

    select count(*) into v_count
    from public.receipt_scan_events
    where user_id = v_uid
      and created_at > now() - make_interval(secs => p_window_seconds);

    if v_count >= p_limit then
        return false;
    end if;

    insert into public.receipt_scan_events (user_id) values (v_uid);
    return true;
end;
$$;

revoke all on function public.record_receipt_scan(int, int) from public, anon;
grant execute on function public.record_receipt_scan(int, int) to authenticated;

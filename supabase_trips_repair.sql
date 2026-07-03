-- TripSplit trip-sync repair.
--
-- Run this in Supabase Dashboard -> SQL Editor if cloud trip saves fail with:
--   403 / 42501 / "new row violates row-level security policy for table trips"
--
-- This repairs the trip tables, policies, owner-membership trigger, and the RPC
-- used by the app to save trips. It does not delete existing trips.

create extension if not exists pgcrypto;

create table if not exists public.trips (
    id         uuid primary key,
    user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
    data       jsonb not null,
    updated_at timestamptz not null default now()
);

alter table public.trips add column if not exists user_id uuid references auth.users (id) on delete cascade;
alter table public.trips alter column user_id set default auth.uid();
alter table public.trips add column if not exists data jsonb;
alter table public.trips alter column data set not null;
alter table public.trips add column if not exists updated_at timestamptz not null default now();

create table if not exists public.trip_members (
    trip_id    uuid not null references public.trips (id) on delete cascade,
    user_id    uuid not null references auth.users (id) on delete cascade,
    role       text not null default 'member' check (role in ('owner', 'member')),
    created_at timestamptz not null default now(),
    primary key (trip_id, user_id)
);

create index if not exists trip_members_user_id_idx on public.trip_members (user_id);

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
where user_id is not null
on conflict (trip_id, user_id) do update set role = 'owner';

create or replace function public.upsert_trip(p_id uuid, p_user_id uuid, p_data jsonb)
returns void
security definer
set search_path = public
as $$
declare
    v_uid uuid := auth.uid();
    v_owner uuid;
begin
    if v_uid is null then
        raise exception 'You must be signed in.';
    end if;

    select user_id into v_owner
    from public.trips
    where id = p_id;

    if v_owner is null then
        if p_user_id <> v_uid then
            raise exception 'Trip owner must be the signed-in user.';
        end if;

        insert into public.trips (id, user_id, data)
        values (p_id, v_uid, p_data);

        insert into public.trip_members (trip_id, user_id, role)
        values (p_id, v_uid, 'owner')
        on conflict (trip_id, user_id) do update set role = 'owner';
        return;
    end if;

    if not exists (
        select 1
        from public.trip_members tm
        where tm.trip_id = p_id
          and tm.user_id = v_uid
    ) then
        raise exception 'You are not a member of this trip.';
    end if;

    update public.trips
    set data = p_data
    where id = p_id;
end;
$$ language plpgsql;

grant execute on function public.upsert_trip(uuid, uuid, jsonb) to authenticated;

alter table public.trips enable row level security;
alter table public.trip_members enable row level security;

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

drop policy if exists "Trip members can view memberships" on public.trip_members;
create policy "Trip members can view memberships"
    on public.trip_members for select
    using (public.is_trip_member(trip_id));

-- Optional reset if you want to wipe only synced trip data and start clean:
-- truncate table public.trip_invitations, public.trip_members, public.trips cascade;

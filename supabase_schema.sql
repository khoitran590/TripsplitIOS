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

alter table public.trips add column if not exists user_id uuid references auth.users (id) on delete cascade;
alter table public.trips alter column user_id set default auth.uid();

create table if not exists public.profiles (
    user_id    uuid primary key references auth.users (id) on delete cascade,
    email      text unique not null,
    updated_at timestamptz not null default now()
);

-- Personal profile fields shown in Settings → Profile. The row itself is created by
-- the auth trigger below; the app only ever UPDATEs these columns for its own row.
-- `visited_places` is a JSON array of place-name strings ("where have they been").
alter table public.profiles add column if not exists display_name   text;
alter table public.profiles add column if not exists date_of_birth  date;
alter table public.profiles add column if not exists bio            text;
alter table public.profiles add column if not exists avatar_path    text;
alter table public.profiles add column if not exists visited_places jsonb not null default '[]'::jsonb;
-- Bookmarks that must survive reinstalls: map-place save keys and Explore destination ids.
alter table public.profiles add column if not exists saved_place_keys      jsonb not null default '[]'::jsonb;
alter table public.profiles add column if not exists saved_map_places      jsonb not null default '[]'::jsonb;
alter table public.profiles add column if not exists saved_destination_ids jsonb not null default '[]'::jsonb;

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
drop policy if exists "Owners can view invitations" on public.trip_invitations;
create policy "Owners can view invitations"
    on public.trip_invitations for select
    using (
        exists (
            select 1
            from public.trips t
            where t.id = trip_id
              and t.user_id = auth.uid()
        )
    );

drop policy if exists "Trip members can create invitations" on public.trip_invitations;
drop policy if exists "Owners can create invitations" on public.trip_invitations;
create policy "Owners can create invitations"
    on public.trip_invitations for insert
    with check (
        auth.uid() = invited_by
        and exists (
            select 1
            from public.trips t
            where t.id = trip_id
              and t.user_id = auth.uid()
        )
    );

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

-- Trip feed ------------------------------------------------------------------
--
-- Feed posts live in their OWN table (not the trip's JSON blob) so posting,
-- commenting, and reacting never race with expense edits: each post is one row,
-- and concurrent activity on different posts can't overwrite each other. Comments
-- and reactions stay as jsonb on the post row (they're only ever edited through
-- their post, and per-post last-write-wins matches the rest of the app).
-- Photo files follow the receipts-bucket convention ("<auth.uid()>/feed-*.jpg").

create table if not exists public.trip_feed_posts (
    id          uuid primary key,
    trip_id     uuid not null references public.trips (id) on delete cascade,
    author_id   uuid not null references auth.users (id) on delete cascade,
    author_name text not null default '',
    body        text not null default '',
    photo_paths jsonb not null default '[]'::jsonb,
    -- Optional place tag shown on the post ("Blue Bottle Coffee, Oakland").
    location_name text,
    comments    jsonb not null default '[]'::jsonb,
    reactions   jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

-- Upgrade path for databases created before location tags existed.
alter table public.trip_feed_posts add column if not exists location_name text;

create index if not exists trip_feed_posts_trip_created_idx
    on public.trip_feed_posts (trip_id, created_at desc);

drop trigger if exists trip_feed_posts_set_updated_at on public.trip_feed_posts;
create trigger trip_feed_posts_set_updated_at
    before update on public.trip_feed_posts
    for each row execute function public.set_trips_updated_at();

alter table public.trip_feed_posts enable row level security;

drop policy if exists "Trip members can read feed posts" on public.trip_feed_posts;
create policy "Trip members can read feed posts"
    on public.trip_feed_posts for select
    using (public.is_trip_member(trip_id));

drop policy if exists "Trip members create their own feed posts" on public.trip_feed_posts;
create policy "Trip members create their own feed posts"
    on public.trip_feed_posts for insert
    with check (
        auth.uid() = author_id
        and public.is_trip_member(trip_id)
        and length(author_name) <= 100
        and length(body) <= 10000
        and length(coalesce(location_name, '')) <= 200
        and case when jsonb_typeof(photo_paths) = 'array' then
            jsonb_array_length(photo_paths) <= 4
            and (nullif(btrim(body), '') is not null or jsonb_array_length(photo_paths) > 0)
            and not exists (
                select 1
                from jsonb_array_elements(photo_paths) as photos(photo)
                where jsonb_typeof(photo) <> 'string'
                   or photo #>> '{}' !~ (
                       '^' || auth.uid()::text || '/feed-' || id::text || '-[0-3][.]jpg$'
                   )
            )
        else false end
        and comments = '[]'::jsonb
        and reactions = '{}'::jsonb
    );

revoke insert on table public.trip_feed_posts from public, anon, authenticated;
grant insert (id, trip_id, author_id, author_name, body, photo_paths, location_name)
    on table public.trip_feed_posts to authenticated;

-- Direct row updates are author-only. Column grants below further limit those updates to
-- the editable body/location fields; interactions use update_feed_interactions(), which
-- verifies that each caller changes only their own comments and reactions.
drop policy if exists "Trip members can update feed posts" on public.trip_feed_posts;
drop policy if exists "Authors can update their own feed posts" on public.trip_feed_posts;
create policy "Authors can update their own feed posts"
    on public.trip_feed_posts for update
    using (auth.uid() = author_id and public.is_trip_member(trip_id))
    with check (
        auth.uid() = author_id
        and public.is_trip_member(trip_id)
        and length(body) <= 10000
        and length(coalesce(location_name, '')) <= 200
        and (nullif(btrim(body), '') is not null or jsonb_array_length(photo_paths) > 0)
    );

revoke update on table public.trip_feed_posts from public, anon, authenticated;
grant update (body, location_name) on table public.trip_feed_posts to authenticated;

-- Authors may delete their own posts; the trip owner may moderate any post.
drop policy if exists "Authors and trip owners can delete feed posts" on public.trip_feed_posts;
create policy "Authors and trip owners can delete feed posts"
    on public.trip_feed_posts for delete
    using (
        auth.uid() = author_id
        or exists (
            select 1
            from public.trips t
            where t.id = trip_id
              and t.user_id = auth.uid()
        )
    );

create or replace function public.update_feed_interactions(
    p_post_id uuid,
    p_comments jsonb,
    p_reactions jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_trip_id uuid;
    v_old_comments jsonb;
    v_old_reactions jsonb;
    v_comment jsonb;
    v_key text;
    v_value jsonb;
begin
    if v_uid is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;

    -- Serialize interaction updates per post. Stale clients are rejected below instead
    -- of being allowed to erase another member's concurrent activity.
    select trip_id, comments, reactions
      into v_trip_id, v_old_comments, v_old_reactions
      from public.trip_feed_posts
     where id = p_post_id
     for update;

    if not found then
        raise exception 'Feed post not found.' using errcode = 'P0002';
    end if;
    if not public.is_trip_member(v_trip_id) then
        raise exception 'You are not a member of this trip.' using errcode = '42501';
    end if;

    if jsonb_typeof(p_comments) is distinct from 'array'
       or jsonb_typeof(p_reactions) is distinct from 'object' then
        raise exception 'Invalid feed interactions.' using errcode = '22023';
    end if;
    if pg_column_size(p_comments) > 262144 or pg_column_size(p_reactions) > 65536 then
        raise exception 'Feed interactions are too large.' using errcode = '22001';
    end if;
    if jsonb_array_length(p_comments) > 500
       or (select count(*) from jsonb_object_keys(p_reactions)) > 50 then
        raise exception 'Too many feed interactions.' using errcode = '22001';
    end if;

    for v_comment in select value from jsonb_array_elements(p_comments)
    loop
        if jsonb_typeof(v_comment) <> 'object'
           or jsonb_typeof(v_comment->'id') is distinct from 'string'
           or jsonb_typeof(v_comment->'authorID') is distinct from 'string'
           or jsonb_typeof(v_comment->'text') is distinct from 'string'
           or jsonb_typeof(v_comment->'date') is distinct from 'string'
           or (v_comment ? 'authorName' and jsonb_typeof(v_comment->'authorName') <> 'string')
           or (v_comment ? 'editedAt' and jsonb_typeof(v_comment->'editedAt') not in ('string', 'null'))
           or coalesce(v_comment->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or coalesce(v_comment->>'authorID', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or nullif(btrim(v_comment->>'text'), '') is null
           or length(v_comment->>'text') > 2000
           or length(coalesce(v_comment->>'authorName', '')) > 100
           or coalesce(v_comment->>'date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
           or (jsonb_typeof(v_comment->'editedAt') = 'string'
               and (v_comment->>'editedAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$') then
            raise exception 'Invalid feed comment.' using errcode = '22023';
        end if;

        perform (v_comment->>'date')::timestamptz;
        if jsonb_typeof(v_comment->'editedAt') = 'string' then
            perform (v_comment->>'editedAt')::timestamptz;
        end if;
    end loop;
    if (
        select count(*) <> count(distinct value->>'id')
        from jsonb_array_elements(p_comments)
    ) then
        raise exception 'Duplicate feed comment id.' using errcode = '22023';
    end if;

    if exists (
        select 1
        from jsonb_array_elements(v_old_comments) as old_items(old_comment)
        where lower(old_comment->>'authorID') is distinct from v_uid::text
          and not exists (
              select 1 from jsonb_array_elements(p_comments) as new_items(new_comment)
              where new_comment->>'id' = old_comment->>'id'
                and new_comment = old_comment
          )
    ) or exists (
        select 1
        from jsonb_array_elements(p_comments) as new_items(new_comment)
        where lower(new_comment->>'authorID') is distinct from v_uid::text
          and not exists (
              select 1 from jsonb_array_elements(v_old_comments) as old_items(old_comment)
              where old_comment->>'id' = new_comment->>'id'
                and old_comment = new_comment
          )
    ) then
        raise exception 'You can only change your own comments.' using errcode = '42501';
    end if;

    for v_key, v_value in select key, value from jsonb_each(p_reactions)
    loop
        if length(v_key) < 1 or length(v_key) > 32 or jsonb_typeof(v_value) <> 'array'
           or jsonb_array_length(v_value) > 500
           or exists (
               select 1 from jsonb_array_elements_text(v_value) as reactors(reactor)
               where reactor !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           )
           or (
               select count(*) <> count(distinct reactor)
               from jsonb_array_elements_text(v_value) as reactors(reactor)
           ) then
            raise exception 'Invalid feed reactions.' using errcode = '22023';
        end if;
    end loop;

    if exists (
        select 1
        from (
            select old_key as key from jsonb_object_keys(v_old_reactions) as old_keys(old_key)
            union
            select new_key as key from jsonb_object_keys(p_reactions) as new_keys(new_key)
        ) keys
        where coalesce((
            select jsonb_agg(lower(reactor) order by lower(reactor))
            from jsonb_array_elements_text(coalesce(v_old_reactions->keys.key, '[]'::jsonb)) as reactors(reactor)
            where lower(reactor) <> v_uid::text
        ), '[]'::jsonb) <> coalesce((
            select jsonb_agg(lower(reactor) order by lower(reactor))
            from jsonb_array_elements_text(coalesce(p_reactions->keys.key, '[]'::jsonb)) as reactors(reactor)
            where lower(reactor) <> v_uid::text
        ), '[]'::jsonb)
    ) then
        raise exception 'You can only change your own reactions.' using errcode = '42501';
    end if;

    update public.trip_feed_posts
       set comments = p_comments,
           reactions = p_reactions
     where id = p_post_id;
end;
$$;

revoke all on function public.update_feed_interactions(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.update_feed_interactions(uuid, jsonb, jsonb) to authenticated;

-- AI usage rate limiting -----------------------------------------------------
--
-- The table keeps its original name for a zero-data-loss migration, but now holds
-- feature-scoped AI usage. Edge Functions reserve capacity before paid work and commit the
-- reservation only after success. Failed calls release their reservation, while concurrent
-- calls still count against the window until they finish or the reservation expires.
--
-- There are intentionally no RLS policies and the RPCs are service-role-only. The Edge
-- Functions authenticate the user's JWT, then use their injected service-role key to call
-- these RPCs with that verified user id. App clients cannot manufacture usage kinds or
-- pollute their own quota.

create table if not exists public.receipt_scan_events (
    id                     uuid primary key default gen_random_uuid(),
    user_id                uuid not null references auth.users (id) on delete cascade,
    kind                   text not null default 'unknown',
    status                 text not null default 'succeeded',
    created_at             timestamptz not null default now(),
    committed_at           timestamptz,
    reservation_expires_at timestamptz,
    constraint receipt_scan_events_kind_check
        check (kind in ('unknown', 'receipt', 'ocr', 'parse', 'itinerary')),
    constraint receipt_scan_events_status_check
        check (status in ('reserved', 'succeeded'))
);

-- Upgrade existing installations without renaming the table or dropping history.
alter table public.receipt_scan_events add column if not exists kind text not null default 'unknown';
alter table public.receipt_scan_events add column if not exists status text not null default 'succeeded';
alter table public.receipt_scan_events add column if not exists committed_at timestamptz;
alter table public.receipt_scan_events add column if not exists reservation_expires_at timestamptz;

update public.receipt_scan_events
   set committed_at = created_at
 where status = 'succeeded' and committed_at is null;

do $$
begin
    if not exists (
        select 1 from pg_constraint
         where conrelid = 'public.receipt_scan_events'::regclass
           and conname = 'receipt_scan_events_kind_check'
    ) then
        alter table public.receipt_scan_events
            add constraint receipt_scan_events_kind_check
            check (kind in ('unknown', 'receipt', 'ocr', 'parse', 'itinerary'));
    end if;
    if not exists (
        select 1 from pg_constraint
         where conrelid = 'public.receipt_scan_events'::regclass
           and conname = 'receipt_scan_events_status_check'
    ) then
        alter table public.receipt_scan_events
            add constraint receipt_scan_events_status_check
            check (status in ('reserved', 'succeeded'));
    end if;
end;
$$;

drop index if exists public.receipt_scan_events_user_time_idx;
create index if not exists receipt_scan_events_user_kind_time_idx
    on public.receipt_scan_events (user_id, kind, committed_at desc, created_at desc);

alter table public.receipt_scan_events enable row level security;
-- Intentionally no policies: RLS denies all direct client access.

create or replace function public.reserve_ai_usage(
    p_user_id uuid,
    p_kind text,
    p_limit int,
    p_window_seconds int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_count int;
    v_id uuid;
    v_retry_after int := 0;
    v_reservation_seconds int;
begin
    if p_user_id is null
       or p_kind not in ('ocr', 'parse', 'itinerary')
       or p_limit < 1 or p_limit > 100
       or p_window_seconds < 10 or p_window_seconds > 3600 then
        raise exception 'Invalid AI usage reservation arguments' using errcode = '22023';
    end if;

    -- Itinerary generation can legitimately take several minutes; receipt calls should
    -- release abandoned reservations sooner.
    v_reservation_seconds := case when p_kind = 'itinerary' then 600 else 180 end;

    -- Serialize each user's feature bucket so concurrent requests cannot over-reserve.
    perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':' || p_kind, 0));

    -- Abandoned work stops consuming capacity after its short lease. Successful rows are
    -- retained for 30 days so Supabase logs/SQL metrics can be used to retune limits.
    delete from public.receipt_scan_events
     where user_id = p_user_id
       and kind = p_kind
       and ((status = 'reserved' and reservation_expires_at <= now())
         or (status = 'succeeded' and coalesce(committed_at, created_at) < now() - interval '30 days'));

    select count(*) into v_count
      from public.receipt_scan_events
     where user_id = p_user_id
       and kind = p_kind
       and ((status = 'succeeded'
             and coalesce(committed_at, created_at) > now() - make_interval(secs => p_window_seconds))
         or (status = 'reserved' and reservation_expires_at > now()));

    if v_count >= p_limit then
        select greatest(1, ceil(extract(epoch from min(
            case
                when status = 'reserved' then reservation_expires_at
                else coalesce(committed_at, created_at) + make_interval(secs => p_window_seconds)
            end
        ) - now()))::int)
          into v_retry_after
          from public.receipt_scan_events
         where user_id = p_user_id
           and kind = p_kind
           and ((status = 'succeeded'
                 and coalesce(committed_at, created_at) > now() - make_interval(secs => p_window_seconds))
             or (status = 'reserved' and reservation_expires_at > now()));

        return jsonb_build_object(
            'allowed', false,
            'feature', p_kind,
            'limit', p_limit,
            'remaining', 0,
            'windowSeconds', p_window_seconds,
            'retryAfterSeconds', coalesce(v_retry_after, 1)
        );
    end if;

    insert into public.receipt_scan_events (
        user_id, kind, status, reservation_expires_at
    ) values (
        p_user_id, p_kind, 'reserved', now() + make_interval(secs => v_reservation_seconds)
    ) returning id into v_id;

    return jsonb_build_object(
        'allowed', true,
        'reservationId', v_id,
        'feature', p_kind,
        'limit', p_limit,
        'remaining', greatest(p_limit - v_count - 1, 0),
        'windowSeconds', p_window_seconds,
        'retryAfterSeconds', 0
    );
end;
$$;

create or replace function public.complete_ai_usage(
    p_reservation_id uuid,
    p_succeeded boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_status text;
begin
    select status into v_status
      from public.receipt_scan_events
     where id = p_reservation_id
     for update;

    if v_status is distinct from 'reserved' then
        return false;
    end if;

    if p_succeeded then
        update public.receipt_scan_events
           set status = 'succeeded',
               committed_at = now(),
               reservation_expires_at = null
         where id = p_reservation_id;
    else
        delete from public.receipt_scan_events where id = p_reservation_id;
    end if;
    return true;
end;
$$;

-- Remove the old authenticated-client entry point and expose the new contract only to
-- Edge Functions using the injected service-role key.
drop function if exists public.record_receipt_scan(int, int);
revoke all on function public.reserve_ai_usage(uuid, text, int, int) from public, anon, authenticated;
revoke all on function public.complete_ai_usage(uuid, boolean) from public, anon, authenticated;
grant execute on function public.reserve_ai_usage(uuid, text, int, int) to service_role;
grant execute on function public.complete_ai_usage(uuid, boolean) to service_role;

-- Normalized trip storage (B10) ---------------------------------------------
-- Keep this block identical to
-- `supabase/migrations/20260716000000_normalize_trip_storage.sql`.
-- B10: normalize the independently edited parts of a trip while retaining `trips.data`
-- as a compatibility projection for older clients. All writes happen in one transaction.

alter table public.trips add column if not exists name text;
alter table public.trips add column if not exists currency_code text;
alter table public.trips add column if not exists metadata jsonb not null default '{}'::jsonb;

create table if not exists public.trip_expenses (
    id uuid primary key,
    trip_id uuid not null references public.trips (id) on delete cascade,
    payer_id uuid,
    amount double precision not null default 0,
    expense_date timestamptz,
    deleted_at timestamptz,
    payload jsonb not null,
    updated_at timestamptz not null default now(),
    unique (trip_id, id)
);

create table if not exists public.settlement_records (
    id uuid primary key,
    trip_id uuid not null references public.trips (id) on delete cascade,
    settlement_key text not null,
    amount double precision not null default 0,
    status text,
    record_date timestamptz,
    payload jsonb not null,
    updated_at timestamptz not null default now(),
    unique (trip_id, id)
);

create table if not exists public.expense_comments (
    id uuid primary key,
    trip_id uuid not null references public.trips (id) on delete cascade,
    expense_id uuid not null,
    author_id uuid,
    created_at timestamptz,
    edited_at timestamptz,
    payload jsonb not null,
    updated_at timestamptz not null default now(),
    unique (trip_id, id)
);

create index if not exists trip_expenses_trip_date_idx
    on public.trip_expenses (trip_id, expense_date desc);
create index if not exists trip_expenses_trip_deleted_idx
    on public.trip_expenses (trip_id, deleted_at);
create index if not exists settlement_records_trip_key_idx
    on public.settlement_records (trip_id, settlement_key, record_date);
create index if not exists expense_comments_expense_date_idx
    on public.expense_comments (trip_id, expense_id, created_at);

alter table public.trip_expenses enable row level security;
alter table public.settlement_records enable row level security;
alter table public.expense_comments enable row level security;

drop policy if exists "Trip members can read expenses" on public.trip_expenses;
create policy "Trip members can read expenses" on public.trip_expenses
    for select using (public.is_trip_member(trip_id));
drop policy if exists "Trip members can write expenses" on public.trip_expenses;
create policy "Trip members can write expenses" on public.trip_expenses
    for all using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

drop policy if exists "Trip members can read settlements" on public.settlement_records;
create policy "Trip members can read settlements" on public.settlement_records
    for select using (public.is_trip_member(trip_id));
drop policy if exists "Trip members can write settlements" on public.settlement_records;
create policy "Trip members can write settlements" on public.settlement_records
    for all using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

drop policy if exists "Trip members can read expense comments" on public.expense_comments;
create policy "Trip members can read expense comments" on public.expense_comments
    for select using (public.is_trip_member(trip_id));
drop policy if exists "Trip members can write expense comments" on public.expense_comments;
create policy "Trip members can write expense comments" on public.expense_comments
    for all using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

-- Reconstruct the Codable Trip document. This is used both by new table-backed reads
-- and to keep the old blob current during the compatibility window.
create or replace function public.trip_document(p_trip_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select t.metadata || jsonb_build_object(
        'expenses', coalesce((
            select jsonb_agg(e.payload order by e.expense_date, e.id)
            from public.trip_expenses e
            where e.trip_id = t.id and e.deleted_at is null
        ), '[]'::jsonb),
        'deletedExpenses', coalesce((
            select jsonb_agg(e.payload order by e.deleted_at desc, e.id)
            from public.trip_expenses e
            where e.trip_id = t.id and e.deleted_at is not null
        ), '[]'::jsonb),
        'settlementRecords', coalesce((
            select jsonb_object_agg(grouped.settlement_key, grouped.records)
            from (
                select s.settlement_key,
                       jsonb_agg(s.payload order by s.record_date, s.id) as records
                from public.settlement_records s
                where s.trip_id = t.id
                group by s.settlement_key
            ) grouped
        ), '{}'::jsonb),
        'comments', coalesce((
            select jsonb_object_agg(grouped.expense_id::text, grouped.comments)
            from (
                select c.expense_id,
                       jsonb_agg(c.payload order by c.created_at, c.id) as comments
                from public.expense_comments c
                where c.trip_id = t.id
                group by c.expense_id
            ) grouped
        ), '{}'::jsonb)
    )
    from public.trips t
    where t.id = p_trip_id;
$$;

-- Applies only fields which differ between the caller's previous synced snapshot and
-- its new snapshot. Distinct child rows edited concurrently by another member survive.
create or replace function public.sync_trip_normalized(
    p_id uuid,
    p_user_id uuid,
    p_data jsonb,
    p_previous_data jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid uuid := auth.uid();
    v_owner uuid;
    v_metadata jsonb;
    v_previous_metadata jsonb;
    v_current_expenses jsonb;
    v_previous_expenses jsonb;
    v_current_settlements jsonb;
    v_previous_settlements jsonb;
    v_current_comments jsonb;
    v_previous_comments jsonb;
    v_item jsonb;
    v_previous_item jsonb;
    v_pair record;
    v_id uuid;
    v_document jsonb;
begin
    if v_uid is null then raise exception 'You must be signed in.'; end if;
    if p_data is null or jsonb_typeof(p_data) <> 'object' then
        raise exception 'Trip data must be a JSON object.';
    end if;

    -- Serialize writes only long enough to merge this delta with the latest rows.
    perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
    select user_id into v_owner from public.trips where id = p_id;
    if v_owner is null then
        if p_user_id <> v_uid then raise exception 'Trip owner must be the signed-in user.'; end if;
        insert into public.trips (id, user_id, data, metadata, name, currency_code)
        values (p_id, v_uid, '{}'::jsonb, '{}'::jsonb, p_data->>'name', p_data->>'currencyCode');
        insert into public.trip_members (trip_id, user_id, role)
        values (p_id, v_uid, 'owner')
        on conflict (trip_id, user_id) do update set role = 'owner';
    elsif not public.is_trip_member(p_id) then
        raise exception 'You are not a member of this trip.';
    end if;

    v_metadata := p_data - 'expenses' - 'deletedExpenses' - 'settlementRecords' - 'comments';
    v_previous_metadata := coalesce(p_previous_data, '{}'::jsonb)
        - 'expenses' - 'deletedExpenses' - 'settlementRecords' - 'comments';
    if p_previous_data is null or v_metadata is distinct from v_previous_metadata then
        update public.trips
        set metadata = v_metadata,
            name = p_data->>'name',
            currency_code = p_data->>'currencyCode'
        where id = p_id;
    end if;

    v_current_expenses := coalesce(p_data->'expenses', '[]'::jsonb)
        || coalesce(p_data->'deletedExpenses', '[]'::jsonb);
    v_previous_expenses := coalesce(p_previous_data->'expenses', '[]'::jsonb)
        || coalesce(p_previous_data->'deletedExpenses', '[]'::jsonb);
    for v_item in select value from jsonb_array_elements(v_current_expenses)
    loop
        if coalesce(v_item->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            raise exception 'Expense id is invalid.';
        end if;
        v_id := (v_item->>'id')::uuid;
        select value into v_previous_item
        from jsonb_array_elements(v_previous_expenses)
        where value->>'id' = v_item->>'id' limit 1;
        if p_previous_data is null or v_previous_item is distinct from v_item then
            insert into public.trip_expenses
                (id, trip_id, payer_id, amount, expense_date, deleted_at, payload, updated_at)
            values (
                v_id, p_id,
                case when coalesce(v_item->>'payerID', '') ~* '^[0-9a-f-]{36}$' then (v_item->>'payerID')::uuid end,
                coalesce((v_item->>'amount')::double precision, 0),
                nullif(v_item->>'date', '')::timestamptz,
                nullif(v_item->>'deletedAt', '')::timestamptz,
                v_item, now()
            )
            on conflict (id) do update set
                payer_id = excluded.payer_id, amount = excluded.amount,
                expense_date = excluded.expense_date, deleted_at = excluded.deleted_at,
                payload = excluded.payload, updated_at = now()
            where public.trip_expenses.trip_id = p_id;
        end if;
        v_previous_item := null;
    end loop;
    if p_previous_data is not null then
        delete from public.trip_expenses e
        where e.trip_id = p_id
          and exists (select 1 from jsonb_array_elements(v_previous_expenses) old where old->>'id' = e.id::text)
          and not exists (select 1 from jsonb_array_elements(v_current_expenses) cur where cur->>'id' = e.id::text);
    end if;

    v_current_settlements := coalesce(p_data->'settlementRecords', '{}'::jsonb);
    v_previous_settlements := coalesce(p_previous_data->'settlementRecords', '{}'::jsonb);
    for v_pair in select key as settlement_key, value as records from jsonb_each(v_current_settlements)
    loop
        for v_item in select value from jsonb_array_elements(v_pair.records)
        loop
            if coalesce(v_item->>'id', '') !~* '^[0-9a-f-]{36}$' then
                raise exception 'Settlement id is invalid.';
            end if;
            v_id := (v_item->>'id')::uuid;
            select prior_item into v_previous_item
            from jsonb_each(v_previous_settlements) pairs,
                 jsonb_array_elements(pairs.value) prior_item
            where pairs.key = v_pair.settlement_key and prior_item->>'id' = v_item->>'id' limit 1;
            if p_previous_data is null or v_previous_item is distinct from v_item then
                insert into public.settlement_records
                    (id, trip_id, settlement_key, amount, status, record_date, payload, updated_at)
                values (
                    v_id, p_id, v_pair.settlement_key,
                    coalesce((v_item->>'amount')::double precision, 0), v_item->>'status',
                    nullif(v_item->>'date', '')::timestamptz, v_item, now()
                )
                on conflict (id) do update set
                    settlement_key = excluded.settlement_key, amount = excluded.amount,
                    status = excluded.status, record_date = excluded.record_date,
                    payload = excluded.payload, updated_at = now()
                where public.settlement_records.trip_id = p_id;
            end if;
            v_previous_item := null;
        end loop;
    end loop;
    if p_previous_data is not null then
        delete from public.settlement_records s
        where s.trip_id = p_id
          and exists (
              select 1 from jsonb_each(v_previous_settlements) pairs,
                   jsonb_array_elements(pairs.value) old where old->>'id' = s.id::text
          )
          and not exists (
              select 1 from jsonb_each(v_current_settlements) pairs,
                   jsonb_array_elements(pairs.value) cur where cur->>'id' = s.id::text
          );
    end if;

    v_current_comments := coalesce(p_data->'comments', '{}'::jsonb);
    v_previous_comments := coalesce(p_previous_data->'comments', '{}'::jsonb);
    for v_pair in select key as expense_id, value as comments from jsonb_each(v_current_comments)
    loop
        if v_pair.expense_id !~* '^[0-9a-f-]{36}$' then continue; end if;
        for v_item in select value from jsonb_array_elements(v_pair.comments)
        loop
            if coalesce(v_item->>'id', '') !~* '^[0-9a-f-]{36}$' then
                raise exception 'Comment id is invalid.';
            end if;
            v_id := (v_item->>'id')::uuid;
            select prior_item into v_previous_item
            from jsonb_each(v_previous_comments) pairs,
                 jsonb_array_elements(pairs.value) prior_item
            where pairs.key = v_pair.expense_id and prior_item->>'id' = v_item->>'id' limit 1;
            if p_previous_data is null or v_previous_item is distinct from v_item then
                insert into public.expense_comments
                    (id, trip_id, expense_id, author_id, created_at, edited_at, payload, updated_at)
                values (
                    v_id, p_id, v_pair.expense_id::uuid,
                    case when coalesce(v_item->>'authorID', '') ~* '^[0-9a-f-]{36}$' then (v_item->>'authorID')::uuid end,
                    nullif(v_item->>'date', '')::timestamptz,
                    nullif(v_item->>'editedAt', '')::timestamptz, v_item, now()
                )
                on conflict (id) do update set
                    expense_id = excluded.expense_id, author_id = excluded.author_id,
                    created_at = excluded.created_at, edited_at = excluded.edited_at,
                    payload = excluded.payload, updated_at = now()
                where public.expense_comments.trip_id = p_id;
            end if;
            v_previous_item := null;
        end loop;
    end loop;
    if p_previous_data is not null then
        delete from public.expense_comments c
        where c.trip_id = p_id
          and exists (
              select 1 from jsonb_each(v_previous_comments) pairs,
                   jsonb_array_elements(pairs.value) old where old->>'id' = c.id::text
          )
          and not exists (
              select 1 from jsonb_each(v_current_comments) pairs,
                   jsonb_array_elements(pairs.value) cur where cur->>'id' = c.id::text
          );
    end if;

    v_document := public.trip_document(p_id);
    update public.trips set data = v_document where id = p_id;
    return v_document;
end;
$$;

-- Idempotent backfill. With no previous snapshot, the function imports the complete
-- compatibility document into normalized rows and immediately verifies its projection.
create or replace function public.backfill_normalized_trip_storage()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_trip record;
    v_count integer := 0;
begin
    for v_trip in select id, user_id, data from public.trips loop
        perform set_config('request.jwt.claim.sub', v_trip.user_id::text, true);
        perform public.sync_trip_normalized(v_trip.id, v_trip.user_id, v_trip.data, null);
        v_count := v_count + 1;
    end loop;
    return v_count;
end;
$$;

-- New clients read a table-backed projection. Membership is checked inside the SECURITY
-- DEFINER function because PostgREST executes the function rather than selecting tables.
create or replace function public.fetch_normalized_trips()
returns table(data jsonb, updated_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
    select public.trip_document(t.id), t.updated_at
    from public.trips t
    where public.is_trip_member(t.id)
    order by t.updated_at desc;
$$;

revoke all on function public.trip_document(uuid) from public, anon, authenticated;
revoke all on function public.sync_trip_normalized(uuid, uuid, jsonb, jsonb) from public, anon;
grant execute on function public.sync_trip_normalized(uuid, uuid, jsonb, jsonb) to authenticated;
revoke all on function public.backfill_normalized_trip_storage() from public, anon, authenticated;
revoke all on function public.fetch_normalized_trips() from public, anon;
grant execute on function public.fetch_normalized_trips() to authenticated;

-- Run as the migration owner so legacy rows are ready before table-backed reads begin.
select public.backfill_normalized_trip_storage();

-- Profile sharing & friends --------------------------------------------------
--
-- A user can share their profile with a stable, unguessable link
-- (tripsplit://profile?token=<share_token>). Anyone who opens the link views the
-- profile through profile_by_token() — a SECURITY DEFINER function, so a viewer who
-- isn't a trip member still sees the owner's name/bio/places and a lightweight trip
-- summary. Adding someone creates a pending row in `friendships`; the addressee
-- confirms before the two are connected. All reads/writes go through the RPCs below,
-- never direct table access, so no profile is exposed app-wide.

alter table public.profiles add column if not exists share_token text;
update public.profiles set share_token = encode(gen_random_bytes(18), 'hex') where share_token is null;
alter table public.profiles alter column share_token set default encode(gen_random_bytes(18), 'hex');
alter table public.profiles alter column share_token set not null;
create unique index if not exists profiles_share_token_idx on public.profiles (share_token);

create table if not exists public.friendships (
    id           uuid primary key default gen_random_uuid(),
    requester_id uuid not null references auth.users (id) on delete cascade,
    addressee_id uuid not null references auth.users (id) on delete cascade,
    status       text not null default 'pending' check (status in ('pending', 'accepted')),
    created_at   timestamptz not null default now(),
    responded_at timestamptz,
    constraint friendships_distinct check (requester_id <> addressee_id),
    unique (requester_id, addressee_id)
);

create index if not exists friendships_addressee_idx on public.friendships (addressee_id, status);
create index if not exists friendships_requester_idx on public.friendships (requester_id, status);

alter table public.friendships enable row level security;
-- Direct reads are limited to your own edges; all mutations flow through the RPCs.
drop policy if exists "Users view their friendships" on public.friendships;
create policy "Users view their friendships"
    on public.friendships for select
    using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- View a profile (and its trip summary) by its share token. SECURITY DEFINER so the
-- viewer need not be a trip member. `date_of_birth` is only ever stored when the owner
-- opted to show it, so returning it as-is respects that opt-in.
create or replace function public.profile_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_viewer uuid := auth.uid();
    v_owner uuid;
    v_friend_status text;
    v_result jsonb;
begin
    if p_token is null or p_token !~ '^[a-f0-9]{36}$' then
        raise exception 'This profile link is invalid.';
    end if;
    select user_id into v_owner from public.profiles where share_token = p_token;
    if v_owner is null then
        raise exception 'This profile link is invalid.';
    end if;

    if v_viewer is not null and v_viewer <> v_owner then
        select case
            when status = 'accepted' then 'accepted'
            when requester_id = v_viewer then 'requested' -- I sent it, awaiting them
            else 'incoming'                                -- they sent me one
        end into v_friend_status
        from public.friendships
        where (requester_id = v_viewer and addressee_id = v_owner)
           or (requester_id = v_owner and addressee_id = v_viewer)
        limit 1;
    end if;

    select jsonb_build_object(
        'userID', p.user_id,
        'isSelf', v_owner = v_viewer,
        'friendStatus', coalesce(v_friend_status, 'none'),
        'displayName', coalesce(p.display_name, ''),
        'avatarPath', p.avatar_path,
        'bio', coalesce(p.bio, ''),
        'dateOfBirth', p.date_of_birth,
        'visitedPlaces', coalesce(p.visited_places, '[]'::jsonb),
        'trips', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', t.id,
                'name', coalesce(t.name, t.metadata->>'name', 'Trip'),
                'location', t.metadata->>'location',
                'startDate', t.metadata->>'startDate',
                'endDate', t.metadata->>'endDate',
                'coverImageURL', t.metadata->>'coverImageURL'
            ) order by coalesce(t.metadata->>'startDate', '') desc)
            from public.trips t
            where t.user_id = p.user_id
        ), '[]'::jsonb)
    ) into v_result
    from public.profiles p
    where p.user_id = v_owner;

    return v_result;
end;
$$;

-- Send a friend request to the owner of a share token. If the owner already has a
-- pending request out to the viewer, this accepts it (mutual add). Returns the
-- resulting edge state: 'requested' (new pending) or 'accepted'.
create or replace function public.send_friend_request(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_viewer uuid := auth.uid();
    v_owner uuid;
    v_existing public.friendships%rowtype;
begin
    if v_viewer is null then raise exception 'You must be signed in.'; end if;
    if p_token is null or p_token !~ '^[a-f0-9]{36}$' then
        raise exception 'This profile link is invalid.';
    end if;
    select user_id into v_owner from public.profiles where share_token = p_token;
    if v_owner is null then raise exception 'This profile link is invalid.'; end if;
    if v_owner = v_viewer then raise exception 'You cannot add yourself.'; end if;

    select * into v_existing from public.friendships
    where requester_id = v_owner and addressee_id = v_viewer;
    if found then
        if v_existing.status = 'pending' then
            update public.friendships set status = 'accepted', responded_at = now()
            where id = v_existing.id;
        end if;
        return 'accepted';
    end if;

    select * into v_existing from public.friendships
    where requester_id = v_viewer and addressee_id = v_owner;
    if found then
        return case when v_existing.status = 'accepted' then 'accepted' else 'requested' end;
    end if;

    insert into public.friendships (requester_id, addressee_id, status)
    values (v_viewer, v_owner, 'pending');
    return 'requested';
end;
$$;

-- Accept (or decline/delete) an incoming friend request addressed to the caller.
create or replace function public.respond_friend_request(p_friendship_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_viewer uuid := auth.uid();
begin
    if v_viewer is null then raise exception 'You must be signed in.'; end if;
    if p_accept then
        update public.friendships set status = 'accepted', responded_at = now()
        where id = p_friendship_id and addressee_id = v_viewer and status = 'pending';
        if not found then raise exception 'This friend request is no longer available.'; end if;
    else
        delete from public.friendships
        where id = p_friendship_id and addressee_id = v_viewer and status = 'pending';
    end if;
end;
$$;

-- Remove a friend (or withdraw a pending request) in either direction.
create or replace function public.remove_friend(p_other_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_viewer uuid := auth.uid();
begin
    if v_viewer is null then raise exception 'You must be signed in.'; end if;
    delete from public.friendships
    where (requester_id = v_viewer and addressee_id = p_other_user_id)
       or (requester_id = p_other_user_id and addressee_id = v_viewer);
end;
$$;

-- One round trip for the Friends screen: accepted friends, incoming requests
-- (awaiting the caller's response), and the caller's outgoing pending requests.
create or replace function public.friends_overview()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'friends', coalesce((
            select jsonb_agg(jsonb_build_object(
                'userID', p.user_id,
                'displayName', coalesce(p.display_name, ''),
                'avatarPath', p.avatar_path,
                'bio', coalesce(p.bio, ''),
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
                'bio', coalesce(p.bio, '')
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

revoke all on function public.profile_by_token(text) from public, anon;
revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_friend_request(uuid, boolean) from public, anon;
revoke all on function public.remove_friend(uuid) from public, anon;
revoke all on function public.friends_overview() from public, anon;
grant execute on function public.profile_by_token(text) to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.friends_overview() to authenticated;

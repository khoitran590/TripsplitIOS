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
    comments    jsonb not null default '[]'::jsonb,
    reactions   jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

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
    );

-- Any member may update a post's comments/reactions (the app only ever PATCHes
-- those columns; the post body is only edited by its author via the same policy).
drop policy if exists "Trip members can update feed posts" on public.trip_feed_posts;
create policy "Trip members can update feed posts"
    on public.trip_feed_posts for update
    using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

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


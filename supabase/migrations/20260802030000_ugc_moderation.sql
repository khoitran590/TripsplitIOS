-- User-generated-content reporting and user blocking.

create table if not exists public.user_blocks (
    blocker_id uuid not null references auth.users(id) on delete cascade,
    blocked_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    check (blocker_id <> blocked_id)
);
alter table public.user_blocks enable row level security;
drop policy if exists "Users view their blocks" on public.user_blocks;
create policy "Users view their blocks" on public.user_blocks for select
    using (auth.uid() = blocker_id);
revoke insert, update, delete on table public.user_blocks from public, anon, authenticated;

create table if not exists public.content_reports (
    id uuid primary key default gen_random_uuid(),
    reporter_id uuid not null references auth.users(id) on delete cascade,
    reported_user_id uuid references auth.users(id) on delete set null,
    content_type text not null check (content_type in ('post', 'comment', 'profile', 'media')),
    content_id uuid not null,
    reason text not null check (reason in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'privacy', 'other')),
    details text not null default '',
    content_snapshot jsonb not null default '{}'::jsonb,
    status text not null default 'open' check (status in ('open', 'reviewing', 'actioned', 'dismissed')),
    created_at timestamptz not null default now(),
    reviewed_at timestamptz,
    moderator_note text
);
create index if not exists content_reports_status_time_idx
    on public.content_reports (status, created_at);
alter table public.content_reports enable row level security;
-- Reports are intentionally invisible and immutable to ordinary users after submission.
revoke all on table public.content_reports from public, anon, authenticated;

create or replace function public.has_block_between(p_user_a uuid, p_user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select p_user_a is not null and p_user_b is not null and exists (
        select 1 from public.user_blocks b
        where (b.blocker_id = p_user_a and b.blocked_id = p_user_b)
           or (b.blocker_id = p_user_b and b.blocked_id = p_user_a)
    );
$$;

create or replace function public.set_user_block(p_blocked_user_id uuid, p_blocked boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid := auth.uid();
begin
    if v_uid is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if p_blocked_user_id is null or p_blocked_user_id = v_uid then
        raise exception 'You cannot block this account.' using errcode = '22023';
    end if;
    if not exists (select 1 from auth.users where id = p_blocked_user_id) then
        raise exception 'Account not found.' using errcode = 'P0002';
    end if;
    if p_blocked then
        insert into public.user_blocks (blocker_id, blocked_id)
        values (v_uid, p_blocked_user_id) on conflict do nothing;
        delete from public.friendships
        where (requester_id = v_uid and addressee_id = p_blocked_user_id)
           or (requester_id = p_blocked_user_id and addressee_id = v_uid);
    else
        delete from public.user_blocks where blocker_id = v_uid and blocked_id = p_blocked_user_id;
    end if;
end;
$$;

create or replace function public.blocked_user_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select b.blocked_id from public.user_blocks b where b.blocker_id = auth.uid();
$$;

create or replace function public.report_content(
    p_content_type text,
    p_content_id uuid,
    p_reason text,
    p_details text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_reported_user uuid;
    v_snapshot jsonb := '{}'::jsonb;
    v_report_id uuid;
begin
    if v_uid is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if p_content_type not in ('post', 'comment', 'profile', 'media')
       or p_reason not in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'privacy', 'other')
       or p_content_id is null or length(coalesce(p_details, '')) > 2000 then
        raise exception 'Report data is invalid.' using errcode = '22023';
    end if;
    if (select count(*) from public.content_reports
        where reporter_id = v_uid and created_at > now() - interval '1 day') >= 20 then
        raise exception 'Report limit reached. Contact support for urgent help.' using errcode = 'P0001';
    end if;

    if p_content_type in ('post', 'media') then
        select p.author_id,
               jsonb_build_object('body', left(p.body, 10000), 'photoPaths', p.photo_paths, 'tripID', p.trip_id)
          into v_reported_user, v_snapshot
          from public.trip_feed_posts p
         where p.id = p_content_id and public.is_trip_member(p.trip_id);
    elsif p_content_type = 'profile' then
        select p.user_id, jsonb_build_object('displayName', p.display_name, 'bio', left(p.bio, 2000))
          into v_reported_user, v_snapshot from public.profiles p where p.user_id = p_content_id;
    else
        select c.author_id, c.payload
          into v_reported_user, v_snapshot
          from public.expense_comments c
         where c.id = p_content_id and public.is_trip_member(c.trip_id);
        if v_reported_user is null then
            select (comment->>'authorID')::uuid, comment
              into v_reported_user, v_snapshot
              from public.trip_feed_posts p,
                   jsonb_array_elements(p.comments) comment
             where lower(comment->>'id') = p_content_id::text
               and public.is_trip_member(p.trip_id)
             limit 1;
        end if;
    end if;
    if v_reported_user is null or v_reported_user = v_uid then
        raise exception 'This content cannot be reported.' using errcode = '22023';
    end if;

    insert into public.content_reports
        (reporter_id, reported_user_id, content_type, content_id, reason, details, content_snapshot)
    values (v_uid, v_reported_user, p_content_type, p_content_id, p_reason,
            btrim(coalesce(p_details, '')), v_snapshot)
    returning id into v_report_id;
    return v_report_id;
end;
$$;

-- Blocks apply to friend requests even if a modified client calls the older RPCs
-- directly. Existing friendship rows are removed by set_user_block().
create or replace function public.enforce_friendship_block()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.role() = 'service_role' then return new; end if;
    if public.has_block_between(new.requester_id, new.addressee_id) then
        raise exception 'Interaction is unavailable.' using errcode = '42501';
    end if;
    return new;
end;
$$;
drop trigger if exists enforce_friendship_block_trigger on public.friendships;
create trigger enforce_friendship_block_trigger
    before insert or update on public.friendships
    for each row execute function public.enforce_friendship_block();

-- Replace the share-token profile reader so a known token cannot bypass a block.
create or replace function public.profile_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_viewer uuid := auth.uid();
    v_owner uuid;
    v_friend_status text;
    v_result jsonb;
begin
    if v_viewer is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if p_token is null or p_token !~ '^[a-f0-9]{36}$' then
        raise exception 'This profile link is invalid.' using errcode = '22023';
    end if;
    select user_id into v_owner from public.profiles where share_token = p_token;
    if v_owner is null or (v_owner <> v_viewer and public.has_block_between(v_viewer, v_owner)) then
        raise exception 'This profile link is invalid.' using errcode = 'P0002';
    end if;

    if v_viewer <> v_owner then
        select case
            when status = 'accepted' then 'accepted'
            when requester_id = v_viewer then 'requested'
            else 'incoming'
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
        'bio', case when v_owner = v_viewer
                     or coalesce((p.profile_visibility->>'bio')::boolean, true)
                    then coalesce(p.bio, '') else '' end,
        'dateOfBirth', case when v_owner = v_viewer
                             or coalesce((p.profile_visibility->>'birthday')::boolean, true)
                            then p.date_of_birth else null end,
        'visitedPlaces', case when v_owner = v_viewer
                               or coalesce((p.profile_visibility->>'places')::boolean, true)
                              then coalesce(p.visited_places, '[]'::jsonb) else '[]'::jsonb end,
        'trips', case when v_owner = v_viewer
                       or coalesce((p.profile_visibility->>'trips')::boolean, true)
                      then coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', t.id,
                'name', coalesce(t.name, t.metadata->>'name', 'Trip'),
                'location', t.metadata->>'location',
                'startDate', t.metadata->>'startDate',
                'endDate', t.metadata->>'endDate',
                'coverImageURL', t.metadata->>'coverImageURL'
            ) order by coalesce(t.metadata->>'startDate', '') desc)
            from public.trips t where t.user_id = p.user_id
        ), '[]'::jsonb) else '[]'::jsonb end
    ) into v_result
    from public.profiles p where p.user_id = v_owner;

    return v_result;
end;
$$;

revoke all on function public.has_block_between(uuid, uuid) from public, anon;
revoke all on function public.set_user_block(uuid, boolean) from public, anon;
revoke all on function public.blocked_user_ids() from public, anon;
revoke all on function public.report_content(text, uuid, text, text) from public, anon;
grant execute on function public.has_block_between(uuid, uuid) to authenticated;
grant execute on function public.set_user_block(uuid, boolean) to authenticated;
grant execute on function public.blocked_user_ids() to authenticated;
grant execute on function public.report_content(text, uuid, text, text) to authenticated;

drop policy if exists "Trip members can read feed posts" on public.trip_feed_posts;
create policy "Trip members can read feed posts"
    on public.trip_feed_posts for select
    using (
        public.is_trip_member(trip_id)
        and not public.has_block_between(auth.uid(), author_id)
    );

create or replace function public.enforce_feed_block()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.role() = 'service_role' then return new; end if;
    if auth.uid() is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if public.has_block_between(auth.uid(), new.author_id) then
        raise exception 'Interaction is unavailable.' using errcode = '42501';
    end if;
    return new;
end;
$$;
drop trigger if exists enforce_feed_block_trigger on public.trip_feed_posts;
create trigger enforce_feed_block_trigger
    before insert or update on public.trip_feed_posts
    for each row execute function public.enforce_feed_block();

-- Apply the same reciprocal block to profile-avatar downloads. Trip-scoped media still
-- follows active trip membership; the feed/profile readers hide blocked authors.
drop policy if exists "Attachment-authorized reads" on storage.objects;
create policy "Attachment-authorized reads"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'receipts'
        and (
            auth.uid()::text = (storage.foldername(name))[1]
            or exists (
                select 1 from public.storage_attachments a
                where a.bucket_id = storage.objects.bucket_id
                  and a.path = storage.objects.name
                  and a.lifecycle_state = 'active'
                  and (
                      (a.asset_type = 'avatar'
                       and not public.has_block_between(auth.uid(), a.owner_id))
                      or (
                          a.trip_id is not null
                          and public.is_trip_member(a.trip_id)
                          and (
                              a.asset_type <> 'feed_photo'
                              or not public.has_block_between(auth.uid(), a.owner_id)
                          )
                      )
                  )
            )
        )
    );

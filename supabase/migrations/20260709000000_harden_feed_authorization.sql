-- Harden trip-feed writes ----------------------------------------------------
--
-- RLS previously allowed every trip member to UPDATE an entire feed-post row.
-- The iOS client only patched comments/reactions, but a hostile client could also
-- rewrite another member's body, author, photos, or trip id.  Direct updates are now
-- limited to an author's editable columns.  Group interactions go through a validated
-- SECURITY DEFINER RPC that only permits callers to change their own comments and
-- reaction memberships.

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

-- The database supplies comments, reactions, and timestamps. Restricting INSERT at the
-- column-privilege layer means those fields cannot be forged even if a future policy is
-- accidentally loosened.
revoke insert on table public.trip_feed_posts from public, anon, authenticated;
grant insert (id, trip_id, author_id, author_name, body, photo_paths, location_name)
    on table public.trip_feed_posts to authenticated;

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

-- Remove the table-wide UPDATE privilege inherited by PostgREST's authenticated role.
-- Authors only need these two columns for the edit-post UI; updated_at is maintained by
-- the existing trigger.  Identity, photos, comments, and reactions cannot be patched
-- directly even by a post author.
revoke update on table public.trip_feed_posts from public, anon, authenticated;
grant update (body, location_name) on table public.trip_feed_posts to authenticated;

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

    -- Lock the post so two interaction updates are validated against one consistent
    -- version. A stale client is rejected instead of silently deleting someone else's
    -- concurrent comment or reaction.
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

    -- Keep untrusted JSON bounded and require the shapes the Swift decoder expects.
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

    -- Validate comment shape, UUIDs, uniqueness, and user-controlled text limits.
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

        -- A syntactically ISO-looking value can still contain an impossible month/day.
        -- Casting validates the calendar value; any failure aborts before the row update.
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

    -- A caller may add, edit, or remove their own comments. Every comment belonging to
    -- another user must occur byte-for-byte in both old and new arrays.
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

    -- Each reaction value is a unique array of user UUIDs. Removing the caller from
    -- old/new values must leave identical sets, proving they changed only themselves.
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

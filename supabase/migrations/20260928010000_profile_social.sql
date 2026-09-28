-- Profile Phase 3: a shareable bucket list and "Moments" (trip-feed photos the owner
-- picks for their profile). Both live in profiles.showcase (20260928000000).
--
-- Visibility keys, same rules as the other sections:
--   * `bucketList` — hidden unless the owner turns it on (a missing key means hidden);
--   * `moments`    — shown by default (a missing key means visible); only photos the owner
--                    explicitly picked are ever listed.

-- 1. Storage: a feed photo is otherwise readable only by that trip's members. Let any
--    signed-in user read one when its OWNER has put it in their profile's Moments and
--    shows Moments — the owner can only ever expose their own uploads (a.owner_id), never
--    someone else's photo from a shared trip. Blocks still apply. The other branches are
--    unchanged from 20260913030000_community_guide_cover_photos.sql.
create or replace function public.can_read_storage_attachment(
    p_bucket_id text,
    p_path text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select auth.uid() is not null
       and p_bucket_id = 'receipts'
       and exists (
            select 1
            from public.storage_attachments a
            where a.bucket_id = p_bucket_id
              and a.path = p_path
              and a.lifecycle_state = 'active'
              and (
                  (
                      a.asset_type = 'avatar'
                      and not public.has_block_between(auth.uid(), a.owner_id)
                  )
                  or (
                      a.trip_id is not null
                      and public.is_trip_member(a.trip_id)
                      and (
                          a.asset_type <> 'feed_photo'
                          or not public.has_block_between(auth.uid(), a.owner_id)
                      )
                  )
                  or (
                      a.asset_type = 'community_cover'
                      and exists (
                          select 1 from public.community_trip_guides g
                          where g.id = a.record_id
                            and g.author_id = a.owner_id
                            and g.cover_image_path = a.path
                            and not public.has_block_between(auth.uid(), g.author_id)
                      )
                  )
                  or (
                      a.asset_type = 'feed_photo'
                      and not public.has_block_between(auth.uid(), a.owner_id)
                      and exists (
                          select 1 from public.profiles p
                          where p.user_id = a.owner_id
                            and coalesce((p.profile_visibility->>'moments')::boolean, true)
                            and jsonb_typeof(p.showcase->'moments') = 'array'
                            and p.showcase->'moments' @> jsonb_build_array(jsonb_build_object('path', a.path))
                      )
                  )
              )
       );
$$;

revoke all on function public.can_read_storage_attachment(text, text)
    from public, anon;
grant execute on function public.can_read_storage_attachment(text, text)
    to authenticated;

-- 2. The share-token reader, now also returning the bucket list and Moments for
--    non-owners when shown. Otherwise identical to 20260928000000_profile_showcase.sql.
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
        'birthday', case when p.date_of_birth is not null
                          and (v_owner = v_viewer
                               or coalesce((p.profile_visibility->>'birthday')::boolean, false))
                         then to_char(p.date_of_birth, 'MM-DD') else null end,
        'visitedPlaces', case when v_owner = v_viewer
                               or coalesce((p.profile_visibility->>'places')::boolean, true)
                              then coalesce(p.visited_places, '[]'::jsonb) else '[]'::jsonb end,
        'badgesVisible', v_owner = v_viewer
                         or coalesce((p.profile_visibility->>'badges')::boolean, true),
        'showcase', case when v_owner = v_viewer then p.showcase else jsonb_strip_nulls(jsonb_build_object(
            'cover', case when jsonb_typeof(p.showcase->'cover') = 'string'
                          then p.showcase->'cover' end,
            'homeBase', case when coalesce((p.profile_visibility->>'details')::boolean, true)
                              and jsonb_typeof(p.showcase->'homeBase') = 'string'
                             then p.showcase->'homeBase' end,
            'languages', case when coalesce((p.profile_visibility->>'details')::boolean, true)
                               and jsonb_typeof(p.showcase->'languages') = 'string'
                              then p.showcase->'languages' end,
            'travelStyles', case when coalesce((p.profile_visibility->>'details')::boolean, true)
                                  and jsonb_typeof(p.showcase->'travelStyles') = 'array'
                                 then p.showcase->'travelStyles' end,
            'prompts', case when coalesce((p.profile_visibility->>'bio')::boolean, true)
                             and jsonb_typeof(p.showcase->'prompts') = 'array'
                            then p.showcase->'prompts' end,
            'favoritePlace', case when coalesce((p.profile_visibility->>'places')::boolean, true)
                                   and jsonb_typeof(p.showcase->'favoritePlace') = 'string'
                                  then p.showcase->'favoritePlace' end,
            'favoriteMemory', case when coalesce((p.profile_visibility->>'places')::boolean, true)
                                    and jsonb_typeof(p.showcase->'favoriteMemory') = 'string'
                                   then p.showcase->'favoriteMemory' end,
            'pinnedBadges', case when coalesce((p.profile_visibility->>'badges')::boolean, true)
                                  and jsonb_typeof(p.showcase->'pinnedBadges') = 'array'
                                 then p.showcase->'pinnedBadges' end,
            'bucketList', case when coalesce((p.profile_visibility->>'bucketList')::boolean, false)
                                and jsonb_typeof(p.showcase->'bucketList') = 'array'
                               then p.showcase->'bucketList' end,
            'moments', case when coalesce((p.profile_visibility->>'moments')::boolean, true)
                             and jsonb_typeof(p.showcase->'moments') = 'array'
                            then p.showcase->'moments' end
        )) end,
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

revoke all on function public.profile_by_token(text) from public, anon;
grant execute on function public.profile_by_token(text) to authenticated;

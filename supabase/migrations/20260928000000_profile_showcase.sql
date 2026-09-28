-- Profile showcase: the self-expression fields on the Profile tab (passport cover, home
-- base, languages, travel styles, travel-note prompts, favorite place, pinned badges).
--
-- One jsonb object rather than a column per field, so the app can add a showcase field
-- without a schema change (a missing column made every profile PATCH 400 before). The
-- app decodes every key with a default, so rows written by older builds keep loading.
alter table public.profiles
    add column if not exists showcase jsonb not null default '{}'::jsonb;

-- Friends' devices render this blob, so bound its shape and size server-side.
alter table public.profiles drop constraint if exists profiles_showcase_shape;
alter table public.profiles
    add constraint profiles_showcase_shape
    check (jsonb_typeof(showcase) = 'object' and pg_column_size(showcase) <= 16384);

-- Re-issue the share-token reader with the showcase and two privacy changes:
--   * the birthday leaves the database as month and day only ("MM-DD"), never the year,
--     and is hidden unless the owner turned it on (a missing key now means hidden);
--   * each showcase field is filtered by the owner's profile_visibility, the same way the
--     existing sections are: `details` gates home base, languages and travel styles;
--     `bio` gates the bio and travel notes; `places` gates the favorite place; `badges`
--     gates pinned badges. Missing keys mean visible, except the birthday.
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
                                 then p.showcase->'pinnedBadges' end
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

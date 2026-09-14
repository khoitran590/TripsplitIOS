-- Optional traveler-chosen cover photo for community guides ------------------
--
-- The photo lives in the private receipts bucket at "<author-uuid>/community-<guide-id>.jpg",
-- like trip covers. A guide stores only that path. Other signed-in travelers can read
-- the object while an unblocked guide references it; clearing or replacing the path
-- makes the old object owner-only again.

alter table public.community_trip_guides
    add column if not exists cover_image_path text;

alter table public.community_trip_guides
    drop constraint if exists community_trip_guides_cover_image_path_check,
    add constraint community_trip_guides_cover_image_path_check
        check (
            cover_image_path is null
            or cover_image_path = author_id::text || '/community-' || id::text || '.jpg'
        );

grant insert (cover_image_path) on table public.community_trip_guides to authenticated;
grant update (cover_image_path) on table public.community_trip_guides to authenticated;

comment on column public.community_trip_guides.cover_image_path is
    'Storage path of the author''s optional cover photo in the private receipts bucket.';

alter table public.storage_attachments
    drop constraint if exists storage_attachments_asset_type_check,
    add constraint storage_attachments_asset_type_check
        check (asset_type in ('avatar', 'trip_cover', 'receipt', 'feed_photo', 'community_cover'));

-- A new guide's photo is uploaded before the guide row exists, so registration only
-- requires that no other author already owns that guide id. Reads (below) still need
-- a guide that references the exact path.
create or replace function public.register_storage_attachment(
    p_path text,
    p_asset_type text,
    p_trip_id uuid default null,
    p_record_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
begin
    if v_uid is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if p_asset_type not in ('avatar', 'trip_cover', 'receipt', 'feed_photo', 'community_cover')
       or p_path is null or length(p_path) > 180
       or split_part(p_path, '/', 1) <> v_uid::text
       or not exists (
           select 1 from storage.objects o
           where o.bucket_id = 'receipts'
             and o.name = p_path
             and (storage.foldername(o.name))[1] = v_uid::text
       ) then
        raise exception 'Storage attachment is invalid.' using errcode = '22023';
    end if;

    if p_asset_type = 'avatar' then
        if p_path <> (v_uid::text || '/profile.jpg')
           or p_trip_id is not null or p_record_id is distinct from v_uid then
            raise exception 'Avatar attachment is invalid.' using errcode = '22023';
        end if;
    elsif p_asset_type = 'trip_cover' then
        if p_trip_id is null or p_record_id is distinct from p_trip_id
           or not public.is_trip_owner(p_trip_id, v_uid)
           or p_path <> (v_uid::text || '/cover-' || p_trip_id::text || '.jpg') then
            raise exception 'Trip cover attachment is invalid.' using errcode = '42501';
        end if;
    elsif p_asset_type = 'receipt' then
        if p_trip_id is null or p_record_id is null or not public.is_trip_member(p_trip_id)
           or p_path <> (v_uid::text || '/' || p_record_id::text || '.jpg') then
            raise exception 'Receipt attachment is invalid.' using errcode = '42501';
        end if;
    elsif p_asset_type = 'community_cover' then
        if p_trip_id is not null or p_record_id is null
           or p_path <> (v_uid::text || '/community-' || p_record_id::text || '.jpg')
           or exists (
               select 1 from public.community_trip_guides g
               where g.id = p_record_id and g.author_id <> v_uid
           ) then
            raise exception 'Community guide cover attachment is invalid.' using errcode = '42501';
        end if;
    else
        if p_trip_id is null or p_record_id is null or not public.is_trip_member(p_trip_id)
           or p_path !~ ('^' || v_uid::text || '/feed-' || p_record_id::text || '-[0-3][.]jpg$') then
            raise exception 'Feed attachment is invalid.' using errcode = '42501';
        end if;
    end if;

    insert into public.storage_attachments
        (path, bucket_id, asset_type, owner_id, trip_id, record_id, lifecycle_state, updated_at)
    values (p_path, 'receipts', p_asset_type, v_uid, p_trip_id, p_record_id, 'active', now())
    on conflict (path) do update set
        asset_type = excluded.asset_type,
        trip_id = excluded.trip_id,
        record_id = excluded.record_id,
        lifecycle_state = 'active',
        updated_at = now()
    where public.storage_attachments.owner_id = v_uid;
    if not found then
        raise exception 'Storage path belongs to another account.' using errcode = '42501';
    end if;
end;
$$;

revoke all on function public.register_storage_attachment(text, text, uuid, uuid)
    from public, anon;
grant execute on function public.register_storage_attachment(text, text, uuid, uuid)
    to authenticated;

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
              )
       );
$$;

revoke all on function public.can_read_storage_attachment(text, text)
    from public, anon;
grant execute on function public.can_read_storage_attachment(text, text)
    to authenticated;

-- Reports keep the photo path so moderators can review the image that was shown.
create or replace function public.report_community_trip_guide(
    p_guide_id uuid,
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
    v_guide public.community_trip_guides%rowtype;
    v_report_id uuid;
begin
    if v_uid is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
    if p_reason not in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'privacy', 'other')
       or p_guide_id is null or length(coalesce(p_details, '')) > 2000 then
        raise exception 'Report data is invalid.' using errcode = '22023';
    end if;
    if (select count(*) from public.content_reports
        where reporter_id = v_uid and created_at > now() - interval '1 day') >= 20 then
        raise exception 'Report limit reached. Contact support for urgent help.' using errcode = 'P0001';
    end if;

    select * into v_guide
      from public.community_trip_guides g
     where g.id = p_guide_id
       and not public.has_block_between(v_uid, g.author_id);
    if v_guide.id is null or v_guide.author_id = v_uid then
        raise exception 'This content cannot be reported.' using errcode = '22023';
    end if;

    insert into public.content_reports
        (reporter_id, reported_user_id, content_type, content_id, reason, details, content_snapshot)
    values (
        v_uid,
        v_guide.author_id,
        'community_trip',
        v_guide.id,
        p_reason,
        btrim(coalesce(p_details, '')),
        jsonb_build_object(
            'title', v_guide.title,
            'city', v_guide.city,
            'country', v_guide.country,
            'places', v_guide.places,
            'restaurants', v_guide.restaurants,
            'plannerNote', v_guide.planner_note,
            'bestBase', v_guide.best_base,
            'gettingAround', v_guide.getting_around,
            'bookFirst', v_guide.book_first,
            'coverImagePath', v_guide.cover_image_path
        )
    )
    returning id into v_report_id;
    return v_report_id;
end;
$$;

revoke all on function public.report_community_trip_guide(uuid, text, text) from public, anon;
grant execute on function public.report_community_trip_guide(uuid, text, text) to authenticated;

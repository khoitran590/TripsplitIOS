-- Object-level authorization for the private receipts bucket.

create table if not exists public.storage_attachments (
    path text primary key,
    bucket_id text not null default 'receipts' check (bucket_id = 'receipts'),
    asset_type text not null check (asset_type in ('avatar', 'trip_cover', 'receipt', 'feed_photo')),
    owner_id uuid not null references auth.users(id) on delete cascade,
    trip_id uuid references public.trips(id) on delete cascade,
    record_id uuid,
    lifecycle_state text not null default 'active' check (lifecycle_state in ('active', 'pending_delete')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists storage_attachments_trip_idx
    on public.storage_attachments (trip_id, asset_type);
alter table public.storage_attachments enable row level security;
revoke all on table public.storage_attachments from public, anon, authenticated;

update storage.buckets
set public = false,
    file_size_limit = 5000000,
    allowed_mime_types = array['image/jpeg']::text[]
where id = 'receipts';

-- Bound orphan/cost exposure before an object is registered as an attachment. The
-- bucket's 5 MB object cap makes the aggregate check conservative even though the
-- pending object's byte size is not available to an INSERT policy yet.
create or replace function public.can_upload_storage_object(p_bucket_id text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = public, storage, pg_temp
as $$
    select auth.uid() is not null
       and p_bucket_id = 'receipts'
       and auth.uid()::text = (storage.foldername(p_name))[1]
       and (
            exists (
                select 1 from storage.objects existing
                where existing.bucket_id = p_bucket_id and existing.name = p_name
            )
            or (
                (select count(*) from storage.objects o
                  where o.bucket_id = p_bucket_id
                    and (storage.foldername(o.name))[1] = auth.uid()::text) < 250
                and
                (select coalesce(sum(coalesce((o.metadata->>'size')::bigint, 0)), 0)
                   from storage.objects o
                  where o.bucket_id = p_bucket_id
                    and (storage.foldername(o.name))[1] = auth.uid()::text) < 500000000
            )
       );
$$;
revoke all on function public.can_upload_storage_object(text, text) from public, anon;
grant execute on function public.can_upload_storage_object(text, text) to authenticated;

drop policy if exists "Users upload their own receipts" on storage.objects;
create policy "Users upload their own receipts"
    on storage.objects for insert to authenticated
    with check (public.can_upload_storage_object(bucket_id, name));

-- Backfill current stable paths before narrowing Storage SELECT. Only recognized paths
-- are migrated; malformed/legacy public URLs remain owner-readable and can be re-uploaded.
insert into public.storage_attachments (path, asset_type, owner_id, record_id)
select p.avatar_path, 'avatar', p.user_id, p.user_id
from public.profiles p
where p.avatar_path ~* ('^' || p.user_id::text || '/profile[.]jpg$')
on conflict (path) do nothing;

insert into public.storage_attachments (path, asset_type, owner_id, trip_id, record_id)
select t.metadata->>'coverImageURL', 'trip_cover',
       split_part(t.metadata->>'coverImageURL', '/', 1)::uuid, t.id, t.id
from public.trips t
where coalesce(t.metadata->>'coverImageURL', '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/cover-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
on conflict (path) do nothing;

insert into public.storage_attachments (path, asset_type, owner_id, trip_id, record_id)
select e.payload->>'receiptURL', 'receipt',
       split_part(e.payload->>'receiptURL', '/', 1)::uuid, e.trip_id, e.id
from public.trip_expenses e
where coalesce(e.payload->>'receiptURL', '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
on conflict (path) do nothing;

insert into public.storage_attachments (path, asset_type, owner_id, trip_id, record_id)
select photo #>> '{}', 'feed_photo', split_part(photo #>> '{}', '/', 1)::uuid, p.trip_id, p.id
from public.trip_feed_posts p,
     jsonb_array_elements(coalesce(p.photo_paths, '[]'::jsonb)) photo
where (photo #>> '{}')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/feed-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-3][.]jpg$'
on conflict (path) do nothing;

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
    if p_asset_type not in ('avatar', 'trip_cover', 'receipt', 'feed_photo')
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

drop policy if exists "Authenticated users can view receipts" on storage.objects;
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
                      a.asset_type = 'avatar'
                      or (a.trip_id is not null and public.is_trip_member(a.trip_id))
                  )
            )
        )
    );

-- A pending deletion closes the race between storage cleanup and a new upload.
create table public.account_deletion_jobs (
 user_id uuid primary key references auth.users(id) on delete cascade,
 started_at timestamptz not null default now(),
 storage_cleared_at timestamptz,
 application_prepared_at timestamptz
);
alter table public.account_deletion_jobs enable row level security;
revoke all on public.account_deletion_jobs from public, anon, authenticated;

create or replace function public.begin_account_deletion(p_user_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
 if auth.role() is distinct from 'service_role' then
  raise exception 'Service role required.' using errcode='42501';
 end if;
 if p_user_id is null or not exists(select 1 from auth.users where id=p_user_id) then
  raise exception 'Account not found.' using errcode='P0002';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('deleting-storage:'||p_user_id::text,0));
 insert into public.account_deletion_jobs(user_id) values(p_user_id) on conflict do nothing;
end;
$$;

-- Storage uploads/upserts take the same transaction lock before checking the tombstone.
-- Whichever transaction arrives first completes; cleanup then sees its final state.
create or replace function public.prevent_storage_writes_during_deletion()
returns trigger language plpgsql security definer set search_path = public, storage, pg_temp
as $$
declare v_prefix text;
begin
 if tg_op='UPDATE' and old.bucket_id='receipts' then
  v_prefix := split_part(old.name,'/',1);
 elsif new.bucket_id='receipts' then
  v_prefix := split_part(new.name,'/',1);
 end if;
 if v_prefix is not null and
    v_prefix ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  perform pg_advisory_xact_lock(hashtextextended('deleting-storage:'||lower(v_prefix),0));
  if exists(select 1 from public.account_deletion_jobs where user_id=v_prefix::uuid) then
   raise exception 'Account deletion is in progress.' using errcode='42501';
  end if;
 end if;
 return new;
end;
$$;
create trigger prevent_storage_writes_during_deletion_trigger
 before insert or update on storage.objects for each row
 execute function public.prevent_storage_writes_during_deletion();

-- List exact object paths from Storage metadata. The HTTP Storage list API exposes
-- folders separately and can miss nested objects when used as a flat file list.
create or replace function public.account_storage_paths_for_deletion(p_user_id uuid,p_limit integer default 100)
returns table(path text) language plpgsql stable security definer set search_path = public, storage, pg_temp
as $$
begin
 if auth.role() is distinct from 'service_role' then
  raise exception 'Service role required.' using errcode='42501';
 end if;
 if p_user_id is null or p_limit is null or p_limit not between 1 and 100 then
  raise exception 'Invalid storage listing arguments.' using errcode='22023';
 end if;
 return query select o.name from storage.objects o
  where o.bucket_id='receipts' and o.name like p_user_id::text || '/%'
  order by o.name limit p_limit;
end;
$$;

create or replace function public.mark_account_storage_cleared(p_user_id uuid)
returns void language plpgsql security definer set search_path = public, storage, pg_temp
as $$
begin
 if auth.role() is distinct from 'service_role' then
  raise exception 'Service role required.' using errcode='42501';
 end if;
 -- Uploads are already blocked by the job; this catches incomplete/reordered callers.
 if exists(select 1 from storage.objects o where o.bucket_id='receipts'
             and o.name like p_user_id::text || '/%') then
  raise exception 'Account storage is not empty.' using errcode='P0001';
 end if;
 update public.account_deletion_jobs set storage_cleared_at=coalesce(storage_cleared_at,now())
  where user_id=p_user_id;
 if not found then raise exception 'Account deletion has not started.' using errcode='42501'; end if;
end;
$$;

revoke all on function public.begin_account_deletion(uuid) from public,anon,authenticated;
revoke all on function public.prevent_storage_writes_during_deletion() from public,anon,authenticated;
revoke all on function public.account_storage_paths_for_deletion(uuid,integer) from public,anon,authenticated;
revoke all on function public.mark_account_storage_cleared(uuid) from public,anon,authenticated;
grant execute on function public.begin_account_deletion(uuid) to service_role;
grant execute on function public.account_storage_paths_for_deletion(uuid,integer) to service_role;
grant execute on function public.mark_account_storage_cleared(uuid) to service_role;

-- The Storage insert policy also fails early for normal clients. The BEFORE trigger
-- above is authoritative under concurrency and for privileged/upsert writes.
create or replace function public.can_upload_storage_object(p_bucket_id text,p_name text)
returns boolean language sql stable security definer set search_path = public, storage, pg_temp
as $$
 select auth.uid() is not null and p_bucket_id='receipts'
  and auth.uid()::text=(storage.foldername(p_name))[1]
  and not exists(select 1 from public.account_deletion_jobs j where j.user_id=auth.uid());
$$;

create or replace function public.prepare_account_deletion(p_user_id uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_affected_trip_ids uuid[];
    v_trip_id uuid;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'Service role required.' using errcode = '42501';
    end if;
    if not exists (select 1 from public.account_deletion_jobs j
                   where j.user_id=p_user_id and j.storage_cleared_at is not null)
       or exists (select 1 from storage.objects o where o.bucket_id='receipts'
                  and o.name like p_user_id::text || '/%') then
        raise exception 'Account storage must be cleared first.' using errcode='42501';
    end if;

    select coalesce(array_agg(tm.trip_id), '{}'::uuid[])
      into v_affected_trip_ids
      from public.trip_members tm
     where tm.user_id = p_user_id
       and not exists (
           select 1 from public.trips owned
           where owned.id = tm.trip_id and owned.user_id = p_user_id
       );

    -- Trips organized by the deleting account are removed under the published product
    -- rule. Cascades remove normalized expenses, settlements, feed posts, and membership.
    delete from public.trips where user_id = p_user_id;

    -- Remove authored UGC from trips owned by somebody else.
    delete from public.expense_comments where author_id = p_user_id;
    delete from public.trip_feed_posts where author_id = p_user_id;
    update public.trip_feed_posts p
       set comments = coalesce((
               select jsonb_agg(comment order by comment->>'date')
                 from jsonb_array_elements(p.comments) comment
                where lower(coalesce(comment->>'authorID', '')) <> p_user_id::text
           ), '[]'::jsonb),
           reactions = coalesce((
               select jsonb_object_agg(reaction.key, reaction.members)
                 from (
                     select pair.key,
                            coalesce(jsonb_agg(member order by member #>> '{}')
                                filter (where lower(member #>> '{}') <> p_user_id::text), '[]'::jsonb) members
                       from jsonb_each(p.reactions) pair
                       left join lateral jsonb_array_elements(pair.value) member on true
                      group by pair.key
                 ) reaction
           ), '{}'::jsonb)
     where exists (
         select 1 from jsonb_array_elements(p.comments) comment
          where lower(coalesce(comment->>'authorID', '')) = p_user_id::text
     ) or p.reactions::text ilike '%' || p_user_id::text || '%';

    -- Keep a pseudonymous participant tombstone where shared financial history still
    -- references this UUID, while removing profile/avatar data and active access.
    update public.trips t
       set metadata = jsonb_set(
               jsonb_set(
                   t.metadata,
                   '{members}',
                   coalesce((
                       select jsonb_agg(
                           case when lower(member->>'id') = p_user_id::text
                                then (member - 'avatarURL') || jsonb_build_object('name', 'Deleted User')
                                else member end
                           order by member->>'id'
                       )
                       from jsonb_array_elements(coalesce(t.metadata->'members', '[]'::jsonb)) member
                   ), '[]'::jsonb),
                   true
               ),
               '{archivedBy}',
               coalesce((
                   select jsonb_agg(value order by value #>> '{}')
                   from jsonb_array_elements(coalesce(t.metadata->'archivedBy', '[]'::jsonb))
                   where lower(value #>> '{}') <> p_user_id::text
               ), '[]'::jsonb),
               true
           )
     where t.id = any(v_affected_trip_ids);

    insert into public.trip_removed_members (trip_id, user_id, reason, removed_at)
    select unnest(v_affected_trip_ids), p_user_id, 'deleted', now()
    on conflict (trip_id, user_id) do update set reason = 'deleted', removed_at = now();
    delete from public.trip_members where user_id = p_user_id;
    delete from public.friendships where requester_id = p_user_id or addressee_id = p_user_id;
    delete from public.trip_invitations
     where invited_by = p_user_id
        or (p_email is not null and lower(email) = lower(p_email));
    delete from public.profiles where user_id = p_user_id;

    foreach v_trip_id in array v_affected_trip_ids loop
        update public.trips set data = public.trip_document(v_trip_id) where id = v_trip_id;
    end loop;

    -- Storage is empty and new writes are blocked, so retire its quota row too.
    delete from public.storage_quota_counters where owner_prefix=p_user_id::text;

    update public.account_deletion_jobs set application_prepared_at=coalesce(application_prepared_at,now())
     where user_id=p_user_id;

    return jsonb_build_object(
        'prepared', true,
        'storagePrefix', p_user_id::text,
        'retainedFinancialIdentity', true
    );
end;
$$;

revoke all on function public.prepare_account_deletion(uuid,text) from public,anon,authenticated;
grant execute on function public.prepare_account_deletion(uuid,text) to service_role;
;

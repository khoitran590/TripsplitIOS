-- Keep storage attachment metadata private while allowing the Storage RLS policy
-- to evaluate it. A policy that queries a fully revoked table directly fails at
-- query planning for authenticated callers, even when the owner-path branch is true.

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
              )
       );
$$;

revoke all on function public.can_read_storage_attachment(text, text)
    from public, anon;
grant execute on function public.can_read_storage_attachment(text, text)
    to authenticated;

drop policy if exists "Attachment-authorized reads" on storage.objects;
create policy "Attachment-authorized reads"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'receipts'
        and (
            auth.uid()::text = (storage.foldername(name))[1]
            or public.can_read_storage_attachment(bucket_id, name)
        )
    );


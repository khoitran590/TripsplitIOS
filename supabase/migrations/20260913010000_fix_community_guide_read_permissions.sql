-- Fix community-guide reads for signed-out users and for the brief anonymous request
-- that can occur while an existing session is being restored.
--
-- has_block_between remains unavailable to anon because arbitrary block-pair queries
-- would disclose private moderation state. Instead, only authenticated reads invoke it.

drop policy if exists "Community guides are publicly readable" on public.community_trip_guides;

drop policy if exists "Anonymous users read community guides" on public.community_trip_guides;
create policy "Anonymous users read community guides"
    on public.community_trip_guides for select to anon
    using (true);

drop policy if exists "Authenticated users read unblocked community guides" on public.community_trip_guides;
create policy "Authenticated users read unblocked community guides"
    on public.community_trip_guides for select to authenticated
    using (not public.has_block_between(auth.uid(), author_id));

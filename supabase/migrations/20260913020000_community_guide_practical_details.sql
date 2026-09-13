-- Bring traveler-authored guides to parity with the editorial "Plan it like a local"
-- framework. Defaults keep guides created by the first app release readable/editable.

alter table public.community_trip_guides
    add column if not exists best_base text not null
        default 'Choose a central, well-connected neighborhood.',
    add column if not exists getting_around text not null
        default 'Group stops by area and rely on local transit.',
    add column if not exists book_first text not null
        default 'Reserve the one experience you would be disappointed to miss.';

alter table public.community_trip_guides
    drop constraint if exists community_trip_guides_best_base_check,
    add constraint community_trip_guides_best_base_check
        check (length(btrim(best_base)) between 1 and 1000),
    drop constraint if exists community_trip_guides_getting_around_check,
    add constraint community_trip_guides_getting_around_check
        check (length(btrim(getting_around)) between 1 and 1000),
    drop constraint if exists community_trip_guides_book_first_check,
    add constraint community_trip_guides_book_first_check
        check (length(btrim(book_first)) between 1 and 1000);

grant insert (best_base, getting_around, book_first)
    on table public.community_trip_guides to authenticated;
grant update (best_base, getting_around, book_first)
    on table public.community_trip_guides to authenticated;

comment on column public.community_trip_guides.best_base is
    'Community author guidance for the best neighborhood or area to stay.';
comment on column public.community_trip_guides.getting_around is
    'Community author guidance for local transportation and trip clustering.';
comment on column public.community_trip_guides.book_first is
    'Community author guidance for reservations that should be made first.';

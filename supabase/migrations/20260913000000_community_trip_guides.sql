-- Public traveler-authored trip guides --------------------------------------
--
-- Community guides deliberately mirror the app's bundled Destination shape.
-- They are separate from private/shared trips: copying a guide creates a normal
-- private itinerary; it never grants access to the author's trip data.

create or replace function public.community_guide_items_are_valid(p_items jsonb)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
    select jsonb_typeof(p_items) = 'array'
       and jsonb_array_length(p_items) between 1 and 20
       and not exists (
           select 1
             from jsonb_array_elements(p_items) item
            where jsonb_typeof(item) <> 'object'
               or coalesce(item->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
               or length(btrim(coalesce(item->>'name', ''))) not between 1 and 120
               or length(coalesce(item->>'detail', '')) > 1000
               or coalesce(item->>'cost', '') not in ('Free', 'Low', 'Low-mid', 'Mid', 'Mid-high', 'High')
       );
$$;

create table if not exists public.community_trip_guides (
    id            uuid primary key,
    author_id     uuid not null references auth.users(id) on delete cascade,
    author_name   text not null default '',
    title         text not null check (length(btrim(title)) between 1 and 120),
    city          text not null check (length(btrim(city)) between 1 and 120),
    country       text not null check (length(btrim(country)) between 1 and 120),
    style         text not null check (style in ('Foodie', 'Beach', 'Culture', 'Design', 'Adventure', 'Relaxed', 'Family')),
    days          integer not null check (days between 1 and 30),
    budget_usd    numeric(12,2) not null check (budget_usd > 0 and budget_usd <= 1000000),
    places        jsonb not null check (public.community_guide_items_are_valid(places)),
    restaurants   jsonb not null check (public.community_guide_items_are_valid(restaurants)),
    planner_note  text not null check (length(btrim(planner_note)) between 1 and 2000),
    best_base     text not null default 'Choose a central, well-connected neighborhood.'
        check (length(btrim(best_base)) between 1 and 1000),
    getting_around text not null default 'Group stops by area and rely on local transit.'
        check (length(btrim(getting_around)) between 1 and 1000),
    book_first    text not null default 'Reserve the one experience you would be disappointed to miss.'
        check (length(btrim(book_first)) between 1 and 1000),
    latitude      double precision,
    longitude     double precision,
    use_count     bigint not null default 0 check (use_count >= 0),
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    check (
        (latitude is null and longitude is null)
        or (latitude is not null and longitude is not null
            and latitude between -90 and 90 and longitude between -180 and 180)
    )
);

create index if not exists community_trip_guides_created_idx
    on public.community_trip_guides (created_at desc, id desc);
create index if not exists community_trip_guides_author_idx
    on public.community_trip_guides (author_id, created_at desc);

drop trigger if exists community_trip_guides_set_updated_at on public.community_trip_guides;
create trigger community_trip_guides_set_updated_at
    before update on public.community_trip_guides
    for each row execute function public.set_trips_updated_at();

-- Attribution is server-owned. A modified client cannot publish under somebody
-- else's name, and profile edits do not rewrite the historical snapshot.
create or replace function public.set_community_trip_guide_author()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if auth.uid() is null or new.author_id <> auth.uid() then
        raise exception 'Guide author must be the signed-in user.' using errcode = '42501';
    end if;
    select coalesce(nullif(btrim(p.display_name), ''), 'A TripSplit traveler')
      into new.author_name
      from public.profiles p
     where p.user_id = auth.uid();
    new.author_name := coalesce(new.author_name, 'A TripSplit traveler');
    return new;
end;
$$;

drop trigger if exists community_trip_guides_set_author on public.community_trip_guides;
create trigger community_trip_guides_set_author
    before insert on public.community_trip_guides
    for each row execute function public.set_community_trip_guide_author();

alter table public.community_trip_guides enable row level security;

-- Keep anonymous and authenticated reads separate. Anonymous callers intentionally
-- cannot execute has_block_between (it would expose private block relationships), so
-- a shared OR expression can fail permission checks before PostgreSQL short-circuits it.
drop policy if exists "Community guides are publicly readable" on public.community_trip_guides;
drop policy if exists "Anonymous users read community guides" on public.community_trip_guides;
create policy "Anonymous users read community guides"
    on public.community_trip_guides for select to anon
    using (true);
drop policy if exists "Authenticated users read unblocked community guides" on public.community_trip_guides;
create policy "Authenticated users read unblocked community guides"
    on public.community_trip_guides for select to authenticated
    using (not public.has_block_between(auth.uid(), author_id));

drop policy if exists "Users publish their own community guides" on public.community_trip_guides;
create policy "Users publish their own community guides"
    on public.community_trip_guides for insert to authenticated
    with check (author_id = auth.uid());

drop policy if exists "Authors update their community guides" on public.community_trip_guides;
create policy "Authors update their community guides"
    on public.community_trip_guides for update to authenticated
    using (author_id = auth.uid())
    with check (author_id = auth.uid());

drop policy if exists "Authors delete their community guides" on public.community_trip_guides;
create policy "Authors delete their community guides"
    on public.community_trip_guides for delete to authenticated
    using (author_id = auth.uid());

revoke all on table public.community_trip_guides from public, anon, authenticated;
grant select on table public.community_trip_guides to anon, authenticated;
grant insert (id, author_id, title, city, country, style, days, budget_usd, places, restaurants, planner_note, best_base, getting_around, book_first, latitude, longitude)
    on table public.community_trip_guides to authenticated;
grant update (title, city, country, style, days, budget_usd, places, restaurants, planner_note, best_base, getting_around, book_first, latitude, longitude)
    on table public.community_trip_guides to authenticated;
grant delete on table public.community_trip_guides to authenticated;

-- One use per signed-in traveler. This makes the displayed count useful discovery
-- metadata instead of a tap counter that one client can inflate.
create table if not exists public.community_trip_guide_uses (
    guide_id uuid not null references public.community_trip_guides(id) on delete cascade,
    user_id  uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (guide_id, user_id)
);
alter table public.community_trip_guide_uses enable row level security;
revoke all on table public.community_trip_guide_uses from public, anon, authenticated;

create or replace function public.use_community_trip_guide(p_guide_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_inserted integer;
begin
    if v_uid is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.community_trip_guides g
         where g.id = p_guide_id
           and not public.has_block_between(v_uid, g.author_id)
    ) then
        raise exception 'Community guide not found.' using errcode = 'P0002';
    end if;

    insert into public.community_trip_guide_uses (guide_id, user_id)
    values (p_guide_id, v_uid)
    on conflict do nothing;
    get diagnostics v_inserted = row_count;

    if v_inserted = 1 then
        update public.community_trip_guides
           set use_count = use_count + 1
         where id = p_guide_id;
    end if;
end;
$$;

revoke all on function public.use_community_trip_guide(uuid) from public, anon;
grant execute on function public.use_community_trip_guide(uuid) to authenticated;

-- Reuse the existing private moderation inbox while keeping the established
-- report_content RPC's narrower post/comment/profile contract unchanged.
alter table public.content_reports
    drop constraint if exists content_reports_content_type_check;
alter table public.content_reports
    add constraint content_reports_content_type_check
    check (content_type in ('post', 'comment', 'profile', 'media', 'community_trip'));

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
            'bookFirst', v_guide.book_first
        )
    )
    returning id into v_report_id;
    return v_report_id;
end;
$$;

revoke all on function public.report_community_trip_guide(uuid, text, text) from public, anon;
grant execute on function public.report_community_trip_guide(uuid, text, text) to authenticated;

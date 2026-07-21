-- Rich MapKit bookmark snapshots power the Saved map/list while the legacy key list
-- remains available for backward compatibility with older app versions.
alter table public.profiles
    add column if not exists saved_map_places jsonb not null default '[]'::jsonb;

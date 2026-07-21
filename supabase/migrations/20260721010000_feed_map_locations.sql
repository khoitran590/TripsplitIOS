-- Exact MapKit coordinates for trip-feed place pins. Existing name-only posts remain
-- valid and are geocoded by the client when their map layer is enabled.
alter table public.trip_feed_posts add column if not exists location_latitude double precision;
alter table public.trip_feed_posts add column if not exists location_longitude double precision;
alter table public.trip_feed_posts add column if not exists location_address text;

grant update (body, location_name, location_latitude, location_longitude, location_address)
    on table public.trip_feed_posts to authenticated;

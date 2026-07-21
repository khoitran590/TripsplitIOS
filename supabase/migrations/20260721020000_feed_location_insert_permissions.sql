-- Location-tagged feed posts include exact coordinates and an address in the initial
-- INSERT. Keep the hardened column allowlist while permitting those new fields.
grant insert (
    id,
    trip_id,
    author_id,
    author_name,
    body,
    photo_paths,
    location_name,
    location_latitude,
    location_longitude,
    location_address
)
    on table public.trip_feed_posts to authenticated;

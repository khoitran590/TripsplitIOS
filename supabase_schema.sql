-- TripSplit — Supabase schema for cloud-syncing trips.
--
-- Run this once in your Supabase project:
--   Dashboard → SQL Editor → New query → paste → Run.
--
-- Each trip (with its members, budgets, and expenses) is stored as a single JSON
-- blob in the `data` column. Row-level security ties every row to the signed-in
-- user via auth.uid(), so the app only ever sends the user's access token.

create table if not exists public.trips (
    id         uuid primary key,
    user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
    data       jsonb not null,
    updated_at timestamptz not null default now()
);

-- Keep updated_at fresh on every upsert so fetches can order newest-first.
create or replace function public.set_trips_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trips_set_updated_at on public.trips;
create trigger trips_set_updated_at
    before insert or update on public.trips
    for each row execute function public.set_trips_updated_at();

-- Row-level security: users may only read/write their own trips.
alter table public.trips enable row level security;

drop policy if exists "Users manage their own trips" on public.trips;
create policy "Users manage their own trips"
    on public.trips
    for all
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Receipt image storage ------------------------------------------------------
--
-- Scanned receipt photos are uploaded to a public `receipts` bucket; each file is
-- namespaced under the uploader's user id ("<auth.uid()>/<expenseId>.jpg"). Reads are
-- public (so the URL stored on the expense renders anywhere); writes/updates/deletes
-- are restricted to the owner via the leading-folder convention.

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', true)
on conflict (id) do update set public = true;

drop policy if exists "Anyone can view receipts" on storage.objects;
create policy "Anyone can view receipts"
    on storage.objects for select
    using (bucket_id = 'receipts');

drop policy if exists "Users upload their own receipts" on storage.objects;
create policy "Users upload their own receipts"
    on storage.objects for insert
    with check (
        bucket_id = 'receipts'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

drop policy if exists "Users update their own receipts" on storage.objects;
create policy "Users update their own receipts"
    on storage.objects for update
    using (
        bucket_id = 'receipts'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

drop policy if exists "Users delete their own receipts" on storage.objects;
create policy "Users delete their own receipts"
    on storage.objects for delete
    using (
        bucket_id = 'receipts'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

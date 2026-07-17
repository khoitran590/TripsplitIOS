-- B10: normalize the independently edited parts of a trip while retaining `trips.data`
-- as a compatibility projection for older clients. All writes happen in one transaction.

alter table public.trips add column if not exists name text;
alter table public.trips add column if not exists currency_code text;
alter table public.trips add column if not exists metadata jsonb not null default '{}'::jsonb;

create table if not exists public.trip_expenses (
    id uuid primary key,
    trip_id uuid not null references public.trips (id) on delete cascade,
    payer_id uuid,
    amount double precision not null default 0,
    expense_date timestamptz,
    deleted_at timestamptz,
    payload jsonb not null,
    updated_at timestamptz not null default now(),
    unique (trip_id, id)
);

create table if not exists public.settlement_records (
    id uuid primary key,
    trip_id uuid not null references public.trips (id) on delete cascade,
    settlement_key text not null,
    amount double precision not null default 0,
    status text,
    record_date timestamptz,
    payload jsonb not null,
    updated_at timestamptz not null default now(),
    unique (trip_id, id)
);

create table if not exists public.expense_comments (
    id uuid primary key,
    trip_id uuid not null references public.trips (id) on delete cascade,
    expense_id uuid not null,
    author_id uuid,
    created_at timestamptz,
    edited_at timestamptz,
    payload jsonb not null,
    updated_at timestamptz not null default now(),
    unique (trip_id, id)
);

create index if not exists trip_expenses_trip_date_idx
    on public.trip_expenses (trip_id, expense_date desc);
create index if not exists trip_expenses_trip_deleted_idx
    on public.trip_expenses (trip_id, deleted_at);
create index if not exists settlement_records_trip_key_idx
    on public.settlement_records (trip_id, settlement_key, record_date);
create index if not exists expense_comments_expense_date_idx
    on public.expense_comments (trip_id, expense_id, created_at);

alter table public.trip_expenses enable row level security;
alter table public.settlement_records enable row level security;
alter table public.expense_comments enable row level security;

drop policy if exists "Trip members can read expenses" on public.trip_expenses;
create policy "Trip members can read expenses" on public.trip_expenses
    for select using (public.is_trip_member(trip_id));
drop policy if exists "Trip members can write expenses" on public.trip_expenses;
create policy "Trip members can write expenses" on public.trip_expenses
    for all using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

drop policy if exists "Trip members can read settlements" on public.settlement_records;
create policy "Trip members can read settlements" on public.settlement_records
    for select using (public.is_trip_member(trip_id));
drop policy if exists "Trip members can write settlements" on public.settlement_records;
create policy "Trip members can write settlements" on public.settlement_records
    for all using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

drop policy if exists "Trip members can read expense comments" on public.expense_comments;
create policy "Trip members can read expense comments" on public.expense_comments
    for select using (public.is_trip_member(trip_id));
drop policy if exists "Trip members can write expense comments" on public.expense_comments;
create policy "Trip members can write expense comments" on public.expense_comments
    for all using (public.is_trip_member(trip_id))
    with check (public.is_trip_member(trip_id));

-- Reconstruct the Codable Trip document. This is used both by new table-backed reads
-- and to keep the old blob current during the compatibility window.
create or replace function public.trip_document(p_trip_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select t.metadata || jsonb_build_object(
        'expenses', coalesce((
            select jsonb_agg(e.payload order by e.expense_date, e.id)
            from public.trip_expenses e
            where e.trip_id = t.id and e.deleted_at is null
        ), '[]'::jsonb),
        'deletedExpenses', coalesce((
            select jsonb_agg(e.payload order by e.deleted_at desc, e.id)
            from public.trip_expenses e
            where e.trip_id = t.id and e.deleted_at is not null
        ), '[]'::jsonb),
        'settlementRecords', coalesce((
            select jsonb_object_agg(grouped.settlement_key, grouped.records)
            from (
                select s.settlement_key,
                       jsonb_agg(s.payload order by s.record_date, s.id) as records
                from public.settlement_records s
                where s.trip_id = t.id
                group by s.settlement_key
            ) grouped
        ), '{}'::jsonb),
        'comments', coalesce((
            select jsonb_object_agg(grouped.expense_id::text, grouped.comments)
            from (
                select c.expense_id,
                       jsonb_agg(c.payload order by c.created_at, c.id) as comments
                from public.expense_comments c
                where c.trip_id = t.id
                group by c.expense_id
            ) grouped
        ), '{}'::jsonb)
    )
    from public.trips t
    where t.id = p_trip_id;
$$;

-- Applies only fields which differ between the caller's previous synced snapshot and
-- its new snapshot. Distinct child rows edited concurrently by another member survive.
create or replace function public.sync_trip_normalized(
    p_id uuid,
    p_user_id uuid,
    p_data jsonb,
    p_previous_data jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid uuid := auth.uid();
    v_owner uuid;
    v_metadata jsonb;
    v_previous_metadata jsonb;
    v_current_expenses jsonb;
    v_previous_expenses jsonb;
    v_current_settlements jsonb;
    v_previous_settlements jsonb;
    v_current_comments jsonb;
    v_previous_comments jsonb;
    v_item jsonb;
    v_previous_item jsonb;
    v_pair record;
    v_id uuid;
    v_document jsonb;
begin
    if v_uid is null then raise exception 'You must be signed in.'; end if;
    if p_data is null or jsonb_typeof(p_data) <> 'object' then
        raise exception 'Trip data must be a JSON object.';
    end if;

    -- Serialize writes only long enough to merge this delta with the latest rows.
    perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
    select user_id into v_owner from public.trips where id = p_id;
    if v_owner is null then
        if p_user_id <> v_uid then raise exception 'Trip owner must be the signed-in user.'; end if;
        insert into public.trips (id, user_id, data, metadata, name, currency_code)
        values (p_id, v_uid, '{}'::jsonb, '{}'::jsonb, p_data->>'name', p_data->>'currencyCode');
        insert into public.trip_members (trip_id, user_id, role)
        values (p_id, v_uid, 'owner')
        on conflict (trip_id, user_id) do update set role = 'owner';
    elsif not public.is_trip_member(p_id) then
        raise exception 'You are not a member of this trip.';
    end if;

    v_metadata := p_data - 'expenses' - 'deletedExpenses' - 'settlementRecords' - 'comments';
    v_previous_metadata := coalesce(p_previous_data, '{}'::jsonb)
        - 'expenses' - 'deletedExpenses' - 'settlementRecords' - 'comments';
    if p_previous_data is null or v_metadata is distinct from v_previous_metadata then
        update public.trips
        set metadata = v_metadata,
            name = p_data->>'name',
            currency_code = p_data->>'currencyCode'
        where id = p_id;
    end if;

    v_current_expenses := coalesce(p_data->'expenses', '[]'::jsonb)
        || coalesce(p_data->'deletedExpenses', '[]'::jsonb);
    v_previous_expenses := coalesce(p_previous_data->'expenses', '[]'::jsonb)
        || coalesce(p_previous_data->'deletedExpenses', '[]'::jsonb);
    for v_item in select value from jsonb_array_elements(v_current_expenses)
    loop
        if coalesce(v_item->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            raise exception 'Expense id is invalid.';
        end if;
        v_id := (v_item->>'id')::uuid;
        select value into v_previous_item
        from jsonb_array_elements(v_previous_expenses)
        where value->>'id' = v_item->>'id' limit 1;
        if p_previous_data is null or v_previous_item is distinct from v_item then
            insert into public.trip_expenses
                (id, trip_id, payer_id, amount, expense_date, deleted_at, payload, updated_at)
            values (
                v_id, p_id,
                case when coalesce(v_item->>'payerID', '') ~* '^[0-9a-f-]{36}$' then (v_item->>'payerID')::uuid end,
                coalesce((v_item->>'amount')::double precision, 0),
                nullif(v_item->>'date', '')::timestamptz,
                nullif(v_item->>'deletedAt', '')::timestamptz,
                v_item, now()
            )
            on conflict (id) do update set
                payer_id = excluded.payer_id, amount = excluded.amount,
                expense_date = excluded.expense_date, deleted_at = excluded.deleted_at,
                payload = excluded.payload, updated_at = now()
            where public.trip_expenses.trip_id = p_id;
        end if;
        v_previous_item := null;
    end loop;
    if p_previous_data is not null then
        delete from public.trip_expenses e
        where e.trip_id = p_id
          and exists (select 1 from jsonb_array_elements(v_previous_expenses) old where old->>'id' = e.id::text)
          and not exists (select 1 from jsonb_array_elements(v_current_expenses) cur where cur->>'id' = e.id::text);
    end if;

    v_current_settlements := coalesce(p_data->'settlementRecords', '{}'::jsonb);
    v_previous_settlements := coalesce(p_previous_data->'settlementRecords', '{}'::jsonb);
    for v_pair in select key as settlement_key, value as records from jsonb_each(v_current_settlements)
    loop
        for v_item in select value from jsonb_array_elements(v_pair.records)
        loop
            if coalesce(v_item->>'id', '') !~* '^[0-9a-f-]{36}$' then
                raise exception 'Settlement id is invalid.';
            end if;
            v_id := (v_item->>'id')::uuid;
            select prior_item into v_previous_item
            from jsonb_each(v_previous_settlements) pairs,
                 jsonb_array_elements(pairs.value) prior_item
            where pairs.key = v_pair.settlement_key and prior_item->>'id' = v_item->>'id' limit 1;
            if p_previous_data is null or v_previous_item is distinct from v_item then
                insert into public.settlement_records
                    (id, trip_id, settlement_key, amount, status, record_date, payload, updated_at)
                values (
                    v_id, p_id, v_pair.settlement_key,
                    coalesce((v_item->>'amount')::double precision, 0), v_item->>'status',
                    nullif(v_item->>'date', '')::timestamptz, v_item, now()
                )
                on conflict (id) do update set
                    settlement_key = excluded.settlement_key, amount = excluded.amount,
                    status = excluded.status, record_date = excluded.record_date,
                    payload = excluded.payload, updated_at = now()
                where public.settlement_records.trip_id = p_id;
            end if;
            v_previous_item := null;
        end loop;
    end loop;
    if p_previous_data is not null then
        delete from public.settlement_records s
        where s.trip_id = p_id
          and exists (
              select 1 from jsonb_each(v_previous_settlements) pairs,
                   jsonb_array_elements(pairs.value) old where old->>'id' = s.id::text
          )
          and not exists (
              select 1 from jsonb_each(v_current_settlements) pairs,
                   jsonb_array_elements(pairs.value) cur where cur->>'id' = s.id::text
          );
    end if;

    v_current_comments := coalesce(p_data->'comments', '{}'::jsonb);
    v_previous_comments := coalesce(p_previous_data->'comments', '{}'::jsonb);
    for v_pair in select key as expense_id, value as comments from jsonb_each(v_current_comments)
    loop
        if v_pair.expense_id !~* '^[0-9a-f-]{36}$' then continue; end if;
        for v_item in select value from jsonb_array_elements(v_pair.comments)
        loop
            if coalesce(v_item->>'id', '') !~* '^[0-9a-f-]{36}$' then
                raise exception 'Comment id is invalid.';
            end if;
            v_id := (v_item->>'id')::uuid;
            select prior_item into v_previous_item
            from jsonb_each(v_previous_comments) pairs,
                 jsonb_array_elements(pairs.value) prior_item
            where pairs.key = v_pair.expense_id and prior_item->>'id' = v_item->>'id' limit 1;
            if p_previous_data is null or v_previous_item is distinct from v_item then
                insert into public.expense_comments
                    (id, trip_id, expense_id, author_id, created_at, edited_at, payload, updated_at)
                values (
                    v_id, p_id, v_pair.expense_id::uuid,
                    case when coalesce(v_item->>'authorID', '') ~* '^[0-9a-f-]{36}$' then (v_item->>'authorID')::uuid end,
                    nullif(v_item->>'date', '')::timestamptz,
                    nullif(v_item->>'editedAt', '')::timestamptz, v_item, now()
                )
                on conflict (id) do update set
                    expense_id = excluded.expense_id, author_id = excluded.author_id,
                    created_at = excluded.created_at, edited_at = excluded.edited_at,
                    payload = excluded.payload, updated_at = now()
                where public.expense_comments.trip_id = p_id;
            end if;
            v_previous_item := null;
        end loop;
    end loop;
    if p_previous_data is not null then
        delete from public.expense_comments c
        where c.trip_id = p_id
          and exists (
              select 1 from jsonb_each(v_previous_comments) pairs,
                   jsonb_array_elements(pairs.value) old where old->>'id' = c.id::text
          )
          and not exists (
              select 1 from jsonb_each(v_current_comments) pairs,
                   jsonb_array_elements(pairs.value) cur where cur->>'id' = c.id::text
          );
    end if;

    v_document := public.trip_document(p_id);
    update public.trips set data = v_document where id = p_id;
    return v_document;
end;
$$;

-- Idempotent backfill. With no previous snapshot, the function imports the complete
-- compatibility document into normalized rows and immediately verifies its projection.
create or replace function public.backfill_normalized_trip_storage()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_trip record;
    v_count integer := 0;
begin
    for v_trip in select id, user_id, data from public.trips loop
        perform set_config('request.jwt.claim.sub', v_trip.user_id::text, true);
        perform public.sync_trip_normalized(v_trip.id, v_trip.user_id, v_trip.data, null);
        v_count := v_count + 1;
    end loop;
    return v_count;
end;
$$;

-- New clients read a table-backed projection. Membership is checked inside the SECURITY
-- DEFINER function because PostgREST executes the function rather than selecting tables.
create or replace function public.fetch_normalized_trips()
returns table(data jsonb, updated_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
    select public.trip_document(t.id), t.updated_at
    from public.trips t
    where public.is_trip_member(t.id)
    order by t.updated_at desc;
$$;

revoke all on function public.trip_document(uuid) from public, anon, authenticated;
revoke all on function public.sync_trip_normalized(uuid, uuid, jsonb, jsonb) from public, anon;
grant execute on function public.sync_trip_normalized(uuid, uuid, jsonb, jsonb) to authenticated;
revoke all on function public.backfill_normalized_trip_storage() from public, anon, authenticated;
revoke all on function public.fetch_normalized_trips() from public, anon;
grant execute on function public.fetch_normalized_trips() to authenticated;

-- Run as the migration owner so legacy rows are ready before table-backed reads begin.
select public.backfill_normalized_trip_storage();

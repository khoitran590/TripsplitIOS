-- Build previous-record lookups once per save. Preserve the original financial
-- mutation triggers, advisory lock, merge semantics, and legacy RPC contract.
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
    v_expense_lookup jsonb;
    v_settlement_lookup jsonb;
    v_comment_lookup jsonb;
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
    select coalesce(jsonb_object_agg(id, payload), '{}'::jsonb) into v_expense_lookup
    from (select distinct on (value->>'id') value->>'id' as id, value as payload
          from jsonb_array_elements(v_previous_expenses) with ordinality
          where value->>'id' is not null
          order by value->>'id', ordinality) previous;
    for v_item in select value from jsonb_array_elements(v_current_expenses)
    loop
        if coalesce(v_item->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            raise exception 'Expense id is invalid.';
        end if;
        v_id := (v_item->>'id')::uuid;
        v_previous_item := v_expense_lookup->(v_item->>'id');
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
          and e.id::text in (
              select jsonb_object_keys(v_expense_lookup)
              except select value->>'id' from jsonb_array_elements(v_current_expenses)
          );
    end if;

    v_current_settlements := coalesce(p_data->'settlementRecords', '{}'::jsonb);
    v_previous_settlements := coalesce(p_previous_data->'settlementRecords', '{}'::jsonb);
    select coalesce(jsonb_object_agg(lookup_key, payload), '{}'::jsonb) into v_settlement_lookup
    from (
        select distinct on (pairs.key, item.value->>'id')
               jsonb_build_array(pairs.key, item.value->>'id')::text as lookup_key,
               item.value as payload
        from jsonb_each(v_previous_settlements) pairs,
             jsonb_array_elements(pairs.value) with ordinality item(value, position)
        order by pairs.key, item.value->>'id', item.position
    ) previous;
    for v_pair in select key as settlement_key, value as records from jsonb_each(v_current_settlements)
    loop
        for v_item in select value from jsonb_array_elements(v_pair.records)
        loop
            if coalesce(v_item->>'id', '') !~* '^[0-9a-f-]{36}$' then
                raise exception 'Settlement id is invalid.';
            end if;
            v_id := (v_item->>'id')::uuid;
            v_previous_item := v_settlement_lookup->(jsonb_build_array(v_pair.settlement_key, v_item->>'id')::text);
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
          and s.id::text in (
              select value->>'id' from jsonb_each(v_settlement_lookup)
              except
              select item->>'id' from jsonb_each(v_current_settlements) pairs,
                   jsonb_array_elements(pairs.value) item
          );
    end if;

    v_current_comments := coalesce(p_data->'comments', '{}'::jsonb);
    v_previous_comments := coalesce(p_previous_data->'comments', '{}'::jsonb);
    select coalesce(jsonb_object_agg(lookup_key, payload), '{}'::jsonb) into v_comment_lookup
    from (
        select distinct on (pairs.key, item.value->>'id')
               jsonb_build_array(pairs.key, item.value->>'id')::text as lookup_key,
               item.value as payload
        from jsonb_each(v_previous_comments) pairs,
             jsonb_array_elements(pairs.value) with ordinality item(value, position)
        order by pairs.key, item.value->>'id', item.position
    ) previous;
    for v_pair in select key as expense_id, value as comments from jsonb_each(v_current_comments)
    loop
        if v_pair.expense_id !~* '^[0-9a-f-]{36}$' then continue; end if;
        for v_item in select value from jsonb_array_elements(v_pair.comments)
        loop
            if coalesce(v_item->>'id', '') !~* '^[0-9a-f-]{36}$' then
                raise exception 'Comment id is invalid.';
            end if;
            v_id := (v_item->>'id')::uuid;
            v_previous_item := v_comment_lookup->(jsonb_build_array(v_pair.expense_id, v_item->>'id')::text);
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
          and c.id::text in (
              select value->>'id' from jsonb_each(v_comment_lookup)
              except
              select item->>'id' from jsonb_each(v_current_comments) pairs,
                   jsonb_array_elements(pairs.value) item
          );
    end if;

    v_document := public.trip_document(p_id);
    update public.trips set data = v_document where id = p_id;
    return v_document;
end;
$$;

-- New clients send only changed children and explicit removed IDs. Adapt to the
-- hardened normalized writer with a sparse previous document containing tombstones.
-- No old snapshot or full response document crosses the network.
create or replace function public.sync_trip_delta_v1(p_id uuid, p_user_id uuid, p_delta jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_data jsonb;
    v_previous jsonb;
begin
    if auth.uid() is null then raise exception 'You must be signed in.'; end if;
    if p_delta is null or jsonb_typeof(p_delta) <> 'object' then
        raise exception 'Trip delta must be an object.';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
    if not exists (select 1 from public.trips where id = p_id)
       and (jsonb_typeof(p_delta->'metadata') is distinct from 'object'
            or p_user_id is distinct from auth.uid()) then
        raise exception 'A new trip requires its owner and metadata.';
    end if;
    v_data := coalesce(nullif(p_delta->'metadata', 'null'::jsonb), '{}'::jsonb)
        || jsonb_build_object(
            'expenses', coalesce(p_delta->'expenses', '[]'::jsonb),
            'deletedExpenses', '[]'::jsonb,
            'settlementRecords', coalesce(p_delta->'settlements', '{}'::jsonb),
            'comments', coalesce(p_delta->'comments', '{}'::jsonb)
        );
    v_previous := jsonb_build_object(
        'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', lower(value)))
            from jsonb_array_elements_text(coalesce(p_delta->'removedExpenses', '[]'::jsonb))), '[]'::jsonb),
        'settlementRecords', jsonb_build_object('_removed', coalesce((
            select jsonb_agg(jsonb_build_object('id', lower(value)))
            from jsonb_array_elements_text(coalesce(p_delta->'removedSettlements', '[]'::jsonb))), '[]'::jsonb)),
        'comments', jsonb_build_object('_removed', coalesce((
            select jsonb_agg(jsonb_build_object('id', lower(value)))
            from jsonb_array_elements_text(coalesce(p_delta->'removedComments', '[]'::jsonb))), '[]'::jsonb))
    );
    perform public.sync_trip_normalized(p_id, p_user_id, v_data, v_previous);
end;
$$;
revoke all on function public.sync_trip_delta_v1(uuid, uuid, jsonb) from public, anon;
grant execute on function public.sync_trip_delta_v1(uuid, uuid, jsonb) to authenticated;

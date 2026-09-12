-- A debtor may confirm their own recorded payment when the creditor cannot use the
-- app, but only through an explicit selfApproved payload. The server records immutable
-- provenance so collaborators can distinguish self-approved and creditor-approved
-- settlements. Creditor confirmation/rejection behavior remains unchanged.

create or replace function public.enforce_settlement_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_debtor uuid;
    v_creditor uuid;
    v_self_approved boolean;
begin
    if v_uid is null and auth.role() is distinct from 'service_role' then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if auth.role() = 'service_role' then
        if tg_op = 'DELETE' then return old; else return new; end if;
    end if;
    if tg_op = 'DELETE' then
        raise exception 'Settlement records are append-only.' using errcode = '42501';
    end if;
    if not public.is_trip_member(new.trip_id) then
        raise exception 'You are not a member of this trip.' using errcode = '42501';
    end if;
    if new.settlement_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}->[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'Settlement parties are invalid.' using errcode = '22023';
    end if;
    v_debtor := split_part(new.settlement_key, '->', 1)::uuid;
    v_creditor := split_part(new.settlement_key, '->', 2)::uuid;
    if v_debtor = v_creditor
       or not public.trip_metadata_has_person(new.trip_id, v_debtor)
       or not public.trip_metadata_has_person(new.trip_id, v_creditor) then
        raise exception 'Settlement parties must belong to the trip.' using errcode = '22023';
    end if;
    if new.amount::text in ('NaN', 'Infinity', '-Infinity')
       or new.amount <= 0 or new.amount > 1000000000
       or jsonb_typeof(new.payload) is distinct from 'object'
       or pg_column_size(new.payload) > 16384
       or lower(coalesce(new.payload->>'id', '')) <> new.id::text
       or length(coalesce(new.payload->>'note', '')) > 1000
       or coalesce(new.payload->>'method', '') not in ('Cash', 'Venmo', 'PayPal', 'Cash App') then
        raise exception 'Settlement data is invalid.' using errcode = '22023';
    end if;
    v_self_approved := lower(coalesce(new.payload->>'selfApproved', 'false')) = 'true';

    if tg_op = 'INSERT' then
        if not (
            (v_uid = v_debtor and coalesce(new.status, '') = 'pending')
            or (v_uid = v_creditor and coalesce(new.status, '') = 'confirmed')
            or (v_uid = v_debtor and coalesce(new.status, '') = 'confirmed' and v_self_approved)
        ) then
            raise exception 'Only the debtor can propose or self-approve a payment, or the creditor can confirm it.' using errcode = '42501';
        end if;
        new.created_by := v_uid;
        new.debtor_id := v_debtor;
        new.creditor_id := v_creditor;
        new.record_date := now();
        if v_uid = v_debtor and new.status = 'confirmed' and v_self_approved then
            new.payload := new.payload || jsonb_build_object(
                'status', new.status,
                'date', new.record_date,
                'selfApproved', true,
                'selfApprovedBy', v_uid,
                'selfApprovedAt', now()
            );
        else
            new.payload := new.payload || jsonb_build_object('status', new.status, 'date', new.record_date);
        end if;
    else
        if new.id is not distinct from old.id
           and new.trip_id is not distinct from old.trip_id
           and new.settlement_key is not distinct from old.settlement_key
           and new.amount is not distinct from old.amount
           and new.status is not distinct from old.status then
            return old;
        end if;
        if new.id is distinct from old.id
           or new.trip_id is distinct from old.trip_id
           or new.settlement_key is distinct from old.settlement_key
           or old.status is distinct from 'pending'
           or coalesce(new.status, '') not in ('confirmed', 'rejected')
           or new.amount is distinct from old.amount
           or not (
               v_uid = old.creditor_id
               or (v_uid = old.debtor_id and new.status = 'confirmed' and v_self_approved)
           ) then
            raise exception 'Only the creditor can confirm or reject, unless the debtor explicitly self-approves.' using errcode = '42501';
        end if;
        new.created_by := old.created_by;
        new.debtor_id := old.debtor_id;
        new.creditor_id := old.creditor_id;
        new.record_date := old.record_date;
        if v_uid = old.debtor_id and v_self_approved then
            new.payload := old.payload || jsonb_build_object(
                'status', new.status,
                'selfApproved', true,
                'selfApprovedBy', v_uid,
                'selfApprovedAt', now()
            );
        else
            new.payload := old.payload || jsonb_build_object('status', new.status);
        end if;
    end if;
    return new;
end;
$$;

revoke all on function public.enforce_settlement_mutation() from public, anon, authenticated;

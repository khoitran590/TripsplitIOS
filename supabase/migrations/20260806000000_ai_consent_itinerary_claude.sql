-- Claude becomes the primary itinerary planner, with Gemini as fallback.
-- A new itinerary-only consent version is enforced by the client and Edge Function;
-- existing Google-only grants therefore cannot authorize a transfer to Anthropic, and
-- keep using Gemini until the user accepts the new disclosure.

create or replace function public.set_ai_consent(
    p_purpose text,
    p_consent_version text,
    p_granted boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := auth.uid();
    v_providers text[];
begin
    if v_uid is null then
        raise exception 'You must be signed in.' using errcode = '42501';
    end if;
    if p_purpose not in ('receipt_processing', 'itinerary_generation')
       or p_consent_version is null or length(p_consent_version) not between 1 and 40 then
        raise exception 'Consent choice is invalid.' using errcode = '22023';
    end if;
    v_providers := case
        when p_purpose = 'receipt_processing' and p_consent_version = '2026-08-05'
            then array['Anthropic Claude', 'Google Gemini']::text[]
        when p_purpose = 'receipt_processing'
            then array['Google Cloud Vision', 'Google Gemini']::text[]
        when p_purpose = 'itinerary_generation' and p_consent_version = '2026-08-06'
            then array['Anthropic Claude', 'Anthropic web search', 'Google Gemini', 'Google Search grounding']::text[]
        else array['Google Gemini', 'Google Search grounding']::text[]
    end;

    insert into public.ai_processing_consents
        (user_id, purpose, consent_version, providers, granted_at, revoked_at, updated_at)
    values (
        v_uid, p_purpose, p_consent_version, v_providers,
        case when p_granted then now() end,
        case when not p_granted then now() end,
        now()
    )
    on conflict (user_id, purpose) do update set
        consent_version = excluded.consent_version,
        providers = excluded.providers,
        granted_at = case when p_granted then now() else public.ai_processing_consents.granted_at end,
        revoked_at = case when p_granted then null else now() end,
        updated_at = now();
end;
$$;

revoke all on function public.set_ai_consent(text, text, boolean) from public, anon;
grant execute on function public.set_ai_consent(text, text, boolean) to authenticated;

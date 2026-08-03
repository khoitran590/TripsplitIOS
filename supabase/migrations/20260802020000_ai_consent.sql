-- Versioned, purpose-specific consent for third-party AI processing.

create table if not exists public.ai_processing_consents (
    user_id uuid not null references auth.users(id) on delete cascade,
    purpose text not null check (purpose in ('receipt_processing', 'itinerary_generation')),
    consent_version text not null,
    providers text[] not null,
    granted_at timestamptz,
    revoked_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (user_id, purpose)
);
alter table public.ai_processing_consents enable row level security;

drop policy if exists "Users view their AI consent" on public.ai_processing_consents;
create policy "Users view their AI consent"
    on public.ai_processing_consents for select
    using (auth.uid() = user_id);
revoke insert, update, delete on table public.ai_processing_consents
    from public, anon, authenticated;

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
    v_providers := case p_purpose
        when 'receipt_processing' then array['Google Cloud Vision', 'Google Gemini']::text[]
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

create or replace function public.has_ai_consent(p_purpose text, p_consent_version text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select auth.uid() is not null and exists (
        select 1 from public.ai_processing_consents c
        where c.user_id = auth.uid()
          and c.purpose = p_purpose
          and c.consent_version = p_consent_version
          and c.granted_at is not null
          and c.revoked_at is null
    );
$$;

revoke all on function public.set_ai_consent(text, text, boolean) from public, anon;
revoke all on function public.has_ai_consent(text, text) from public, anon;
grant execute on function public.set_ai_consent(text, text, boolean) to authenticated;
grant execute on function public.has_ai_consent(text, text) to authenticated;

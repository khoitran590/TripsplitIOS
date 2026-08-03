# TripSplit Security and App Store Readiness Review

**Review date:** August 2, 2026  
**Implementation update:** August 3, 2026  
**Status:** Not ready for App Store submission  
**Scope:** Native iOS client, Supabase SQL/RLS, Storage policies, Edge Functions, local data handling, Xcode release configuration, and current Apple review requirements.

## Executive summary

TripSplit builds successfully and all 16 unit tests pass. The implementation pass added server-side financial authorization, redirect credential containment, attachment ACL metadata, account deletion, purpose-specific AI consent, reporting/blocking, hardened invitations, session/cache cleanup, a privacy manifest, an AppIcon, and a reproducible database baseline. The app's Edge Functions retain provider secrets server-side and are configured to require JWTs.

The repository is still not ready for submission by itself. The new SQL must be applied and exercised against a disposable/staging Supabase project; the Edge Functions and email-provider secrets must be deployed; a controlled HTTPS domain and universal links are still required; and the hosted privacy policy, content-filtering/moderation operation, support contact, App Store privacy answers, signed archive, and physical-device TestFlight pass remain external release gates.

The bundled Supabase anon key is intentionally public and is not considered a leaked secret. No service-role key, private key, or provider API key was found in the client repository.

## Release gates

| ID | Priority | Release gate | Current status |
| --- | --- | --- | --- |
| SEC-01 | P0 | Enforce financial and trip authorization on the server | Implemented in migrations; staging authorization tests pending |
| SEC-02 | P0 | Prevent credentials from following untrusted redirects | Implemented and unit-tested |
| SEC-03 | P0 | Isolate private Storage objects by owner/trip access | ACLs/quotas implemented; signature validation and staging tests pending |
| ASC-01 | P0 | Provide complete in-app account deletion | Client/backend implemented; deployed end-to-end test pending |
| ASC-02 | P0 | Obtain explicit consent before third-party AI processing | Client/backend implemented; policy/contracts and deployed test pending |
| ASC-03 | P0 | Add UGC reporting, blocking, filtering, and support | Reporting/blocking implemented; filtering/support/moderation operations pending |
| ASC-04 | P0 | Add privacy policy, privacy disclosures, and privacy manifest | Manifest/in-app draft implemented; hosted policy and ASC disclosures pending |
| SEC-04 | P1 | Replace bearer-token custom URL links with universal links | Blocked |
| SEC-05 | P1 | Revoke sessions and improve local-data protection | Implemented; deployed revocation test pending |
| SEC-06 | P1 | Prevent email enumeration and forced trip membership | Implemented; email-provider/domain deployment pending |
| SEC-07 | P1 | Add server-side upload, AI, and invitation abuse controls | Partially implemented; platform rate limits/alerts/signature checks pending |
| OPS-01 | P1 | Make the database reproducible and security-test RLS | Baseline/tests added; clean reset, live diff, and CI pending |
| REL-01 | P1 | Resolve release bundle and App Store packaging gaps | Release build passes; signed archive/domain/device/ASC work pending |

P0 means the issue must be resolved before submission or public use. P1 means it must be resolved before production release. P2 items are defense-in-depth improvements that can follow once the release gates are satisfied.

The detailed findings below describe the state found during the August 2 review. The table above and the implementation ledger below are the current source of truth.

## Implementation ledger

| Area | Implemented in this pass | Evidence / remaining validation |
| --- | --- | --- |
| Financial authorization | Immutable actor fields; owner/payer/comment/settlement capability triggers; server-derived identities; validation; direct child DML revocation; append-only audit events; owner removal/member leave RPCs with financial-history tombstones | [financial authorization migration](supabase/migrations/20260802000000_financial_authorization.sql); apply and run the complete identity matrix in staging |
| Authenticated redirects | Exact HTTPS host/effective-port allowlist and five-hop cap; sensitive redirect data is not logged | [AuthFeature.swift](Tripsplit/AuthFeature.swift), redirect tests in [TripsplitAppTests.swift](TripsplitAppTests/TripsplitAppTests.swift) |
| Storage | Attachment ACL table/registration RPC, private scoped reads, 5 MB JPEG bucket cap, per-user object/byte quotas, blocked-avatar/feed-media handling, orphan cleanup on failed registration | [storage migration](supabase/migrations/20260802010000_storage_authorization.sql) and [ReceiptService.swift](Tripsplit/ReceiptService.swift); add decoded file-signature/dimension validation and staging isolation tests |
| Account deletion | Password reauthentication, two-step destructive UI, privileged retry-safe data preparation, Storage removal, Auth-user deletion last, and local Keychain/cache purge | [delete-account Edge Function](supabase/functions/delete-account/index.ts), [SettingsScreen.swift](Tripsplit/SettingsScreen.swift); deploy and test with owned/shared trips and retry failures |
| AI privacy | Separate receipt/itinerary disclosures and choices, on-device/manual fallback, server consent receipts, backend consent enforcement, revocation, and paid-attempt quota charging | [AIConsentFeature.swift](Tripsplit/AIConsentFeature.swift), [AI consent migration](supabase/migrations/20260802020000_ai_consent.sql); finalize hosted policy and provider retention/training terms |
| UGC safety | Protected reports, 20/day report limit, reciprocal blocks, feed/profile safety menus, block-aware feed/profile/friend/invitation/Storage paths, community-standards screen | [moderation migration](supabase/migrations/20260802030000_ugc_moderation.sql), [ModerationFeature.swift](Tripsplit/ModerationFeature.swift); staff support/mod queue, define SLA/appeals, and deploy pre-publication filtering |
| Invitations | Generic email response, pending-only membership, 72-hour hashed single-use tokens, authenticated email delivery function, preview plus explicit Join/Decline, owner revocation, no auto-accept | [invitation migration](supabase/migrations/20260802040000_invitation_hardening.sql), [send-invitation Edge Function](supabase/functions/send-invitation/index.ts); configure Resend and replace fallback links with universal links |
| Sessions/local data | Global logout attempt before unconditional local cleanup, stronger device-only Keychain accessibility/status checks, complete file protection, user-scoped cache purge | [AuthFeature.swift](Tripsplit/AuthFeature.swift), [TripStore.swift](Tripsplit/TripStore.swift), [TripsRepository.swift](Tripsplit/TripsRepository.swift) |
| Database operations | Former monolithic schema moved to the first ordered baseline; stale root script retired; structural pgTAP release gates added | [baseline](supabase/migrations/20260701000000_baseline.sql), [security_release_gates.sql](supabase/tests/security_release_gates.sql); reconcile existing migration history before pushing and run clean reset/tests in CI |
| App package | 1024×1024 AppIcon, privacy manifest with UserDefaults/FileTimestamp reasons, URL fallback, and aligned 1.1 version | Unsigned generic Debug and optimized arm64 Release simulator builds pass; inspect a signed device archive and complete ASC/export-compliance work |

## Deployment prerequisites still required

1. Back up the linked database and compare its schema/migration history to the new baseline. Existing projects that previously ran `supabase_schema.sql` must mark `20260701000000` as an applied baseline after verification; do not execute it over production.
2. Run a clean local reset and `supabase test db`, then apply the later migrations to staging and execute the multi-identity matrix below. This workspace did not have a usable local Docker/Postgres runtime, so SQL execution is not yet evidenced.
3. Deploy `parse-receipt`, `ocr-receipt`, `suggest-itinerary`, `delete-account`, and `send-invitation` with JWT verification enabled. Configure `RESEND_API_KEY`, `INVITATION_FROM_EMAIL`, and an HTTPS `INVITATION_BASE_URL` in addition to existing provider secrets.
4. Configure a controlled domain, Associated Domains entitlement, `apple-app-site-association`, and HTTPS invitation/profile routes. Remove bearer tokens from the custom-scheme fallback once universal links are verified.
5. Publish final privacy policy, Terms/Community Standards, retention schedule, provider disclosures, staffed support address, moderation SLA/appeals process, and App Store privacy answers.
6. Configure Auth/bot/platform limits, monitoring, provider budgets, moderation operations, backup/recovery, and incident ownership.
7. Produce a signed Release archive and complete physical-device/TestFlight testing before submission.

## P0 remediation

### SEC-01: Enforce authorization and financial integrity on the server

**Risk:** Critical

The UI only permits the trip owner or expense payer to edit an expense ([ExpenseDetailView.swift](Tripsplit/ExpenseDetailView.swift#L24)), and only the creditor can confirm a settlement ([TripDetailView.swift](Tripsplit/TripDetailView.swift#L619)). The database does not enforce those rules. Every trip member has write access to all normalized financial tables ([supabase_schema.sql](supabase_schema.sql#L1005)), while `sync_trip_normalized` only verifies membership before accepting client-provided expenses, payer IDs, settlements, comment authors, deletions, and metadata ([supabase_schema.sql](supabase_schema.sql#L1104)).

**Implement:**

- Stop treating the client’s complete trip JSON document or `p_previous_data` as authorization evidence.
- Replace broad synchronization with narrowly scoped RPCs or API endpoints, such as:
  - `create_expense`
  - `update_expense`
  - `delete_expense`
  - `create_settlement`
  - `confirm_settlement`
  - `create_comment`
  - `update_comment`
  - `delete_comment`
  - `update_trip_metadata`
  - `invite_member`, `remove_member`, and `leave_trip`
- Derive the acting user from `auth.uid()`; never accept an author or creator identity from the client.
- Add immutable `created_by` fields to expenses, comments, and settlement records.
- Enforce an explicit capability matrix:
  - Trip owner: membership and destructive trip administration.
  - Owner or payer: modify/delete an expense, if that matches the product rule.
  - Comment author: edit their comment; author or trip owner: delete it.
  - Creditor: confirm payment; define separately who may propose or cancel it.
  - Members: only the collaborative metadata fields the product intentionally allows.
- Validate referenced users are current trip members.
- Validate monetary values, allowed statuses, currency codes, timestamps, text lengths, and object counts server-side.
- Revoke direct `INSERT`, `UPDATE`, and `DELETE` access where mutations should only occur through RPCs.
- Add an append-only audit trail for expense and settlement changes.

**Acceptance criteria:**

- A member cannot edit another payer’s expense through direct REST calls or RPC payload manipulation.
- A member cannot forge another user’s comment or confirm a settlement owed to someone else.
- A removed member immediately loses read and write access.
- The trip owner cannot be changed by editing JSON metadata.
- Every mutation test runs with at least owner, member A, member B, removed member, authenticated outsider, and anonymous identities.

### SEC-02: Reject cross-origin authenticated redirects

**Risk:** High

`RedirectAuthPreserver` reattaches `Authorization` and `apikey` to every redirect without validating the new origin ([AuthFeature.swift](Tripsplit/AuthFeature.swift#L105)). A compromised or misconfigured endpoint could redirect to another host and receive the user’s bearer token.

**Implement:**

- Require HTTPS on both the original and redirected requests.
- Only allow the exact expected Supabase host and port.
- Return `nil` from the redirect callback for any unexpected origin or downgrade.
- Prefer correcting endpoint URLs so authenticated backend calls never require redirects.
- Do not log tokens, signed URLs, invitation tokens, or sensitive query parameters.
- Add tests for same-origin, cross-origin, HTTPS-to-HTTP, malformed, and redirect-loop cases.

**Acceptance criteria:** No authenticated header is sent to a different scheme, host, or port under any redirect response.

### SEC-03: Enforce object-level Storage authorization

**Risk:** High

The `receipts` bucket is private, but its select policy allows every authenticated user to access every object ([supabase_schema.sql](supabase_schema.sql#L447)). A private bucket prevents anonymous public URLs; it does not provide per-user or per-trip isolation when any authenticated account can mint signed URLs.

**Implement:**

- Separate avatars, trip covers, receipts, and feed media if they have different visibility rules.
- Add an attachment metadata table containing object path, asset type, owner, trip, related record, and lifecycle state.
- Issue signed URLs through an RPC or Edge Function that verifies the caller may access the related profile/trip/expense/post.
- Restrict direct Storage select policies to the narrowest necessary cases.
- Ensure removed trip members can no longer create new signed URLs.
- Set bucket-level `file_size_limit` and `allowed_mime_types` values.
- Validate file signatures after upload rather than trusting the MIME header.
- Add per-user object count/storage quotas and orphan cleanup.
- Migrate existing paths into the metadata model before removing the old policy.

**Acceptance criteria:** Authenticated user A cannot sign or download user B’s unrelated object, even if A knows the exact path.

### ASC-01: Add complete in-app account deletion

**Risk:** App Review rejection and privacy compliance failure

The app creates email/password accounts ([AuthFeature.swift](Tripsplit/AuthFeature.swift#L188)), but Settings only offers Sign Out ([SettingsScreen.swift](Tripsplit/SettingsScreen.swift#L140)). Apple requires account deletion to be initiated from within the app.

**Implement:**

- Add a clearly visible **Delete Account** action under account settings.
- Require recent authentication and a destructive confirmation step.
- Create an idempotent privileged backend deletion workflow. Never place a service-role key in the app.
- Define product rules for owned trips before deletion: delete them, transfer ownership, or require the owner to resolve them first.
- Delete or anonymize profile data, invitations, friendships, reports, posts, comments, media objects, and other UGC as promised by the privacy policy.
- Delete the Supabase Auth user last, after application data and Storage cleanup succeed.
- Revoke all sessions and Sign in with Apple tokens if Apple login is enabled later.
- Purge local Keychain, UserDefaults, trip caches, and image caches.
- Tell the user what is deleted, what must be retained, why, and for how long.
- Provide completion confirmation if deletion is asynchronous.

**Acceptance criteria:** A reviewer can create an account, initiate deletion inside the app, and verify that the account, sessions, personal data, UGC, and non-retained media are removed.

Reference: [Apple — Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

### ASC-02: Add explicit third-party AI consent and data controls

**Risk:** App Review rejection

Receipt selection immediately starts scanning ([AddExpenseView.swift](Tripsplit/AddExpenseView.swift#L389)). The online path can send a receipt image and OCR text to Google Cloud Vision and Gemini ([ReceiptService.swift](Tripsplit/ReceiptService.swift#L121), [ReceiptService.swift](Tripsplit/ReceiptService.swift#L219)). Itinerary generation also sends trip details to Gemini. No explicit pre-transfer consent or third-party disclosure was found.

**Implement:**

- Before the first cloud-assisted scan or itinerary generation, show a plain-language consent screen that names Google Cloud Vision and Google Gemini.
- Explain exactly what is transmitted, why it is transmitted, whether it is retained or used for training, and link to the full privacy policy.
- Do not preselect or bundle consent with unrelated terms.
- Record the consent version, timestamp, and provider/purpose server-side.
- Provide an offline/manual alternative when consent is declined. Receipt scanning already has an on-device path that can be developed into this fallback.
- Add a Settings control to revoke consent. Revocation must prevent future cloud transfers.
- Enforce consent on the backend as well as in the UI so modified clients cannot bypass it.
- Minimize data before transfer: crop/re-encode images, remove metadata, limit OCR text, and exclude unrelated trip information.
- Document provider retention and deletion practices in contracts and the privacy policy.

**Acceptance criteria:** No receipt, OCR text, trip detail, or itinerary prompt reaches a third-party AI service until the current user has explicitly consented to that provider and purpose.

Reference: [Apple App Review Guideline 5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/)

### ASC-03: Implement UGC safety and moderation

**Risk:** App Review rejection and user-safety exposure

The feed supports user text, photos, locations, reactions, and comments ([FeedFeature.swift](Tripsplit/FeedFeature.swift#L743)). The current database only supports deletion by the author or trip owner ([supabase_schema.sql](supabase_schema.sql#L584)).

**Implement:**

- Add a report action on posts, comments, profiles, and media.
- Store reports in a protected table with category, reporter, content snapshot/reference, status, timestamps, and moderator actions.
- Add user blocking and enforce blocks in feed, comments, friend search, invitations, notifications, and direct profile access.
- Filter objectionable content before publication using a documented automated and/or human review process.
- Provide a moderator/admin queue, escalation rules, response target, audit history, and appeal process.
- Publish community standards, Terms of Use, and support/contact information inside the app.
- Give App Review a test account and instructions for demonstrating reporting and blocking.
- Ensure reports cannot be read, modified, or deleted by ordinary users.

**Acceptance criteria:** A user can report content, block another user, immediately stop seeing/interacting with that user where applicable, and reach published support. The team can review and act on reports within its stated response period.

Reference: [Apple App Review Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/)

### ASC-04: Complete privacy policy, disclosures, and privacy manifest

**Risk:** Upload failure or App Review rejection

No `PrivacyInfo.xcprivacy` is present even though the app uses `UserDefaults` and file timestamp APIs such as `contentModificationDateKey` ([ReceiptService.swift](Tripsplit/ReceiptService.swift#L1106)). No easily accessible in-app privacy-policy link was found.

**Implement:**

- Add `PrivacyInfo.xcprivacy` to the application target and confirm it is present in the archived `.app`.
- Declare required-reason API use, including:
  - `NSPrivacyAccessedAPICategoryUserDefaults` with the approved app-only reason appropriate to current use (`CA92.1`).
  - `NSPrivacyAccessedAPICategoryFileTimestamp` with the approved app-container reason appropriate to cache pruning (`C617.1`).
- Recheck the final archive for every required-reason API rather than relying only on source search.
- Publish a privacy policy and link it in both Settings and App Store Connect.
- Document collected data, purpose, linkage to identity, tracking status, retention, deletion, consent withdrawal, security measures, and every processor/subprocessor.
- Build a formal data inventory covering at least account identifiers, profile details, birth date, location/place information, trip records, expenses, settlements, receipts, photos, posts, comments, searches stored or transmitted by the app, AI prompts, and diagnostic data.
- Complete App Store privacy answers based on actual production behavior, including third-party processing.
- Add a user privacy choices page for consent and deletion controls.

**Acceptance criteria:** Xcode’s privacy report is reviewed, the manifest is included in the Release archive, App Store privacy answers match network behavior, and the policy is reachable without signing in.

References: [Apple required-reason API requirement](https://developer.apple.com/news/upcoming-requirements/?id=05012024a) and [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)

## P1 remediation

### SEC-04: Replace custom-scheme bearer links with universal links

Invitation URLs currently use `tripsplit://invite?token=...` ([TripStore.swift](Tripsplit/TripStore.swift#L744)). Multiple apps can register the same custom scheme, and iOS does not guarantee which app receives the URL. The current app also automatically redeems a pending invitation after sign-in ([ContentView.swift](Tripsplit/ContentView.swift#L173)).

**Implement:**

- Use an HTTPS universal link on a controlled domain.
- Add the Associated Domains entitlement and host a valid `apple-app-site-association` file.
- Store only a hash of each invitation token in the database.
- Make tokens single-use, revocable, purpose-specific, and short-lived. Consider 24–72 hours instead of 14 days.
- Before mutating membership, show the trip name, inviter, expiration, and explicit **Join**/**Cancel** actions.
- Do not automatically accept an invitation merely because the user signed in.
- Rate-limit creation and acceptance; record security-relevant attempts.
- If a custom scheme remains as a fallback, fix and verify `CFBundleURLTypes` in the Release bundle and never put sensitive bearer tokens in it.

**Acceptance criteria:** Only the app associated with the controlled web domain can receive native invitation links, and opening/signing in never joins a trip without confirmation.

References: [Apple — Custom URL schemes](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app) and [Apple — Universal links](https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content/)

### SEC-05: Revoke sessions and protect local data

`signOut()` removes local state but never calls the Supabase logout/revocation endpoint ([AuthFeature.swift](Tripsplit/AuthFeature.swift#L467)). The Keychain item is available after first unlock ([AuthFeature.swift](Tripsplit/AuthFeature.swift#L343)). Trip, profile, and image caches can remain after sign-out ([TripStore.swift](Tripsplit/TripStore.swift#L844)).

**Implement:**

- Call Supabase logout before local cleanup; always perform local cleanup even if the network call fails.
- Support revoking all sessions after password change, suspected compromise, and account deletion.
- Change Keychain accessibility to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` unless a documented background requirement prevents it.
- Check and handle Keychain API return statuses.
- Apply explicit iOS file-protection attributes to local trip and media caches.
- Purge user-scoped caches on sign-out and deletion, or provide a clearly justified and documented retention design.
- Ensure sensitive files are excluded from backup if moved outside the Caches directory.
- Add a future **Devices/Sessions** screen if multi-device session management is important.

### SEC-06: Prevent email enumeration and forced membership

The invitation RPC reveals whether an email is registered and immediately adds an existing account to the trip ([supabase_schema.sql](supabase_schema.sql#L224)). The UI then presents a distinct “No account found” response ([TripStore.swift](Tripsplit/TripStore.swift#L719)).

**Implement:**

- Always return the same generic response regardless of account existence.
- Keep every email invitation pending until the recipient accepts it.
- Notify the recipient through a controlled email or in-app invitation flow.
- Rate-limit invitations per owner, trip, recipient, and IP/device risk signal.
- Add expiration, revoke, decline, and abuse-report actions.
- Do not expose target user IDs or account-existence state to the inviter.

### SEC-07: Add server-side resource and abuse limits

The 5 MB receipt limit is enforced only by the client ([ReceiptService.swift](Tripsplit/ReceiptService.swift#L879)). Modified clients can bypass client limits and create provider or Storage costs.

**Implement:**

- Configure Storage file-size and MIME allowlists at the bucket.
- Validate image signatures, decoded dimensions, compression bombs, and attachment counts server-side.
- Enforce user/trip storage quotas and cleanup of orphaned uploads.
- Count AI provider attempts when they incur upstream work, including invalid provider responses—not only successful output.
- Add per-user, per-IP, per-device-risk, and global provider-budget controls.
- Configure Supabase Auth signup, login, reset, and email rate limits; enable anti-bot protections suitable for the launch audience.
- Add quotas for invite creation, profile lookup, signed URLs, feed publishing, comments, and reports.
- Alert on repeated authorization failures, rate-limit bursts, provider-cost spikes, and Storage growth.

### OPS-01: Create reproducible database deployment and authorization tests

The repository has a large desired-state [supabase_schema.sql](supabase_schema.sql), but the versioned migrations begin with later feed/normalization changes and do not provide a complete baseline. SQL in the repository is not proof that the deployed Supabase project has the same policies.

**Implement:**

- Safely baseline or squash the complete schema into versioned migrations. Account for migrations already recorded in production before changing history.
- Confirm a fresh local project can run `supabase db reset` without manual SQL steps.
- Dump and compare staging/production functions, grants, RLS policies, Storage policies, and function ownership with the reviewed state.
- Use `security definer` only where necessary, always pin `search_path`, validate `auth.uid()`, and narrowly grant execution.
- Run Supabase database/security advisors and resolve warnings before release.
- Add pgTAP or equivalent integration tests for every table, function, and Storage access path.
- Test with anonymous, unrelated authenticated, owner, member, removed member, blocked user, and deleted user identities.
- Run those tests in CI against a disposable local Supabase instance.

## Release and App Store work

### REL-01: Resolve packaging and submission gaps

**Implement before TestFlight/App Review:**

- Complete: a 1024×1024 `AppIcon.appiconset` is present and compiles for iPhone/iPad.
- Verify the privacy manifest and all required entitlements are embedded in the signed archive.
- Verify universal-link entitlements and the production `apple-app-site-association` response.
- Complete for the current fallback: `CFBundleURLTypes` contains `tripsplit` in the built Release app.
- Complete: Debug and Release marketing versions are both 1.1.
- Decide the minimum supported iOS version intentionally and test upgrades from the oldest supported release.
- Sign in with Apple is currently disabled and its entitlements are not connected to the target ([AuthFeature.swift](Tripsplit/AuthFeature.swift#L25)). This is not required for email/password-only authentication. If another social login is added, reevaluate App Review Guideline 4.8 and fully configure Apple login.
- Resolve Swift concurrency warnings that are expected to become errors in Swift 6 language mode.
- Validate camera and location purpose strings against actual behavior and provide manual alternatives where appropriate.
- Complete export-compliance answers for HTTPS and Keychain encryption use.
- Prepare App Review credentials, deletion instructions, AI consent instructions, UGC moderation instructions, backend availability, and support contact information.
- Test a signed Release archive on physical devices, including fresh install, upgrade, offline mode, expired sessions, denied permissions, and account deletion.

## Required security test matrix

At minimum, automate these stories before production:

| Area | Required test |
| --- | --- |
| Trips | Outsider and removed member cannot read or mutate a trip |
| Expenses | Member B cannot edit/delete member A’s expense unless explicitly authorized |
| Settlements | Only the intended party can confirm or cancel each state transition |
| Comments | Author identity is server-derived; unauthorized edit/delete fails |
| Metadata | Member cannot change owner, membership, or protected trip fields |
| Storage | A user cannot sign or download an unrelated exact object path |
| Redirects | Cross-origin and HTTPS downgrade redirects never receive credentials |
| Invitations | Expired, revoked, replayed, malformed, and already-used tokens fail |
| Invitations | Opening a valid link does not join until the user confirms |
| Email privacy | Invite responses do not reveal whether an account exists |
| AI consent | Backend rejects AI work without current recorded consent |
| AI limits | Failed/invalid paid provider calls still consume applicable quota |
| Blocking | Blocked users and their content are hidden according to product rules |
| Reports | Ordinary users cannot inspect or alter moderation records |
| Sessions | Sign-out/revoke prevents refresh-token reuse where promised |
| Deletion | Deleted account cannot authenticate; promised data and media are removed |
| Local privacy | Account switching and sign-out do not reveal prior user data |

## Suggested delivery order

1. Freeze public launch and document the authorization capability matrix.
2. Replace whole-document mutations and add RLS/RPC integration tests.
3. Fix authenticated redirects and Storage object authorization.
4. Implement session revocation, invitation hardening, and server abuse limits.
5. Implement account deletion and its data-lifecycle backend.
6. Implement AI consent, privacy policy, privacy inventory, and App Store disclosures.
7. Implement UGC reporting, blocking, filtering, moderation operations, and support.
8. Add the privacy manifest, universal links, app icon, and release configuration fixes.
9. Run a clean database deployment, signed archive validation, TestFlight security pass, and targeted penetration test.
10. Submit only after every P0/P1 acceptance criterion is evidenced and repeatable.

## Definition of App Store ready

TripSplit is ready to submit when all of the following are true:

- Every P0 and P1 gate in this document is complete and tested.
- Backend authorization remains secure against a modified or direct REST client.
- Production database and Storage policies match reviewed versioned migrations.
- A signed Release archive includes the correct icon, privacy manifest, entitlements, versions, and usage descriptions.
- Privacy policy, App Store privacy answers, AI consent, retention, and deletion behavior match the actual data flow.
- UGC reporting, blocking, filtering, support, and moderation operations are live.
- Account deletion works end-to-end on production-like infrastructure.
- Abuse limits, alerting, backups, recovery, and incident ownership are documented.
- A physical-device TestFlight pass covers new account, shared trip, receipt scan, AI decline, permissions decline, invitation confirmation, reporting/blocking, sign-out, and deletion.
- App Review receives a functioning demo account and concise instructions for protected or non-obvious features.

## Verification notes from this review

- Unsigned generic Debug simulator build after implementation: passed.
- Unsigned optimized arm64 Release simulator build after the final implementation pass: passed.
- Unit tests: 16 passed on an iPhone 17 / iOS 26.5 simulator, including same-origin/cross-origin/downgrade redirect checks and redirect-loop bounding.
- The built Release `.app` was inspected: `PrivacyInfo.xcprivacy` is present and valid, the AppIcon is compiled, `CFBundleShortVersionString` is 1.1, and the `tripsplit` fallback scheme is present.
- All Edge Function TypeScript files pass a Node type-stripping syntax/import check with a stubbed Deno global.
- Structural pgTAP security tests were added but not executed because this workspace has no usable Docker/Postgres runtime. Behavioral RLS/Storage/account-deletion tests still require staging.
- Existing native tests primarily cover calculations, model round-trips, and redirect containment; they do not prove deployed database authorization or abuse resistance.
- Release compilation still reports Swift 6 actor-isolation migration warnings in repository/model encoding and export helpers. They are warnings under the current Swift 5 language mode, but should be resolved before enabling Swift 6 mode.
- No third-party package dependencies were detected.
- Supabase Edge Functions are configured to verify JWTs.
- No private backend/provider credential was found in the client.
- The backend review remains repository-based. The live Supabase project, DNS/domain configuration, App Store Connect metadata, provider contracts, and operational moderation process still require direct verification.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Approved reasons for APIs](https://developer.apple.com/news/upcoming-requirements/?id=05012024a)
- [Defining a custom URL scheme](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app)
- [Allowing apps and websites to link to your content](https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content/)

# TripSplit

TripSplit is a SwiftUI iOS app backed by hosted Supabase in normal Debug and Release builds. For backend development, it can opt into an isolated local Supabase stack managed by the Supabase CLI and a Docker-compatible runtime. The iOS app, Simulator, signing, and App Store workflow remain native to macOS.

## Local backend prerequisites

- macOS with Xcode 26 for app and Simulator work.
- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) 2.115.0, matching CI.
- A running Docker-compatible runtime: Docker Desktop, OrbStack, Colima, or Rancher Desktop.
- `curl`, `jq`, and `uuidgen` for the Edge Function smoke suite.
- Deno for `make functions-check`; CI uses Deno 2.9.5.

The Docker runtime is required only for local Supabase and integration tests. Ordinary Swift unit and UI tests do not need Docker.

## First-time setup

From the repository root:

```bash
cp supabase/functions/.env.example supabase/functions/.env.local
make backend-up
make backend-reset
make backend-test
make functions-check
make functions-unit-test
make functions-test
```

The copied `.env.local` file is ignored by Git and intentionally contains no provider credentials. `make functions-test` first checks safe missing-provider behavior, then enables deterministic local mocks for authenticated function paths. It does not call paid providers.

Useful local services are:

| Service | Local address |
| --- | --- |
| API, Auth, Storage, and Functions | `http://127.0.0.1:54321` |
| PostgreSQL | `127.0.0.1:54322` |
| Supabase Studio | `http://127.0.0.1:54323` |
| Mailpit | `http://127.0.0.1:54324` |

Run `make backend-status` to confirm the actual addresses and health. Stop the stack when finished:

```bash
make backend-down
```

The equivalent raw Supabase sequence is:

```bash
supabase start
supabase db reset
supabase test db
supabase functions serve --env-file supabase/functions/.env.local
supabase stop
```

`supabase functions serve` stays in the foreground. Use another terminal for app or HTTP testing.

## Selecting local or hosted Supabase

Backend selection is compile-time and centralized in `BackendEnvironment`:

| Build | Backend |
| --- | --- |
| Normal Debug | Hosted production Supabase |
| Debug with `LOCAL_SUPABASE` | Local `127.0.0.1:54321` |
| Release | Hosted production Supabase over HTTPS only |

To run the app against Docker from Xcode:

1. Start the stack with `make backend-up`.
2. Select the TripSplit app target and its Debug build settings.
3. Add `LOCAL_SUPABASE` to **Active Compilation Conditions** for Debug only.
4. Build and run in the iOS Simulator.
5. Remove `LOCAL_SUPABASE` to return ordinary Debug builds to hosted Supabase.

Never add the flag to Release. A physical iPhone cannot use this loopback setup because `127.0.0.1` would refer to the phone; local physical-device networking is intentionally out of scope.

To confirm that the app is local, run `make backend-status`, create a fictional account or trip, and verify it appears in local Studio. The backend environment unit test also asserts that a build with `LOCAL_SUPABASE` resolves exactly to `http://127.0.0.1:54321`. Stopping the local stack should cause a quick connection error rather than exposing hosted data.

## Test users and data

With `LOCAL_SUPABASE` enabled, create a fictional account through the app's normal sign-up screen. Local email confirmation is disabled by the checked-in Supabase configuration, so the account can be used immediately and inspected under Authentication in local Studio.

No permanent seed data is required. The integration and Edge Function suites create unique fictional users and records, then delete them. Rebuild an empty local database at any time with:

```bash
make backend-reset
```

This removes local data and reapplies every file in `supabase/migrations/`. Those migrations are authoritative; do not apply the retired root `supabase_schema.sql` to a clean database.

## Edge Functions and external providers

All Edge Functions require a signed-in user's JWT. Provider secrets stay in local ignored files or hosted Supabase secrets and must never enter Swift source, Xcode settings, or Git.

| Function | External provider in configured environments | Safe local default |
| --- | --- | --- |
| `delete-account` | None | Uses local Supabase only |
| `send-invitation` | Resend | HTTP 503 without a key; deterministic local mock in tests |
| `ocr-receipt` | Google Cloud Vision | HTTP 503 without a key; deterministic local mock in tests |
| `parse-receipt` | Anthropic, then Gemini fallback | HTTP 503 without a key; deterministic local mock in tests |
| `suggest-itinerary` | Anthropic, then Gemini fallback | HTTP 503 without a key; deterministic local mock in tests |

To exercise a paid provider manually, add only a development credential to `.env.local` and restart `supabase functions serve`. Never use production credentials in local automation. `LOCAL_PROVIDER_MOCKS=true` is accepted only by the local HTTP runtime and cannot enable mocks on hosted HTTPS Supabase.

## Testing

Backend validation:

```bash
make backend-reset
make backend-test
make functions-check
make functions-unit-test
make functions-test
```

The database suite currently runs 70 pgTAP checks, including authorization, delta synchronization, and paged trip reads. The function suite checks missing and malformed JWTs, missing-provider behavior, authenticated mock responses, invitation ownership, and account deletion without paid calls.

Run ordinary native tests from Xcode, or use an available Simulator ID:

```bash
xcodebuild -project Tripsplit.xcodeproj -scheme Tripsplit -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:TripsplitAppTests test

xcodebuild -project Tripsplit.xcodeproj -scheme Tripsplit -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:TripsplitAppUITests test
```

The opt-in authenticated and outage commands are maintained in `DOCKER_SUPABASE_IMPLEMENTATION_PLAN.md` for local regression work.

## Continuous integration

`.github/workflows/ci.yml` runs two isolated jobs:

- Linux installs Supabase CLI 2.115.0 and Deno 2.9.5, starts local Supabase, rebuilds all migrations, runs database security tests, type-checks functions, and runs provider-free function smoke tests. Container and function logs are uploaded after failures, and the stack is always stopped.
- macOS 26 builds with Xcode 26 and runs the Swift unit and UI suites. It compiles with `LOCAL_SUPABASE` but does not start Docker, so native tests stay Docker-independent and cannot contact production.

The workflow has read-only repository permission, receives no Supabase project token, and defines every paid-provider key as empty. It validates local state only and cannot deploy or mutate hosted Supabase.

## Troubleshooting

### The container runtime is unavailable

Run `docker info`. Start Docker Desktop, OrbStack, Rancher Desktop, or `colima start`, then retry `make backend-up`. The Make targets stop early with a focused prerequisite error when Docker or the Supabase CLI is missing.

### A local port is already in use

Run `make backend-status` and stop another TripSplit stack with `make backend-down`. Check ports 54321–54324 for unrelated processes. Avoid changing only one port: the Debug origin allowlist intentionally requires the exact configured API origin.

### A migration or database test fails

Run `make backend-reset`, then `make backend-test`. Fix the versioned migration rather than editing the local database through Studio. A reset must succeed from an empty database and must not contact the hosted project.

### Sign-in says the server cannot be reached

If the build has `LOCAL_SUPABASE`, confirm `make backend-status` reports healthy services at `127.0.0.1:54321`. Start the stack or remove the flag to use the normal hosted Debug backend. Do not use the loopback flag on a physical device.

### An Edge Function returns 401 or 503

HTTP 401 means the request lacks a valid signed-in user JWT. HTTP 503 is expected when a paid provider is intentionally unconfigured. Copy `.env.example` to `.env.local`, restart the function server, and use `make functions-test` for deterministic local coverage. Function logs are written to `supabase/.test-results/functions-serve.log` during the smoke suite.

### Local state is disposable or inconsistent

`make backend-reset` removes local database contents and reapplies migrations. If the containers themselves need a clean rebuild, stop local Supabase without backup and start it again; this destroys only the local stack, so export anything you need first.

## Performance and synchronization

Trip refreshes use `fetch_trip_summaries_v1` in 100-row pages and retrieve changed or
missing complete documents through `fetch_trip_details_v1` in batches of 25. Warm
refreshes reuse server snapshots only when their exact revision matches. Cold loads
still populate complete financial records so home balances and offline editing stay
accurate. Submitted edits are kept separate from these authoritative read snapshots.

`sync_trip_delta_v1` accepts changed metadata, changed child records, and explicit
removal IDs. Unseen concurrent records are preserved. Unchanged saves skip the
network. Older deployments retain the normalized and legacy RPC fallbacks; apply all
ordered migrations before deploying the matching app for the new endpoints to work.

The feed loads 40 posts at a time with a timestamp/UUID cursor and a **Load older
posts** button. Map locations use a separate paged projection without comments or
reactions, so map coverage does not depend on how far the feed has been scrolled.

Receipt and itinerary functions log one `request_timing` JSON event per request,
with durations for authentication, consent, quota, each provider attempt, and quota
completion. Responses also include `Server-Timing`. Metrics exclude request bodies,
user identifiers, tokens, URLs, and provider error text. Provider timeout budgets
are unchanged pending real-provider latency measurements.

For smoke tests using only the checked-in provider-free configuration:

```bash
make functions-test FUNCTIONS_ENV=supabase/functions/.env.example
```

The reserved HTTPS invitation URL in that template is a mock placeholder, not a
production invitation destination.

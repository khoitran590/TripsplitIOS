# TripSplit — File Split Plan + Product PR Roadmap

Read-only planning document for implementing structural refactors and product improvements.
Feed this file to another model/agent as the source of truth for execution.

**Project:** TripSplit — native iOS SwiftUI app (expense splitting + light trip planning)  
**Real app target:** `Tripsplit.xcodeproj` + `Tripsplit/*.swift`  
**Not the app:** `Package.swift`, `Sources/Tripsplit/`, `Tests/TripsplitTests/` (dead SPM Hello World — never add app code/tests there)

---

## Critical project hard rules (do not break)

These exist because each has already caused a real shipped bug:

1. **New model fields must decode with `decodeIfPresent(...) ?? default`.**  
   Trips persist as one long-lived JSON blob (`public.trips.data`). Missing keys on old trips must not throw — undecodable trips **silently vanish** via `compactMap` in fetch.

2. **Never mutate `@Observable` state off the main actor.**  
   `TripStore` is `@MainActor`. Network I/O lives in actors; apply results on main.

3. **Lowercase user UUID in every Storage path.**  
   Private `receipts` bucket paths: `"<user-uuid-lowercased>/<file>.jpg"`.

4. **Image fields store object *path*, not URL.**  
   Use `CachedStorageImage` / `TripStore.signedImageURL(for:)`. Never feed signed URLs to `AsyncImage` as cache keys; never use public bucket URLs.

5. **All split math goes through `SplitEngine`.**  
   Integer cents + largest-remainder. Currency changes must also update `TripStore.applyingCurrencyConversion`.

6. **No API keys in the app bundle.**  
   AI/paid APIs only via Supabase Edge Functions.

7. **Keep client, `supabase_schema.sql`, and live DB in sync.**  
   DDL idempotent; apply to linked project when schema changes.

8. **Localized UI text must not go through `Text(String)`.**  
   Use `LocalizedStringKey(...)` for localizable labels; `Text(verbatim:)` only for dynamic content.

### Architecture constraints

- **No third-party dependencies.** Pure SwiftUI + Foundation + system frameworks.
- **No Supabase Swift SDK.** Direct REST over `URLSession`.
- **One vertical-slice style** is OK — models + store + views can stay feature-oriented. Do **not** introduce MVVM/DI frameworks unless explicitly asked.
- **Verification:** clean `xcodebuild` is enough unless user asks for simulator. Do not invent work in the dead SPM test package.
- **Surgical changes:** only touch what the PR requires; no drive-by cleanups.

### Build command

```sh
xcodebuild -project Tripsplit.xcodeproj -scheme Tripsplit \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# If destination missing:
xcrun simctl list devices available
```

---

## Current size snapshot (approx)

| File | Lines | Role |
|---|---:|---|
| `TripFeature.swift` | ~5,760 | Models, store, repo, trip/expense UI, shared UI |
| `ContentView.swift` | ~3,969 | App shell, map, explore catalog, settings, dock |
| `ItineraryFeature.swift` | ~2,155 | Planner + AI suggestions |
| `HomeScreen.swift` | ~1,433 | Dashboard |
| `ReceiptService.swift` | ~1,173 | OCR/AI/storage/cache |
| `FeedFeature.swift` | ~1,141 | Trip social feed |
| `SplitFeature.swift` | ~1,023 | Person/split models, engine, split/settle UI |
| **Total app Swift** | **~19,000** | |

### `TripFeature.swift` MARK map (line ranges)

| Lines | MARK | ~Size |
|---:|---|---:|
| 10–473 | Trip Models | 464 |
| 474–1712 | Trip Store | 1,239 |
| 1713–1920 | Trips repository | 208 |
| 1921–2009 | Currency helper | 89 |
| 2010–2198 | Cover photo cropping | 189 |
| 2199–2535 | Add Trip | 337 |
| 2536–2862 | Edit Trip | 327 |
| 2863–3969 | Trip Detail | 1,107 |
| 3970–4222 | Expense Detail | 253 |
| 4223–5178 | Add Expense | 956 |
| 5179–5344 | Per-item split configuration | 166 |
| 5345–5506 | Shared pieces (swipe, TripCard) | 162 |
| 5507–5628 | Location autocomplete | 122 |
| 5629–5760 | Trip cover / avatars | 132 |

### `ContentView.swift` major blocks (approx)

| Block | ~Lines |
|---|---:|
| App entry + keyboard + `ContentView` | ~260 |
| Map model + Map UI | ~1,400 |
| Explore screen + filters | ~520 |
| Destination models + hardcoded catalog | ~760 |
| Destination cards / detail | ~280 |
| Settings + profile chrome | ~400 |
| Dock | ~100 |

### Cross-file dependencies (must remain accessible after split)

Symbols defined in `TripFeature.swift` used elsewhere:

| Symbol | Used by |
|---|---|
| `Trip`, `Expense`, `ReceiptItem`, `ExpenseComment` | Home, Feed, Itinerary, Receipt, Split |
| `TripStore` (+ methods; Feed/Itinerary use `extension TripStore`) | Almost everything |
| `AddTripView`, `AddExpenseView`, `TripDetailView` | Home, Itinerary |
| `AvatarView`, `InitialsAvatar`, `TripCoverView` | Feed, Profile, Home, Itinerary, ContentView |
| `SwipeActionsRow`, `SwipeToDeleteRow`, `RowSwipeAction` | Home, Itinerary |
| `UploadImagePreparation`, `CoverCropView`, `LocationField` | Feed, Itinerary |
| `currencySymbol`, `supportedCurrencies` | Multiple UIs |

Symbols from `ContentView.swift` used elsewhere:

| Symbol | Used by |
|---|---|
| `SettingsScreen`, `ProfileAvatar` | Home, Profile |
| `Destination`, `MapPlace` | Profile |
| `DockTab` / shell | Splash, Onboarding, Home |
| `KeyboardDismissInstaller` | Splash |

**Note:** `Person`, `SplitMethod`, `SplitEngine`, `Settlement*` live in `SplitFeature.swift` today but are core domain.

---

# Track A — File split plan

## Goals

- Make mega-files navigable
- **Zero behavior change** (mechanical moves + Xcode target membership)
- Preserve hard rules and vertical-slice philosophy
- Prefer flat `Tripsplit/*.swift` (no forced `Models/` / `Views/` layout)

## Non-goals

- No logic rewrites during splits
- No renaming path fields in the same PR as a move
- No schema/backend changes for Track A
- No app code in dead SPM package

## Target layout (after Track A)

```
Tripsplit/
  # App shell
  ContentView.swift          # MyApp, ContentView, DockTab only (~250–400 lines)
  FloatingDock.swift
  KeyboardDismiss.swift

  # Core domain
  PersonModels.swift         # Person, SplitMethod (from SplitFeature)
  TripModels.swift           # Expense, ReceiptItem, ExpenseComment, Trip + balance helpers
  SplitEngine.swift          # SplitResult, Settlement*, SplitEngine (pure)
  SplitViews.swift           # SplitView, SettleView (or keep name SplitFeature.swift)
  CurrencyFormat.swift       # currencySymbol, supportedCurrencies, member color palette

  # Store / network
  TripStore.swift            # TripStore + TripsCacheWriter
  TripsRepository.swift

  # Trip UI
  AddTripView.swift
  EditTripView.swift
  TripDetailView.swift
  ExpenseDetailView.swift
  AddExpenseView.swift
  ItemSplitConfigView.swift  # optional separate; can stay inside AddExpenseView
  CoverCropView.swift
  LocationField.swift
  TripSharedUI.swift         # swipe rows, TripCard, cover, avatars, UploadImagePreparation

  # Explore / Map / Settings (from ContentView)
  ExploreModels.swift
  ExploreDestinations.json   # optional (A5b / B9)
  ExploreScreen.swift
  MapFeature.swift
  SettingsScreen.swift

  # Existing feature files (structure unchanged unless noted)
  HomeScreen.swift
  FeedFeature.swift          # keeps extension TripStore { feed... }
  ItineraryFeature.swift     # keeps extension TripStore { itinerary... }
  ReceiptService.swift
  AuthFeature.swift
  ProfileFeature.swift
  ...
```

`FeedFeature` / `ItineraryFeature` already use `extension TripStore`. After split, `TripStore` remains **one class in one file**; extensions stay in feature files. Same module = fine.

---

## PR A0 — Safety net (do first)

### Why

Splits without tests are hope-driven. Pure money math is the highest-value unit-test surface.

### Scope

1. Add a real **Xcode unit test target** linked to the **app** `Tripsplit` module (not SPM).
2. Tests only (no product UI):
   - `SplitEngine.equalShares` remainder / sum-exact cases
   - `SplitEngine.allocateProportionally`
   - `SplitEngine.calculate` for each `SplitMethod`
   - `SplitEngine.settleUp` deterministic pairing for fixed nets
   - `Trip.share` / `netBalances` / `remainingOwed` with confirmed `SettlementRecord`s
   - Encode → decode a `Trip` **missing newer keys** (hard rule 1)
3. Do **not** put these tests under `Tests/TripsplitTests` SPM stub.

### Verify

- Test target builds and passes
- App target still builds

### Risk

Low. ~200–400 lines of tests.

---

## PR A1 — Extract pure models + engine (no UI moves)

### Moves (cut/paste, no logic change)

| From | To | Approx lines |
|---|---|---:|
| `SplitFeature.swift` models + engine (~L3–285) | `PersonModels.swift` + `SplitEngine.swift` | ~280 |
| `TripFeature.swift` L10–472 | `TripModels.swift` | ~460 |
| `TripFeature.swift` L1921–2009 | `CurrencyFormat.swift` | ~90 |

### Suggested files

1. **`PersonModels.swift`** — `Person`, `SplitMethod`
2. **`SplitEngine.swift`** — `SplitResult`, `Settlement`, `PaymentMethod`, `SettlementStatus`, `SettlementRecord`, `SplitEngine`
3. **`TripModels.swift`** — `Expense`, `ReceiptItem`, `ExpenseComment`, `Trip` + extensions
4. **`CurrencyFormat.swift`** — `currencySymbol`, `supportedCurrencies`, member color palette if in that block

### Leave in place

- `SplitView` / `SettleView` in `SplitFeature.swift` (optionally rename file → `SplitViews.swift` same PR)
- Entire `TripStore` and all trip UI still in `TripFeature.swift`

### Optional micro-fix (only if bundling with A1)

`SettlementRecord` uses `let id = UUID()` with synthesized Codable — identity may not round-trip. Prefer explicit `CodingKeys` + `decodeIfPresent` default (same pattern as other models). Do **not** broaden scope beyond that.

### Xcode

Add new `.swift` files to the `Tripsplit` app target (`project.pbxproj` or Xcode UI).

### Verify

Clean build + A0 tests green.

### Risk

Low if method bodies are not edited.

---

## PR A2 — Extract repository + store

### Moves

| From | To | Approx lines |
|---|---|---:|
| `TripFeature.swift` L474–1712 | `TripStore.swift` | ~1,240 |
| `TripFeature.swift` L1713–1920 | `TripsRepository.swift` | ~210 |

### Care points

- Keep `TripsCacheWriter` private actor with the store (same file).
- JWT helpers (`jwtPayload`, `userID(fromJWT:)`, etc.) are currently `fileprivate` on `TripStore` — keep them in `TripStore.swift` unless `TripsRepository` needs them (then make `internal` carefully).
- Ensure `extension TripStore` in `FeedFeature.swift` / `ItineraryFeature.swift` still resolves.
- **No behavior edits** to debounce / latest-wins sync / offline cache.

### After A2

`TripFeature.swift` is **UI-only** (~3,800 lines).

### Verify

Clean build + A0 tests. Mentally check sign-in → `loadFromCloud` compile path.

### Risk

Medium (sync code is subtle). Mechanical move only.

---

## PR A3 — Extract shared UI primitives

### Moves from bottom / mid of `TripFeature.swift`

| Block | New file | ~Lines | External dependents |
|---|---|---:|---|
| Cover crop L2010–2198 | `CoverCropView.swift` | 189 | Itinerary |
| Shared pieces L5345–5506 | `TripSharedUI.swift` | 162 | Home, Itinerary |
| Location L5507–5628 | `LocationField.swift` | 122 | Itinerary |
| Cover/avatars L5629–5760 | `TripSharedUI.swift` or `TripCoverAvatar.swift` | 132 | Feed, Profile, Home |
| `UploadImagePreparation` (~L1947) | `TripSharedUI.swift` or own file | — | Feed, Itinerary |

### Verify

Home swipe-to-archive, feed avatars, itinerary cover crop compile.

### Risk

Low.

---

## PR A4 — Extract trip screens (one file per MARK)

| MARK | New file | ~Lines |
|---|---|---:|
| Add Trip | `AddTripView.swift` | 337 |
| Edit Trip | `EditTripView.swift` | 327 |
| Trip Detail | `TripDetailView.swift` | 1,107 |
| Expense Detail | `ExpenseDetailView.swift` | 253 |
| Add Expense | `AddExpenseView.swift` | 956 |
| Per-item split | `ItemSplitConfigView.swift` (or keep inside AddExpense) | 166 |

### End state

Delete empty `TripFeature.swift` (or leave a short pointer comment — prefer delete).

### Verify

Clean build. Paths: Add Trip / Add Expense / Trip Detail / Expense Detail.

### Risk

Low–medium (Trip Detail is large).

---

## PR A5 — Split `ContentView.swift`

### Target files

| Block | New file |
|---|---|
| App entry + keyboard + `ContentView` | keep `ContentView.swift` |
| Map model + Map UI | `MapFeature.swift` |
| Explore screen + filters + cards/detail | `ExploreScreen.swift` (+ optional `ExploreCards.swift`) |
| Destination models + catalog | `ExploreModels.swift` |
| Settings + `PlainSettingsRow` / `ProfileAvatar` | `SettingsScreen.swift` |
| Dock | `FloatingDock.swift` |
| Keyboard dismiss helpers | `KeyboardDismiss.swift` (optional) |

### Recommended sub-order inside A5

1. `SettingsScreen.swift` (Home presents settings)
2. `FloatingDock.swift` + `DockTab` placement
3. `MapFeature.swift` (`ExploreMapModel` environment wiring)
4. `ExploreModels.swift` + `ExploreScreen.swift`

### Optional A5b

Move `Destination.all` into `ExploreDestinations.json` + loader (can also be product PR B9).

### Verify

Tab shell, map, explore, settings from Home all compile.

### Risk

Medium only for map focus / environment object wiring.

---

## PR A6 — Housekeeping (optional)

- Delete or quarantine SPM stub so nobody tests the wrong module
- Update `CLAUDE.md` / this doc file table to match new names
- Grep for orphaned imports after moves
- No drive-by refactors

---

## Mechanical checklist (every Track A PR)

1. Create new file(s) with **exact** moved text (preserve hard-rule comments).
2. Add files to the **app** Xcode target.
3. Remove originals from the old file.
4. Build with `xcodebuild` (see command above).
5. Run A0 unit tests.
6. Do **not** reformat-for-style or clean adjacent code in the same PR.

### Do not during splits

- Introduce protocols/DI for `TripStore`
- Break `extension TripStore` into a protocol unless forced
- Move Edge Functions / SQL
- Rename types in the same PR as a move (rename later when green)

### Expected outcome

| Before | After (order of magnitude) |
|---|---|
| `TripFeature.swift` ~5.8k | gone; largest piece ~1.1k (`TripDetailView`) |
| `ContentView.swift` ~4.0k | ~200–400 shell |
| `SplitFeature.swift` ~1.0k | views ~700; models/engine extracted |

### Track A definition of done

- [ ] No file over ~1,200 lines without a clear single responsibility
- [ ] Docs (`CLAUDE.md`) file map updated
- [ ] A0 tests green + app target clean build
- [ ] Zero intentional behavior change

---

# Track B — Product PR roadmap

Product PRs can start after A1 (stable models) or earlier if they avoid the same files as an in-flight split PR.

## Suggested theme order

```
B1  Settings honesty (stubs)
B2  Display currency preference
B3  Settlement deep links / share
B4  Push notifications (real)
B5  Export trip summary
B6  Search / filter expenses
B7  Enable Sign in with Apple
B8  Itinerary ↔ expense bridge
B9  Explore content as JSON/CMS
B10 Normalize trip storage (long-term epic)
```

---

## PR B1 — Settings honesty pass

### Problem

Settings rows **Payments** and **Notifications** look tappable but do nothing (`ContentView` / `SettingsScreen`).

### Options per row

| Approach | When |
|---|---|
| Implement minimal useful behavior | ≤1 day of work |
| Disable + “Coming soon” | Don’t want fake chrome |
| Remove | Prefer clean UI |

### Recommended MVP

- **Notifications:** sheet with local `@AppStorage` toggles + copy that push is coming; **or** hide until B4.
- **Payments:** sheet explaining Cash / Venmo / PayPal / Cash App used in settle-up; optional default payment method `@AppStorage` preselected in `SettleView`.

### Files likely

Settings UI, `SettleView` / `SplitFeature`, `Localizable.xcstrings`

### Schema

None.

### Risk

Low.

---

## PR B2 — Home display currency preference

### Problem

`TripStore.baseCurrency` is hard-coded `"USD"` for BalanceCard aggregation.

### Design

1. `@AppStorage("displayCurrency")` (local first; profile later optional).
2. Settings → Preferences → “Home currency” picker using `supportedCurrencies`.
3. Generalize `homeTotals` / `toUSD` → display-currency conversion via existing rates (`CurrencyService`).
4. BalanceCard + converter respect preference; trip detail stays on trip currency.

### Hard rules

- Conversion via existing rate helpers only
- Trip currency change still only through `applyingCurrencyConversion`
- Split math still `SplitEngine`

### Acceptance

- Mixed EUR + JPY trips; home set to EUR → card in EUR
- Missing rates → graceful fallback, not wrong totals

### Risk

Medium (aggregation when rates missing).

---

## PR B3 — Settlement actions that do something

### Problem

Payment methods are labels only.

### MVP

1. Settlement row → **Share** sheet:  
   `You owe {name} {amount} {currency} for {trip}`
2. Optional URL schemes (best-effort, fail soft) for Venmo / Cash App / PayPal
3. Default method from B1 prefs if present

### Out of scope

Real payment APIs / PCI / API keys in client.

### Files

`SettleView`, small helper e.g. `PaymentLinkBuilder`

### Risk

Low.

---

## PR B4 — Push notifications (epic; multi-PR)

### Phases

| Phase | Work |
|---|---|
| B4a | APNs capability, device token → DB table, upload on sign-in |
| B4b | Server events: invite accepted, settlement pending, expense added |
| B4c | Settings toggles honor categories server-side; deep links into trip/settle/expense |

### Schema (must update `supabase_schema.sql` **and** live DB)

- `device_tokens(user_id, token, platform, updated_at)` with RLS (user owns rows)
- Optional notification prefs on `profiles`

### Client

- Register remote notifications after auth
- Upload token; deep link handling
- Prefer Edge Function with server secret for APNs (hard rule 6)

### Risk

High operationally (certs, provisioning, backend).

### Acceptance

User A records settlement → User B gets push when app backgrounded.

---

## PR B5 — Export / share trip summary

### MVP

- Trip detail menu → “Export summary”
- PDF via `UIGraphicsPDFRenderer` or plain text (no new deps):
  - Members, budgets, expenses, net balances, open settlements
- System share sheet

### Later

CSV export.

### Files

New `TripExport.swift` + entry point in `TripDetailView`

### Schema

None.

### Risk

Low–medium (layout). Prefer after A4 if also splitting Trip Detail.

---

## PR B6 — Search & filter expenses

### MVP (Trip Detail)

- Search: title contains
- Filters: payer, participant, date range, has receipt

### Later

Global search on Home.

### Files

Primarily `TripDetailView`

### Risk

Low.

---

## PR B7 — Enable Sign in with Apple

### Already scaffolded

`SupabaseConfig.appleSignInEnabled = false` with entitlement comments.

### Checklist

1. Paid Apple Developer team + `Tripsplit.entitlements` Sign in with Apple
2. Flip `appleSignInEnabled = true`
3. Configure Apple provider in Supabase dashboard
4. Test account linking with existing email users

### Risk

Medium (account merge). No split-math impact.

---

## PR B8 — Itinerary ↔ expenses bridge

### MVP

- Itinerary stop with `cost > 0` → “Add as expense” prefills `AddExpenseView`
- Optional: `Expense` field linking stop id — **must** use `decodeIfPresent ?? nil` (hard rule 1)
- If new monetary fields: extend `applyingCurrencyConversion` (hard rule 5)

### Risk

Medium (model evolution + UX).

---

## PR B9 — Explore content extraction

### Ideal dependency

Track A5 (`ExploreModels` already extracted).

### Work

1. Move `Destination.all` catalog → `ExploreDestinations.json` in bundle
2. Loader preserving model shapes and stable destination ids
3. Keep images in `Assets.xcassets`

### Later

OTA catalog from Supabase Storage.

### Risk

Low if golden check on destination count/ids.

---

## PR B10 — Normalize trip storage (epic)

### Motivation

Whole-document `trips.data` jsonb → last-write-wins races on concurrent expense edits. Feed already uses separate rows (`trip_feed_posts`).

### Sub-PRs

| Sub | Work |
|---|---|
| B10a | Design: tables for expenses, settlement_records, expense_comments; trips row for metadata |
| B10b | Dual-write (blob + tables) |
| B10c | Backfill migration from jsonb |
| B10d | Read tables-only; retire blob fields gradually |

### Must preserve

- Membership RLS (`is_trip_member`)
- Offline cache strategy (will need rewrite)
- Decode compatibility during transition
- Schema file + live DB sync (hard rule 7)

### Risk

Very high. Only when concurrent multi-editor pain is real.

---

## Product PR summary

| PR | User-visible win | Effort | Depends on |
|---|---|---|---|
| B1 | No fake settings | XS | — |
| B2 | Home currency choice | S | FX rates exist |
| B3 | Share “you owe $X” | S | B1 optional |
| B4 | Real alerts | L | schema + Apple setup |
| B5 | Export for group chat | M | better after A4 |
| B6 | Find expenses fast | S | better after A4 |
| B7 | Apple login | M | developer team |
| B8 | Plan → spend | M | model field care |
| B9 | Content without app release | S–M | A5 nice-to-have |
| B10 | Safe multi-editor | XL | pain-driven |

### Track B “v1 complete” when

- [ ] Settings has no dead ends (B1)
- [ ] Home currency works (B2)
- [ ] Settle can share a payment ask (B3)
- [ ] At least one of: notifications (B4), export (B5), search (B6)

---

# How tracks fit together

```
A0 tests ──────────────────────────────────────────────┐
     │                                                 │
     ├─ A1 models/engine ── A2 store/repo ── A3 UI kit ── A4 screens
     │         │
     │         └─ B1 settings honesty (early OK)
     │         └─ B2 display currency (touches TripStore — not parallel with A2)
     │         └─ B3 settlement share
     │         └─ B5 export, B6 search (after A4 preferred)
     │
     └─ A5 ContentView split ── B9 explore JSON
                                B4 notifications (long pole)
                                B7 Apple Sign-In (when team ready)
                                B8 itinerary bridge
                                B10 only if concurrent-edit bugs appear
```

### Parallelism rules (avoid merge pain)

- Do **not** run A4 and B5/B6 on `TripDetailView` simultaneously
- Do **not** run A2 and B2 on `TripStore` without a single owner
- Product PRs that only touch Settings / SettleView / new files are safest during early A-series

---

# Recommended first sequence (if only doing a few PRs)

1. **A0** — real unit tests for `SplitEngine` + `Trip` balances  
2. **A1** — extract models/engine  
3. **B1 + B3** — settings honesty + settlement share (quick product trust)  
4. **A2 → A4** — finish trip file split  
5. **B2 / B5 / B6** — next product value  
6. **A5** then **B9** — explore content maintainability  

---

# Feature inventory (context for implementers)

What the app already offers (do not re-build):

- Trips, expenses, per-member budgets, soft-delete expenses, per-user archive
- Split methods: equal all/selected, single payer, percentage, amount; item-level splits; tax/tip
- Settle-up with payment method labels + pending/confirmed/rejected records
- Receipt scan: Cloud Vision + Gemini Edge Functions, Vision offline fallback, document camera
- Multi-currency trips + FX rates + USD home aggregation
- Auth (email), profile, invites (email + link), membership RLS
- Trip feed (posts/photos/comments/reactions) as separate table rows
- Explore curated destinations, MapKit map, itinerary planner + AI suggest Edge Function
- Offline trip cache, path-keyed image cache, themes, en/es/zh-Hans localization, onboarding

Stub / incomplete:

- Settings **Payments** and **Notifications** (no real behavior)
- Sign in with Apple disabled (`appleSignInEnabled = false`)
- Home always aggregates in USD
- Dead SPM package

---

# Agent execution notes

When implementing a PR from this doc:

1. State which PR id you are implementing (`A0`, `A1`, `B2`, …).
2. Stay within that PR’s scope (surgical).
3. Respect hard rules 1–8.
4. Prefer build verification over simulator unless asked.
5. Do not add third-party packages or Supabase SDK.
6. If schema changes: edit `supabase_schema.sql` and note live DB apply step.
7. Update this file’s checkboxes only if the human wants progress tracked here.

---

*Generated as a planning artifact for TripSplit. No code was required to apply this document; implementation happens PR-by-PR.*

# TripSplit — File Split Plan + Product PR Roadmap + Balance Card UX + AI Rate Limits

Read-only planning document for implementing structural refactors, product improvements,
Home balance/currency-converter card UX, and AI rate-limit hardening. Feed this file to
another model/agent as the source of truth for execution.

**Tracks**

| Track | Topic |
|---|---|
| **A** | File split / structure (PRs A0–A6) |
| **B** | Product features (PRs B1–B10) |
| **C** | Balance / currency converter card UX (readability + minimalism) |
| **D** | AI rate limiting (fair buckets, 429 UX, cost controls) |

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

# Track C — Balance / currency converter card UX

Read-only UX plan for the Home **budget summary** face and the **currency converter** face
(`BalanceCard` + `CurrencyConverterCard` in `HomeScreen.swift`). Goal: **better readability**
and a **more minimalist** presentation without losing data.

**Related code (as of planning):**

- `HomeScreen.swift` — `BalanceCard`, `CurrencyConverterCard`, `SyncFailureBanner`
- `TripStore.homeTotals(in:)` — aggregated budget / spent / youOwe / owedToYou
- `@AppStorage("displayCurrency")` — home display currency (also Settings)
- `money(_:_:)` formatting helper

**Suggested PR ids when implementing:** `C1` (quick declutter), `C2` (converter interaction), `C3` (polish).

---

## C.0 — What exists today

### Budget face (front)

1. Header: title (“Budget” / “Spending”) + info button + status chip + flip-to-converter control  
2. Hero amount + label (“Remaining” / “Over budget” / “Total spent”) · trip count  
3. Progress bar + Spent / % / Budget labels  
4. Two tinted tiles: “You owe” / “People owe”  
5. Optional rates warning when some trip currencies cannot convert  

### Converter face (back)

1. Title + loading + back control  
2. Amount field + from/to currency menus  
3. Converted result + rate line  
4. Presented via opacity flip on the same card shell  

### Already good

- One clear hero answering “how am I doing?”
- Status color system (healthy / near / over) aligned with trip cards  
- Honest empty state when no budget is set  
- Display currency via `@AppStorage("displayCurrency")`  
- Converter can seed `to` from home currency  

### Where readability and minimalism suffer

- Too many simultaneous status signals (chip + hero label + red number + bar %)  
- Dense footer tiles compete with the hero  
- Converter is a different job but shares the same “card identity”  
- Glass + chips + tinted tiles + icons stack into visual noise  
- Flip hides the budget; faces can feel unequal in height  
- Info popover copy may still say “USD” while the card uses `displayCurrency` (trust/readability bug)  

---

## C.1 — Design principles

1. **One primary number** — everything else is supporting.  
2. **Status once** — color *or* chip *or* label; not all three at full weight.  
3. **Separate “health” from “settlement”** — budget headroom vs. who owes whom.  
4. **Converter is a tool**, not a second homepage face.  
5. **Quiet chrome** — less fill, fewer borders; type hierarchy and spacing carry the UI.  

---

## C.2 — Budget face recommendations

### Collapse redundant status

Today “over budget” can appear as: status capsule, hero label, red hero number, red bar + “%”.

| State | Minimal pattern |
|---|---|
| On track | No chip. Neutral hero. Quiet bar. |
| Near limit | Small amber text under hero *or* thin amber bar only |
| Over budget | Red hero **or** single chip—not both at full strength |

Example hierarchy:

- **Hero:** `$240 remaining` / `$80 over`  
- **Secondary line:** `Spent $1,260 of $1,500 · 84%` (one line, not three anchors under the bar)  

### Make the hero self-explanatory

Prefer:

```
$1,240
remaining · USD
across 3 trips
```

or compact:

```
$1,240 remaining
3 trips · USD
```

Always show **currency code** (or symbol + code) next to the hero so multi-trip aggregates don’t force users to remember Settings.

### Slim the progress region

Options (pick one):

- **A (most minimal):** single line under the bar: `Spent $X of $Y · 84%` — drop separate budget column.  
- **B:** keep Spent / Budget ends; move `%` into the hero secondary line only.  
- **C:** thinner bar (6–7pt); show percent only when near/over.  

Without a budget: keep “No budget set” as one line under the hero; avoid a full-width “neutral full strip” that can look like 100% used.

### Soften the owe tiles (largest visual clutter)

The two tinted tiles with icon circles fight the glass card and the hero.

**Alternatives (preferred order):**

1. **Plain text row** — `You owe  $42    ·    Owed to you  $110` (color only on amounts).  
2. **Single segmented strip** — one quiet surface, two columns, hairline divider, no icon circles.  
3. **Progressive disclosure** — one-line net `Net +$68`; tap to expand two-way breakdown.  

Rename **“People owe” → “Owed to you”** (clearer, matches finance apps).

### Header chrome

- Title: `.headline` or `.subheadline.weight(.semibold)` so the **number** is the only large type.  
- Info: smaller control, or move explanation under the secondary line / long-press.  
- Status chip: only when near/over; hide when on track.  
- Flip control: prefer text “Convert” (or lighter symbol) over heavy glass circle if the card is already glassy.  

### Fix copy drift (trust)

Budget info popover must not hard-code “converted to USD” if the card uses `displayCurrency`. Say “home currency” and/or show the actual code.

Keep the rates warning, but as one quiet caption when the card is dense.

### Number formatting for scanability

- Prefer grouping + sensible decimals (`$1,234` vs `$1,234.00` when whole; keep cents when non-zero).  
- Avoid aggressive `minimumScaleFactor(0.6)` as the main strategy—prefer slightly smaller base font or compact notation for huge totals (`$12.4k`).  
- Align amounts to a consistent baseline in pairs (spent vs budget, owe vs owed).  

---

## C.3 — Converter face recommendations

### Prefer not flipping the whole card

| Pattern | UX |
|---|---|
| **Sheet / half-sheet (recommended)** | Tap “Convert” → medium detent tool; budget stays visible |
| **Inline expand** | Card grows to show converter under budget (accordion) |
| **Keep flip** | Match min height; clear state change (rotation or labeled modes) |

For minimal + readable: **half-sheet utility**. Budget card stays a pure summary.

### If converter stays in-card

Target structure:

```
[ ← Budget ]                    (or Done)

  100          USD  ⇄  EUR
  ─────────────────────────
  92.40 EUR
  1 USD = 0.9240 EUR
```

Specifics:

- Drop large “Currency Converter” title + filled icon; short nav label only.  
- Stack **From** above **To** (vertical is easier than a cramped HStack).  
- Make the **result** the hero (same language as budget hero).  
- Tappable ⇄ swaps from/to (and amount if useful).  
- Decimal pad: toolbar “Done” so the keyboard doesn’t trap the user under the dock.  
- One caption for freshness/offline (“Rates · 12m ago”), not only error.  

### Tie converter to home currency

- Default **to** = `displayCurrency` (already done).  
- Default **from** = most common trip currency among `myTrips`, or last-used pair in `@AppStorage`.  
- Optional: “Use as home currency” when `to` differs from Settings.  

---

## C.4 — Target hierarchy (minimal budget card)

```
┌─────────────────────────────────────┐
│  Overview                    Convert │  ← quiet header
│                                      │
│  $1,240                              │  ← only large type
│  remaining · USD                     │
│  3 trips · On track                  │  ← secondary; status as text when needed
│                                      │
│  ▓▓▓▓▓▓▓▓▓▓▓░░░░░  84%              │  ← thin bar
│  Spent $1,260 of $1,500              │  ← one line
│                                      │
│  You owe $42  ·  Owed to you $110    │  ← no tiles
│                                      │
│  Some trips need rate refresh        │  ← only if needed
└─────────────────────────────────────┘
```

**Visual weight order:** hero → secondary → bar → settlements → chrome.

Rough density cut vs today: **~30–40% less chrome**, same data.

---

## C.5 — Progressive disclosure (optional)

| Level | Content |
|---|---|
| **Default** | Hero remaining/spent + one-line spent/budget + thin bar |
| **Secondary** | Net settlement or two-way owe line |
| **Tertiary** | Info / “How this works”; full converter in sheet |
| **Empty** | No budget: hero = total spent; text CTA “Set a budget in a trip” |

Optional: tap hero or “Details” → lightweight per-trip breakdown sheet (multi-currency trust without stuffing the card).

---

## C.6 — Interaction & accessibility

- **Discoverability:** “Convert” text beats a lone swap icon for first-time users.  
- **Hit targets:** keep ≥44pt; don’t *visually* expand chrome.  
- **VoiceOver:** one summary, e.g. “Remaining 1,240 US dollars. Spent 84 percent of budget. You owe 42. Owed to you 110.”  
- **Dynamic Type:** hero scales; avoid forcing all bar labels onto one line at large sizes—stack when needed.  
- **Color alone:** near/over must also have text.  
- **Reduce Motion:** if flip remains, keep crossfade/opacity (already present).  

---

## C.7 — Consistency with the rest of Home

| Surface | Role |
|---|---|
| Balance card | Aggregate health, one glance |
| Trip row | Per-trip budget UX (spent/remaining boxes OK here) |
| Converter | Utility (sheet preferred) |

The home card should feel like a **summary**; trip rows stay detailed. Don’t mirror trip-row density on the balance card.

---

## C.8 — Prioritized implementation list

### Quick wins — PR **C1** (high readability, low risk)

1. Show **currency code** on the hero secondary line.  
2. Fix info popover copy for **home currency**, not hard-coded USD.  
3. Hide **status chip** when on track.  
4. Replace owe **tiles** with a quiet two-value line.  
5. Merge bar footnotes into **one** “Spent X of Y · Z%” line.  
6. Demote header title size so hero dominates.  
7. Rename “People owe” → “Owed to you”.  
8. Localize any new/changed strings via `Localizable.xcstrings`; use `LocalizedStringKey` for labels (hard rule 8).  

**Files likely:** `HomeScreen.swift` (`BalanceCard` only).  
**Schema:** none.  
**Risk:** low (UI-only).

### Medium — PR **C2** (structure)

9. Move converter to a **half-sheet** (or expand-in-place); keep budget always visible.  
10. Vertical from → to layout + swap control + keyboard Done.  
11. Persist last currency pair; smarter defaults from trips.  

**Files likely:** `HomeScreen.swift` (`BalanceCard`, `CurrencyConverterCard`).  
**Risk:** low–medium (presentation / keyboard).

### Polish — PR **C3**

12. Compact large amounts; less aggressive scale-down.  
13. Optional **net** settlement line with expand.  
14. Per-trip breakdown sheet for multi-currency trust.  
15. Single glass treatment (card only)—lighter header buttons.  

**Risk:** low; do after C1/C2 settle.

---

## C.9 — What not to do

- Don’t add charts, rings, or more badges on this card.  
- Don’t put Settings “home currency” *and* a third currency control on the face.  
- Don’t gradient-fill the whole card for status—tint sparingly (hero + bar is enough).  
- Don’t keep full flip *and* add more content on both faces (height thrash on Home).  
- Don’t invent new split math; card only displays `homeTotals` / converter rates.  

---

## C.10 — Design direction (one sentence)

**A quieter summary strip:** one hero number with currency, one progress sentence, one settlement line, and Convert as a lightweight tool—not a second full face fighting the budget story.

---

## C.11 — Acceptance criteria

- [ ] At a glance (&lt;2s): user knows remaining/over and currency.  
- [ ] On-track state has **no** redundant red/amber chrome.  
- [ ] Over/near still clear under grayscale (text present).  
- [ ] Card height more stable when opening converter (especially after C2).  
- [ ] Info text matches `displayCurrency`.  
- [ ] Visual density clearly lower than today without dropping spent/budget/settlement data.  
- [ ] Clean app build; localization keys updated.  

### Track C “v1 complete” when

- [ ] C1 declutter shipped  
- [ ] C2 converter interaction improved (sheet or equivalent)  
- [ ] Acceptance criteria above checked  

---

# Track D — AI rate limiting (harden + fair budgets)

Planning for improvements to the existing **server-side AI rate limiter**. Do **not** rebuild
rate limiting from scratch — extend what ships today. This track is independent of A/B/C
file splits and product features (except it touches the same Edge Functions / receipt +
itinerary clients).

**Goal:** fair per-feature budgets, honest quota charging, clearer 429 UX, tighter RPC surface,
and optional cost caps — without client-only “security” or third-party deps.

**Hard rules that apply:** 6 (no API keys in app), 7 (schema file + live DB in sync), 8
(localized UI strings).

---

## D.0 — What exists today (do not re-implement)

### Server

| Piece | Location | Behavior |
|---|---|---|
| Event table | `public.receipt_scan_events` in `supabase_schema.sql` | `(id, user_id, created_at)`; RLS on, **no policies** (clients cannot read/write directly) |
| RPC | `public.record_receipt_scan(p_limit int, p_window_seconds int)` | `SECURITY DEFINER`; requires `auth.uid()`; bounds-checks args; advisory lock per user; counts events in window; inserts one row; returns `true`/`false` |
| Grant | `authenticated` can `EXECUTE` the RPC | Edge Functions call it with the user JWT |

### Edge Functions (each auth-checks user, then rate-limits, then calls paid API)

| Function | Limit | Window | Upstream |
|---|---:|---:|---|
| `supabase/functions/ocr-receipt` | 20 | 60s | Google Cloud Vision |
| `supabase/functions/parse-receipt` | 20 | 60s | Gemini |
| `supabase/functions/suggest-itinerary` | 10 | 300s | Gemini |

All three write into the **same** `receipt_scan_events` table. The RPC counts *all* of a
user’s recent rows in the caller-supplied window — there is no per-feature dimension.

Quota is recorded **before** the paid API call. Failures (5xx, misconfig 503, bad model
JSON, upstream timeout) still consume a slot. On reject: HTTP **429** +
`"Rate limit exceeded. Try again shortly."` (no `Retry-After`, no structured body).

### Client

| Path | File | 429 handling |
|---|---|---|
| OCR + parse | `ReceiptService.swift` | `ReceiptScanError.rateLimited`; online path fails and pipeline falls back toward on-device Vision (often without explaining AI was limited) |
| Itinerary suggest | `ItineraryFeature.swift` | User-facing: “You've generated a few plans in a row — try again in a couple of minutes.” |

### Related (not request-rate limiting)

Feed RPC caps (e.g. max 500 comments / 50 reaction keys, “Too many feed interactions”) are
**payload size** guards. Do not conflate them with Track D. App-wide rate limits for trip
CRUD / storage / auth are **out of scope** unless abuse appears later.

### What’s already solid (keep)

- Server-side enforcement (not client-only)
- Atomic check via advisory lock + insert
- Auth required; events table not client-readable
- Bounds on `p_limit` / `p_window_seconds`
- Client already maps HTTP 429 on receipt + itinerary paths

---

## D.1 — Problems to fix (priority order)

1. **Shared AI bucket across features** — OCR, parse, and itinerary share one event log.
   Heavy receipt scanning can starve itinerary (and vice versa in the overlapping window).
   Naming (`receipt_scan_*`) no longer matches itinerary use.
2. **Double-count per receipt scan** — online pipeline typically calls **ocr-receipt then
   parse-receipt** → **2 events per user action**. Effective full-scan budget is ~half of
   the advertised 20/min unless limits are retuned or counted as one unit.
3. **Pre-call charging** — infra/upstream failures burn quota unfairly.
4. **Opaque 429** — no `Retry-After`, no `limit` / `remaining` / `window` / `feature` for
   clients to cool down intelligently.
5. **RPC callable by any authenticated client** — cannot steal free AI (Edge Functions still
   gate secrets), but can **self-DoS** / pollute the shared window; feature args would not
   be trustworthy if clients can write arbitrary kinds.
6. **Weak UX** — receipt rate limit often silent (fallback); itinerary message is better but
   still guessy on wait time.
7. **Burst-only caps** — per-window limits do not bound all-day spend on Gemini/Vision.
8. **Little observability** — hard to retune 20/60 and 10/300 without 429/success metrics.

---

## D.2 — Design principles

- **Server remains authoritative.** Client guards are UX only (disable button, show toast).
- **Per-feature fairness first**, optional global/daily cost ceiling second.
- **Charge for real AI work**, not for our outages (with optional still-count for obvious abuse).
- **Structured 429s** so clients never invent wait times.
- **Surgical PRs:** schema + Edge Functions + minimal client mapping; no MVVM, no new packages.
- **Idempotent DDL** in `supabase_schema.sql` + apply to linked project (hard rule 7).
- **Do not** add app-wide throttles for non-AI endpoints in this track.
- **Do not** put API keys or rate-limit bypass secrets in the app bundle.

---

## D.3 — Target design (conceptual)

### Feature-scoped events

Prefer one of:

**Option A (recommended):** add `kind text not null` (e.g. `ocr` | `parse` | `itinerary`) to
the events table (or rename table to `ai_usage_events` in a later cleanup). Count only rows
matching the kind for that function’s limit.

**Option B:** separate tables/RPCs per feature — clearer isolation, more schema surface.

**Option C (temporary):** keep one table but pass `p_kind` into the RPC and filter counts —
smallest schema change if renaming is deferred.

Also decide **receipt pipeline units**:

- **Unit = full scan** (one charge for OCR+parse together), *or*
- **Unit = function call** but retune numbers so 20/min means ~10 full scans is intentional
  and documented in function comments / README.

### RPC shape (illustrative)

```text
record_ai_usage(
  p_kind text,              -- 'ocr' | 'parse' | 'itinerary' (or single 'receipt' if unified)
  p_limit int,
  p_window_seconds int
) returns boolean
-- or returns jsonb { allowed, remaining, limit, window_seconds, retry_after_seconds }
```

Prefer **service-role-only execute** from Edge Functions after D3; until then keep
bounds-checks tight.

### 429 response body (illustrative)

```json
{
  "error": "Rate limit exceeded",
  "feature": "itinerary",
  "limit": 10,
  "windowSeconds": 300,
  "retryAfterSeconds": 42
}
```

Plus HTTP header: `Retry-After: 42`.

### When to insert an event

| Outcome | Count against quota? |
|---|---|
| Allowed + paid API success | Yes |
| Allowed + paid API 5xx / timeout / 503 misconfig | Prefer **No** (or separate “soft” counter) |
| Rejected by rate limit | No insert (already at cap) |
| 401/413/invalid input before AI | No |
| Optional: repeated abuse of huge payloads | Yes / separate abuse table (later) |

Implementation note: if charging post-success, use a short-lived “reservation” or accept a
small race; advisory lock already serializes per user — document the chosen approach in the
PR.

---

## Suggested PR breakdown

### PR D1 — Separate feature buckets (highest impact)

**Problem:** one shared event stream makes limits unfair and hard to reason about.

**Scope:**

- Schema: add `kind` (or equivalent) to usage events; backfill existing rows as
  `'receipt'` / `'unknown'` if needed; update index to `(user_id, kind, created_at desc)`.
- Replace or extend `record_receipt_scan` → kind-aware RPC (keep old name as wrapper only if
  zero-downtime deploy requires it; prefer clean rename + update all Edge Functions together).
- Update `ocr-receipt`, `parse-receipt`, `suggest-itinerary` to pass their kind and
  **feature-local** limits/windows.
- Document limits in each function header comment.
- Update `supabase_schema.sql` **and** apply DDL to live DB.
- Update `supabase/functions/parse-receipt/README.md` (and any OCR/itinerary notes).

**Suggested starting limits (retune after metrics):**

| Kind | Limit | Window | Notes |
|---|---:|---:|---|
| `ocr` | 20 | 60s | Cheaper; can be looser than parse |
| `parse` | 15 | 60s | Gemini cost |
| `itinerary` | 10 | 300s | Highest cost / longest work |

**Out of scope for D1:** client UX copy, daily caps, RPC revoke.

**Verify:** build not strictly required if SQL + Deno only, but if client error parsing changes,
run `xcodebuild`. Manually reason concurrent same-user requests still cannot exceed limit
(advisory lock preserved).

**Risk:** Medium — live Edge Functions must deploy in lockstep with RPC signature.

---

### PR D2 — Receipt pipeline unit semantics

**Problem:** one scan ≈ two events.

**Options (pick one in the PR description):**

1. **Single charge at parse** (OCR free / not counted) — simple; OCR can still be abused alone.
2. **Single charge at OCR** when parse always follows — weak if offline-only OCR path differs.
3. **New kind `receipt_scan`** charged once from a thin orchestrator — best long-term, more
   work if client still calls two functions.
4. **Keep dual charge** but set limits so “~10 full scans/min” is explicit in docs/constants.

**Recommendation:** (4) as quick doc+constant fix *or* (1) if OCR abuse is low risk; avoid
silent double-counting without comment.

**Files:** Edge Function constants + README; optional client comment in `ReceiptScanner`.

**Risk:** Low–Medium depending on option.

---

### PR D3 — Charge on success + structured 429

**Scope:**

- Move or split “record usage” so infra failures do not consume the primary budget
  (document race/reservation approach).
- On limit hit: return JSON fields above + `Retry-After` header.
- On success path only (or reservation→commit): insert event.
- Client:
  - `ReceiptService.swift` — parse `retryAfterSeconds` if present; keep
    `ReceiptScanError.rateLimited` (optional associated value for retry).
  - `ItineraryFeature.swift` — use server retry seconds in the user message when available;
    keep friendly fallback string.
- Localization: any new user-visible strings via `Localizable.xcstrings` / hard rule 8.

**Out of scope:** daily caps, metrics dashboards.

**Risk:** Medium — billing/abuse tradeoff if post-success only; test failure paths carefully.

---

### PR D4 — Lock down RPC + client UX polish

**Scope:**

- Revoke `EXECUTE` on the usage RPC from `authenticated` / `anon` if Edge Functions can call
  with service role (or a dedicated restricted path). Confirm deploy model still works with
  `verify_jwt` + user auth for the *function*, service role only for the *RPC*.
- Receipt UX: when cloud path hits 429 and falls back to on-device, show a one-shot toast /
  banner: e.g. “Using offline scan — AI limit reached. Try again in a minute.”
  (`LocalizedStringKey`, not `Text(String)`).
- Itinerary UX: disable suggest button for `retryAfterSeconds` after 429; avoid double-tap
  duplicate in-flight requests.
- Optional: show remaining quota only if API returns it (do not invent client-side counters
  as security).

**Risk:** Medium for RPC revoke (misconfigured service role = all AI 500s). Low for UX-only.

---

### PR D5 — Daily/monthly cost ceiling (optional, when usage grows)

**Problem:** window limits stop bursts, not all-day maxing every window.

**Scope:**

- Second-tier counter (e.g. per-day per user per kind, or global AI actions/day).
- Clear user message when daily cap hit (distinct from short window 429).
- Optional product hook later (upgrade / wait until reset) — not required for MVP.

**Risk:** Product policy decision; implement only when Gemini/Vision spend warrants it.

---

### PR D6 — Observability (ops)

**Scope (server logs / Supabase metrics — no heavy APM product required):**

- Log/count: 429 vs 200 by function and kind
- Success vs pre-call reject vs post-call failure
- Optional: p95 events/user/window

Use data to retune D1 limits. No user-facing UI required.

**Risk:** Low.

---

## D.4 — Explicit non-goals

- App-wide rate limiting for trip CRUD, feed reads, storage uploads, auth, FX.
- Treating feed “Too many interactions” as request-rate control (payload caps only).
- Client-only rate limit as the real enforcement layer.
- Third-party rate-limit libraries or Supabase Swift SDK.
- Perfect sliding-window fairness algorithms (fixed windows are fine at current scale).
- Complex token-bucket in Swift.

---

## Track D PR summary

| PR | Win | Effort | Depends on |
|---|---|---|---|
| **D1** | Fair per-feature AI budgets | M | — |
| **D2** | Honest receipt-scan accounting | S | D1 nice-to-have |
| **D3** | Don’t burn quota on outages; structured 429 | M | D1 optional |
| **D4** | Harden RPC + visible cooldown UX | S–M | D3 for Retry-After |
| **D5** | Daily spend ceiling | M | D1; pain-driven |
| **D6** | Metrics to retune limits | S | D1 |

### Recommended Track D order

1. **D1** — separate buckets (fixes the structural bug)  
2. **D2** — pipeline unit semantics (with or right after D1)  
3. **D3** — success charging + structured 429  
4. **D4** — RPC lockdown + UX  
5. **D6** — metrics when convenient  
6. **D5** — daily cap only if cost becomes real  

### Track D “v1 complete” when

- [ ] Receipt OCR/parse and itinerary no longer unfairly starve each other (D1)  
- [ ] Receipt double-count is intentional and documented *or* fixed (D2)  
- [ ] 429 includes retry guidance; infra failures don’t silently eat the main budget (D3)  
- [ ] Users see when receipt AI was limited; itinerary cools down after 429 (D4)  
- [ ] Schema file and live DB match; Edge Functions deployed in lockstep  

---

## D.5 — Files / surfaces an implementer will touch

| Area | Paths |
|---|---|
| Schema | `supabase_schema.sql` (`receipt_scan_events`, `record_receipt_scan`); new migration under `supabase/migrations/` if that’s the project habit |
| Edge Functions | `supabase/functions/ocr-receipt/index.ts`, `parse-receipt/index.ts`, `suggest-itinerary/index.ts`, `parse-receipt/README.md` |
| Client receipt | `Tripsplit/ReceiptService.swift` (`ReceiptScanError`, OCR/parse HTTP switches, fallback messaging call sites) |
| Client itinerary | `Tripsplit/ItineraryFeature.swift` (suggest HTTP 429 handling, button disable) |
| Strings | `Tripsplit/Localizable.xcstrings` for any new user-visible copy |

---

## D.6 — Acceptance criteria (implementer checklist)

- [ ] Per-feature (or equivalent) limits: burning receipt quota does not block itinerary solely
      because of shared undifferentiated rows (and vice versa within reason).  
- [ ] Concurrent requests for the same user still cannot exceed the limit (lock or equivalent).  
- [ ] 429 responses are parseable; itinerary message uses server retry when present.  
- [ ] Receipt online rate limit either surfaces a short explanation or is explicitly accepted
      as silent fallback in the PR notes.  
- [ ] No API keys added to the app; no public bucket / RLS regressions.  
- [ ] `supabase_schema.sql` updated; live apply step documented in the PR.  
- [ ] Clean `xcodebuild` if any Swift changed.  
- [ ] Edge Functions redeployed: `parse-receipt`, `ocr-receipt`, `suggest-itinerary` as needed.

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
     │         └─ C1 balance card declutter (HomeScreen only — parallel-safe)
     │         └─ C2 converter sheet (after C1)
     │         └─ D1–D4 AI rate limits (Edge Functions + schema; mostly parallel-safe)
     │
     └─ A5 ContentView split ── B9 explore JSON
                                B4 notifications (long pole)
                                B7 Apple Sign-In (when team ready)
                                B8 itinerary bridge
                                B10 only if concurrent-edit bugs appear
                                C3 balance card polish
                                D5 daily AI cap (cost-driven)
                                D6 AI usage metrics
```

### Parallelism rules (avoid merge pain)

- Do **not** run A4 and B5/B6 on `TripDetailView` simultaneously  
- Do **not** run A2 and B2 on `TripStore` without a single owner  
- Product PRs that only touch Settings / SettleView / new files are safest during early A-series  
- **C1/C2** touch `HomeScreen.swift` only (mostly)—safe in parallel with A1–A4 *unless* someone is also editing Home heavily; avoid parallel C* with large Home refactors  
- C1 is independent of B2 if `displayCurrency` already exists; still fix popover copy to match whatever currency the card shows  
- **D1–D3** are mostly backend (SQL + Edge Functions)—safe in parallel with A/B/C **unless** another PR is also editing `ReceiptService.swift` / `ItineraryFeature.swift` or the same Edge Functions  
- **D4** client UX may touch the same Swift files as receipt/itinerary product work (B8)—serialize those  
- Deploy D1 RPC signature changes in lockstep with all three AI Edge Functions  

---

# Recommended first sequence (if only doing a few PRs)

1. **A0** — real unit tests for `SplitEngine` + `Trip` balances  
2. **A1** — extract models/engine  
3. **B1 + B3** — settings honesty + settlement share (quick product trust)  
4. **C1** — balance card declutter (fast Home UX win; low risk)  
5. **A2 → A4** — finish trip file split  
6. **B2 / B5 / B6** — next product value  
7. **C2** — converter as sheet/tool  
8. **A5** then **B9** — explore content maintainability  
9. **D1 → D3 → D4** — AI rate-limit fairness + 429 UX (can interleave earlier if AI cost/abuse is urgent; independent of file split)

---

# Feature inventory (context for implementers)

What the app already offers (do not re-build):

- Trips, expenses, per-member budgets, soft-delete expenses, per-user archive
- Split methods: equal all/selected, single payer, percentage, amount; item-level splits; tax/tip
- Settle-up with payment method labels + pending/confirmed/rejected records
- Receipt scan: Cloud Vision + Gemini Edge Functions, Vision offline fallback, document camera
- Multi-currency trips + FX rates + home aggregation via `displayCurrency` / `homeTotals(in:)`
- Home `BalanceCard` (budget face + flip converter) — UX polish tracked in **Track C**
- Auth (email), profile, invites (email + link), membership RLS
- Trip feed (posts/photos/comments/reactions) as separate table rows
- Explore curated destinations, MapKit map, itinerary planner + AI suggest Edge Function
- Offline trip cache, path-keyed image cache, themes, en/es/zh-Hans localization, onboarding
- **AI rate limiting (MVP):** per-user `record_receipt_scan` + `receipt_scan_events`; used by
  `ocr-receipt` (20/60s), `parse-receipt` (20/60s), `suggest-itinerary` (10/300s); shared
  event table; client maps 429 — harden in **Track D**

Stub / incomplete / polish backlog:

- Settings **Payments** and **Notifications** (no real behavior)
- Sign in with Apple disabled (`appleSignInEnabled = false`)
- Balance card density / converter flip UX (**Track C**)
- AI rate-limit fairness / structured 429 / daily cost caps (**Track D**)
- Dead SPM package

---

# Agent execution notes

When implementing a PR from this doc:

1. State which PR id you are implementing (`A0`, `A1`, `B2`, `C1`, `D1`, …).  
2. Stay within that PR’s scope (surgical).  
3. Respect hard rules 1–8.  
4. Prefer build verification over simulator unless asked.  
5. Do not add third-party packages or Supabase SDK.  
6. If schema changes: edit `supabase_schema.sql` and note live DB apply step.  
7. Update this file’s checkboxes only if the human wants progress tracked here.  
8. For **Track C**: UI-only unless C2 needs presentation plumbing; do not change `SplitEngine` or settlement math; keep localization correct.  
9. For **Track D**: keep enforcement server-side; deploy Edge Functions in lockstep with RPC/schema changes; never put AI keys or bypass secrets in the app; localize any new rate-limit copy (hard rule 8).  

---

*Planning artifact for TripSplit. Implementation happens PR-by-PR (Tracks A, B, C, D).*

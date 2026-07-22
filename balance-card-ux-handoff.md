# Balance Card UX — Implementation Handoff

Hand this file to another model to implement. Scope is **UI/UX only** for the home-screen budget card (`BalanceCard` in `Tripsplit/HomeScreen.swift`). Do not expand into unrelated Home features.

---

## Product decisions (locked)

| Decision | Choice |
|---|---|
| Hero number | Always **budget remaining** (or over-by / total spent when no budget). Not net settle-up. |
| Aggregation | Keep current model: personal budgets only, converted to `displayCurrency`. |
| Empty budget | Guided CTA to set a budget, not a dead caption. |
| Settle-up | Secondary band, not equal 2×2 peers of Spent/Budget. |
| Drill-down | Light: tap hero/status/bar → **Budget by trip** sheet. |
| Convert | Demote out of primary header (menu or icon); keep existing converter sheet. |

---

## Current code map

| What | Where |
|---|---|
| Card UI | `Tripsplit/HomeScreen.swift` — `struct BalanceCard` (~line 619) |
| Totals math | `Tripsplit/TripStore.swift` — `HomeTotals`, `homeTotals(in:)` (~line 531) |
| Per-trip visual language | `Tripsplit/HomeScreen.swift` — `struct TripRow` progress + stat boxes |
| Home currency storage | `@AppStorage("displayCurrency")` (also Settings) |
| Converter sheet | `CurrencyConverterCard` in `HomeScreen.swift` |
| Project rules | `Claude.md` — hard rules (esp. localization, main actor, SplitEngine) |

### Current card structure

1. Header: "Overview" + info popover + **Convert**
2. Hero: remaining / over / total spent + currency + trip count
3. Status capsule + `% of budget`
4. Flat progress capsule (budget only)
5. 2×2 grid: SPENT · BUDGET · YOU OWE · OWED TO YOU
6. Edge captions: no budget / FX unavailable

### Data available today (`HomeTotals`)

```swift
var budget, spent, youOwe, owedToYou: Double
var unavailableCurrencies: Set<String>
var available: Double { budget - spent }
```

You may need **extra derived fields** for partial-budget honesty (e.g. count of trips with personal budget vs total). Compute in `homeTotals` or cheaply in the view from `store.myTrips` + `currentUser.id` — do not re-run `settlements()` more than once per trip.

---

## Target layout

```
┌─────────────────────────────────────────────┐
│ Your budget                    USD ▾   ⋯    │  currency chip + overflow menu
│                                             │
│ $580                                        │  hero
│ Remaining · 2 of 5 trips budgeted           │
│                        [ Running low ]      │  status capsule
│                                             │
│ Budget used                         72%     │
│ ████████████████░░░░░░░░░░░░                │  match TripRow gradient style
│ $1,280 of $1,600                            │  spent of budget
│                                             │
│ ┌────────────┐  ┌────────────┐              │
│ │ SPENT      │  │ BUDGET     │              │  budget tiles only
│ │ $1,280     │  │ $1,600     │              │
│ └────────────┘  └────────────┘              │
│                                             │
│ You owe $48 · Owed to you $12    [Settle]   │  only if either > 0
│                                             │
│ 3 trips have no budget          [Set one]   │  only if partial or empty
└─────────────────────────────────────────────┘
```

**Title rules**

- Has any personal budget across trips → **"Your budget"**
- No budgets → **"Spending"**

**Hero rules** (unchanged math, clearer chrome)

| State | Hero value | Hero label |
|---|---|---|
| Budget set, under | `available` | Remaining |
| Budget set, over | `spent - budget` | Over budget |
| No budget | `spent` | Total spent |

**Status copy / colors** (align healthy with trip rows)

| State | Threshold | Label | Color |
|---|---|---|---|
| Healthy | fraction < 0.8 | On track | Green (`0x16A34A` / same as `TripRow` healthy) |
| Near | ≥ 0.8 and not over | Running low | Amber `0xD97706` |
| Over | spent > budget | Over budget | Red `0xDC2626` |

Today home healthy uses `Theme.accent` (indigo); trip rows use green. **Unify on green for health.**

---

## Work items (implement in this order)

### P0 — Honesty + empty CTA + progress labels

1. **Partial-budget subtitle**
   - Replace always-on `"N trips"` with:
     - All budgeted: `"N trips"` or `"N trips budgeted"`
     - Partial: `"K of N trips budgeted"`
   - Optional secondary line when `K < N`:  
     `"\(N - K) trips have no budget and aren't in this total"`

2. **Empty / no-budget CTA**
   - Remove dead caption `"No budget set · Set one inside a trip"`.
   - Show short benefit line + button **"Set a budget"**:
     - 0 trips → open add-trip (or rely on existing empty trips section; do not duplicate heavy UI).
     - 1 trip → open that trip’s edit/budget path (same as Edit Trip budget).
     - Many trips → trip picker sheet (mirror Home quick-action trip picker pattern).
   - Microcopy OK: budgets are personal and per-trip.

3. **Progress bar parity with `TripRow`**
   - Label row: `"Budget used"` left, percent right.
   - Gradient fill like `TripRow.progressColors`.
   - Caption under bar: `"$spent of $budget"` via existing money formatting helpers.
   - When over: full-width red bar + overflow text e.g. `+$X over` next to percent or under bar.

4. **Info popover**
   - Keep; still explains conversion + only set budgets count.
   - Subtitle must not make the popover the *only* place partial coverage is stated.

### P1 — Settle band + by-trip sheet

5. **Remove YOU OWE / OWED TO YOU from the 2×2**
   - Stat grid becomes **Spent | Budget** only (one row, or two equal tiles).
   - Accessibility Dynamic Type: stack vertically as today.

6. **Settlement secondary row**
   - Show only if `youOwe > 0 || owedToYou > 0`.
   - Format: `You owe $X · Owed to you $Y` with existing value colors (red / green when non-zero).
   - Trailing **Settle** control → trip picker filtered to trips where current user has open settlement remaining (or single-trip fast path). Reuse existing settle/split entry if present; otherwise open the relevant trip detail.
   - Both zero: either hide row or one quiet `"All settled up"` line (prefer **hide** to reduce noise).

7. **Budget by trip sheet**
   - Present on tap of hero band, status capsule, or progress (use a clear hit target; don’t steal the overflow menu).
   - List each trip where `budget(for: me) > 0`:
     - Name, spent/budget, mini bar, remaining or over-by, health color.
   - Footer: count of trips with no budget.
   - Row tap → open `TripDetailView` / existing trip sheet (`selectedTrip` pattern on Home).
   - Sort suggestion: over first, then near, then healthy; or by % used descending.

### P2 — Header cleanup

8. **Demote Convert**
   - Overflow `⋯` menu items:
     - Convert currencies → existing `CurrencyConverterCard` sheet
     - How totals work → existing info content (or keep info.circle)
   - Optional: tappable `USD ▾` chip bound to `displayCurrency` (same AppStorage as Settings). Compact currency list is enough; no need for full Settings clone.

9. **FX unavailable**
   - Keep caption; add **Refresh rates** calling `await store.refreshRates()` if easy.

### P3 — Polish (optional)

10. First-load rates: light “Updating rates…” if totals incomplete.
11. VoiceOver combined summary should include status + % + partial budget counts.
12. No trips: don’t show a misleading $0 “remaining” budget card; collapse or single prompt. Coordinate with existing “No trips yet” section so Home isn’t double-empty.

---

## Localization hard rule

From `Claude.md`:

- Do **not** pass localized UI through `Text(String)`.
- Literal labels → `Text("…")` or `Text(LocalizedStringKey(...))`.
- Dynamic money/names → `Text(verbatim:)`.
- New strings should work with in-app language switch (en/es/zh-Hans) / `Localizable.xcstrings` if the project auto-extracts; follow existing patterns in `BalanceCard` / `TripRow`.

---

## What not to do

- Do **not** change split math or invent float `total / count` outside `SplitEngine`.
- Do **not** mutate `@Observable` / `TripStore` off main actor.
- Do **not** add SPM packages or Supabase SDK.
- Do **not** put app code in `Sources/Tripsplit` (dead SPM package).
- Do **not** refactor unrelated Home sections (trips list, transactions, quick actions) unless needed for navigation hooks.
- Do **not** run simulator verification unless the user asks; a clean `xcodebuild` is enough per project policy.
- Do **not** rewrite `homeTotals` aggregation semantics (still personal budget + personal spend + open settlements, FX-converted).

---

## Verification checklist

```sh
xcodebuild -project Tripsplit.xcodeproj -scheme Tripsplit \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Manual cases for the implementer / user:

| Case | Expect |
|---|---|
| No trips | No fake healthy budget; empty guidance |
| Trips, no budgets | Spending title, total spent hero, Set a budget CTA |
| Some trips budgeted | `K of N trips budgeted` visible without opening info |
| All budgeted, <80% | Green on track, remaining hero, spent of budget caption |
| ≥80% | Amber “Running low” |
| Over | Red hero + over amount + overflow on bar |
| Open debts | Settlement row visible; Settle actionable |
| No debts | Settlement row hidden |
| Tap hero/bar | Budget by trip sheet |
| Convert | Still reachable via menu/icon |
| Change home currency | Card figures re-convert (existing AppStorage) |
| Dynamic Type accessibility | Tiles stack; no truncated critical numbers |
| es / zh-Hans | Labels localize; money stays verbatim |

---

## Suggested PR shape

One PR is fine if kept surgical. If splitting:

1. **PR1 (P0):** subtitle honesty, empty CTA, progress labels/colors — pure `BalanceCard` (+ tiny helper counts).
2. **PR2 (P1):** settle band + budget-by-trip sheet + Home navigation hooks.
3. **PR3 (P2):** header menu / currency chip / refresh rates.

---

## File touch list (expected)

| File | Changes |
|---|---|
| `Tripsplit/HomeScreen.swift` | Main `BalanceCard` redesign; optional sheet types; wire pickers |
| `Tripsplit/TripStore.swift` | Only if you add helper fields on `HomeTotals` (budgeted trip count, trips with open settlements). Prefer view-side counts if simpler. |
| `Tripsplit/Localizable.xcstrings` | Only if project requires explicit string catalog entries for new copy |

No schema, no Edge Functions, no new dependencies.

---

## Success criteria

- User can tell at a glance whether they are OK on **personal budget** across trips.
- Partial budgets never look like full coverage.
- No-budget users get a **one-tap path** to set one.
- Settle-up is visible when relevant and does not dilute the budget story.
- Tapping the summary explains **which trips** drive the number.
- Build is clean; behavior matches checklist above.

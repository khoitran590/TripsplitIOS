# Explore-as-Main Tab — UI/UX Redesign Handoff

Hand this file to another agent to implement. **Do not treat this as a pure tab-order swap.** Making Explore the primary tab requires first-impression, dock, empty-state, and engagement redesign so the product reads as *inspiration → plan → spend/split*, not *ledger → maybe browse later*.

**Scope:** UI/UX product + interaction design recommendations. Implementation should stay surgical and follow `Claude.md` hard rules (localization, main-actor state, no SPM stub tests, clean `xcodebuild` only unless the user asks for simulator verify).

**Out of scope for this handoff:** backend schema changes, new third-party SDKs, rewriting Map or Feed architecture, inventing AI features that need new Edge Functions (unless already present).

---

## 1. Product decision (locked)

| Decision | Choice |
|---|---|
| Primary tab | **Explore** (currently `DockTab.rec` → `RecScreen`) |
| Secondary / utility tab | **Home / Split** (currently `DockTab.home` → `HomeScreen`) — expense ledger, balance, settle |
| App story after redesign | Discover destinations → save / build itinerary → invite friends → track & split costs |
| First open (signed-in) | Land on **Explore**, not Home |
| First open (signed-out) | Still land on Explore, but **do not gate the entire tab behind a lock wall** (see §5) |
| Map / Profile | Stay as supporting tabs; Map remains the “open place on map” escape hatch from Explore detail |

### Why this is not just reordering icons

Today the product is still **expense-first**:

| Signal | Current behavior | Problem if only dock order changes |
|---|---|---|
| Default tab | `selectedTab = .home`, `visitedTabs = [.home]` | User still opens into money UI |
| Dock order | Home · Map · Explore · Profile | Explore is third; thumb path + swipe order treat it as tertiary |
| Welcome flow | Expense / receipt / settle pages only | First-run story never mentions Explore |
| Splash tagline | “Travel together, split with ease” | Brand promise is split, not discovery |
| Post-auth redirect | `selectedTab = .home` | Sign-in ejects user out of Explore |
| Explore gate | `LockedExploreScreen` when signed out | Main tab would be a dead end for guests |
| Home density | Balance, quick actions, trips, transactions | Feels like the “real app”; Explore feels like a magazine insert |

If you only swap dock positions, Explore will still *feel* secondary: quieter chrome, explanatory copy, help-button onboarding, and a full-screen lock for guests.

---

## 2. Current code map (read before editing)

| What | Where |
|---|---|
| Dock tabs + default selection | `Tripsplit/ContentView.swift` — `DockTab`, `selectedTab`, `visitedTabs`, `screen(for:)` |
| Floating dock chrome | `Tripsplit/FloatingDock.swift` |
| Home (split) dashboard | `Tripsplit/HomeScreen.swift` — greeting, `BalanceCard`, quick actions, trips, transactions |
| Explore root | `Tripsplit/ExploreScreen.swift` — `RecScreen`, cards, filters, detail |
| Destination content | `Tripsplit/ExploreModels.swift` — `Destination.all` (~25 curated cities) |
| Itinerary rail on Explore | `Tripsplit/ItineraryFeature.swift` — `ItineraryPlannerSection` |
| App welcome + Explore onboarding | `Tripsplit/OnboardingFeature.swift` — `WelcomeView`, `ExploreOnboardingView` |
| Splash / root handoff | `Tripsplit/SplashScreen.swift` — `RootView`, `SplashScreen` |
| Map ↔ Explore bridge | `Tripsplit/MapFeature.swift` — `ExploreMapModel` |
| Explore promo in Settings | `Tripsplit/SettingsScreen.swift` — `exploreCard` |
| Project hard rules | `Claude.md` |

### Current dock

```swift
enum DockTab: String, CaseIterable {
    case home = "Home"      // house.fill  → HomeScreen
    case map = "Map"        // map.fill    → MapScreen
    case rec = "Explore"    // globe       → RecScreen (auth-gated)
    case profile = "Profile"// person.fill → ProfileScreen
}
// Default: selectedTab = .home
```

### Current Explore vertical structure (`RecScreen`)

1. Intro copy: “Where do you want to go next?”
2. Search capsule
3. Filter chips (Filters + continents)
4. Saved (or empty “keep promising trips” tip)
5. **Popular starting points** horizontal `AdventureCard` rail (featured only)
6. **Your itineraries** (`ItineraryPlannerSection`)
7. **Browse by destination** country sections with `CountryTripCard` rails
8. Detail: `DestinationDetailView` (Overview / Things to do / Restaurants + “Use as my starting plan”)

### Current Home vertical structure (`HomeScreen`)

1. Sync banner
2. `BalanceCard` (budget / settle utility)
3. Quick actions: Split · Add Expense
4. Your Trips carousel
5. Recent Transactions (grouped, expandable)

---

## 3. Tab swap — mechanical changes

Implement these as the **minimum structural** swap, then layer the UX work in §4–§8.

### 3.1 Dock order and labels

**Recommended order (left → right):**

| Position | Tab | Label | Icon | Notes |
|---|---|---|---|---|
| 1 (default) | Explore | `Explore` | Prefer `sparkles` or keep `globe` — either is fine; **sparkles** reads more “inspiration home” | Primary |
| 2 | Map | `Map` | `map.fill` | Discovery adjacency: Explore → Map |
| 3 | Home (split) | Rename to **`Trips`** or **`Split`** | Prefer `suitcase.fill` or `dollarsign.circle.fill` over `house.fill` | Utility / ledger |
| 4 | Profile | `Profile` | `person.fill` | Unchanged |

**Label guidance for the old Home tab**

- Do **not** keep calling it “Home” once Explore is primary — users will think Home is still the root.
- Preferred product name: **`Trips`** (covers trips list + expenses + settle).
- Acceptable alternate: **`Split`** if you want the money job explicit.
- Update `DockTab.rawValue`, dock accessibility labels, and any copy that says “Home tab” (e.g. invite sign-in alert in `ContentView`).

### 3.2 Default selection + mount

In `ContentView`:

- `selectedTab` default → Explore (`.rec` or renamed case).
- `visitedTabs` seed → `{ .rec }` (or new primary).
- After successful auth: land on **Explore**, not Home (unless deep-link / invite / map request requires otherwise).
- Invite-link acceptance can still open the relevant trip, but **do not** bounce every sign-in to the ledger.

### 3.3 Case naming (optional cleanup)

`DockTab.rec` is a historical name. Prefer renaming to `.explore` during the swap if the blast radius is small (`ContentView`, `MapFeature` `originTab`, etc.). Not required for UX, but reduces future confusion.

### 3.4 Sync failure banner

Today the top overlay skips Home (`selectedTab != .home`) because Home already shows an inline banner. After the swap:

- Keep inline sync UI on the **Trips/Split** screen.
- Show the global top overlay on **Explore, Map, Profile** when sync fails.
- Do **not** leave Explore without failure feedback (itinerary edits already depend on this).

---

## 4. Explore as the main tab — visual & information architecture

Goal: the first 1–2 screen-heights of Explore should feel like a **destination product** (Airbnb / Tripadvisor / Polarsteps energy), not a help article above a directory.

### 4.1 Hero first impression (above the fold)

**Replace / compress the current text-only intro.**

Current:

```
Where do you want to go next?
Find a ready-made guide, save your favorites…
[search]
[filters…]
```

**Target above-the-fold stack:**

```
┌─────────────────────────────────────────────┐
│  Good morning, Jennie            [avatar?]  │  optional personal greeting
│  Plan your next trip                        │  one bold line, not a paragraph
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  🔍  Tokyo, beaches, ramen…           │  │  search as hero control
│  └───────────────────────────────────────┘  │
│                                             │
│  [For you] [Weekend] [Foodie] [Under $2k]…  │  intent chips (not only continents)
│                                             │
│  ════════ FEATURED HERO / CAROUSEL ═══════  │  full-bleed or near full-width
│  Tokyo Adventure · 5 days · ~$500/day       │  one primary CTA visible without scroll
│  [Open guide]              ♥                │
└─────────────────────────────────────────────┘
```

**Design rules**

1. **Imagery before explanation.** Featured destinations must occupy visual weight within the first viewport. The current 290×380 `AdventureCard` rail is good *content* but sits *below* intro + search + filters + saved empty state — too late.
2. **One headline, not a tutorial.** Drop or demote “Find a ready-made guide, save your favorites…” from always-on UI. Put that in onboarding / help only.
3. **Search is a primary action**, not a quiet field under body copy. Slightly larger hit target, stronger surface, optional subtle placeholder rotation (“Tokyo”, “ramen”, “beach weekend”).
4. **Greeting optional.** If used, reuse first name like Home’s `greetingName` so signed-in users feel the tab is “theirs.” Do not steal Profile’s job — keep settings/avatar on Profile (or a small avatar that opens Profile/settings).

### 4.2 Section order for engagement (recommended)

Reorder for **return visits** and **first visits** with the same scaffold:

| Priority | Section | Audience | Notes |
|---|---|---|---|
| 1 | Search + intent chips | Everyone | Instant agency |
| 2 | **Continue** (saved + in-progress itineraries) | Returning | Highest retention; only if non-empty |
| 3 | **Featured / For you** hero | Everyone | Aspiration + browse |
| 4 | Seasonal / vibe collections | Everyone | “Beach escapes”, “Food cities”, “Long weekends” — can be static groupings over existing `Destination` tags |
| 5 | Browse by region/country | Deep browsers | Keep country rails, but not the first thing after empty saved tip |
| 6 | Build from scratch CTA | Planners | Secondary to curated start |

**Important change vs today:**  
Empty “Keep promising trips close” tip should **not** push the hero carousel down. Move empty-saved coaching into a compact one-line tip, a heart icon coachmark, or only show after the user has scrolled past featured content once.

### 4.3 “Main tab” chrome, not “secondary magazine”

Make Explore look owned by the app shell:

| Element | Recommendation |
|---|---|
| Navigation title | Large title **Explore** or personalized (“Discover”). Avoid question-mark-only help as the sole toolbar item. |
| Toolbar | Optional: heart → Saved list sheet; optional profile avatar if you want parity with old Home. Help moves behind a “How it works” row or overflow. |
| Background | Keep `AppBackground()`, but let the **first hero image bleed** (edge-to-edge carousel) so the tab feels immersive vs Home’s card stack. |
| Bottom padding | Keep dock clearance (~80–110pt). |
| Scroll physics | Prefer snap on featured hero; keep view-aligned country rails. |

### 4.4 Cards — hierarchy that says “start here”

| Card | Role | Upgrade |
|---|---|---|
| `AdventureCard` | Primary featured | Consider one **full-width** hero + smaller siblings, or taller first card. Show **primary CTA label** (“Open guide” / “Start plan”) on hero only. |
| `CountryTripCard` | Directory | Good; add subtle social proof if available later (“12 stops · 5 days”). Keep heart. |
| `DestinationRow` | Search/saved | Good density; ensure matched-stop hint stays. |
| `ItineraryTripCard` | Progress | Elevate progress: “Day 2 of 5 planned” or % of stops filled if data exists — unfinished plans drive return visits. |

### 4.5 Destination detail — convert inspiration → ownership

`DestinationDetailView` is the conversion surface. Recommendations:

1. **Sticky bottom CTA** (above dock): “Use as my starting plan” always visible while scrolling Overview / places / food. Today the CTA is mid-scroll on Overview only — easy to miss on Things to do / Restaurants.
2. **Secondary CTA:** “Open on Map” (already partially bridged via place taps) as outline button next to primary.
3. **Save** remains toolbar heart; add toast/haptic confirmation copy: “Saved to Explore”.
4. **Social bridge:** after “Create my itinerary”, surface a one-step “Invite friends” prompt (reuse existing invite flows) so Explore → multiplayer feels native.
5. **Budget framing:** show est. total / daily budget near CTA so money anxiety is answered *before* they leave for Trips tab.

### 4.6 Filters that feel like taste, not SQL

Current filters: trip length, continent, max budget. Keep them, but main-tab UX should lead with **intent**:

- Chips examples: `Weekend`, `5–7 days`, `Foodie`, `Culture`, `Beach`, `Under $1.5k`, `Asia`, `Europe`
- Map many chips onto existing fields (`days`, `tags`, `continent`, `budgetValue`) — no new backend required.
- Active filters: persistent pill bar under search with clear “Clear all”.
- When filtering, collapse long country headers into a single “Matching trips” grid (2-column photo grid feels more main-tab than many thin horizontal rails of 1–2 cards).

### 4.7 Personalization without new infrastructure (v1)

Use what you already have:

| Signal | Surface |
|---|---|
| `savedDestinationIDs` | Continue rail + “Because you saved Tokyo” similar cities (same continent/tags) |
| `itineraryTrips` | Continue planning cards at top |
| `store.myTrips` locations / names | Soft “Related to your Bali trip” if string/geo match is easy; skip if fuzzy |
| Time of day / season | Optional static seasonal collection (no ML) |

Avoid fake “recommended for you” if it’s random — label honest sections (“Popular”, “Editor picks”, “Beach escapes”).

---

## 5. Auth & first-run — critical for main-tab Explore

### 5.1 Kill full-tab lock as the signed-out experience

`LockedExploreScreen` (“Explore is for members”) is unacceptable if Explore is primary. Guests must **browse and search**.

| Action | Signed out | Signed in |
|---|---|---|
| Browse destinations | ✅ | ✅ |
| Open detail | ✅ | ✅ |
| Search / filter | ✅ | ✅ |
| Save (heart) | Prompt sign-in | ✅ |
| Use as plan / create itinerary | Prompt sign-in | ✅ |
| Sync itineraries | — | ✅ |

Pattern: soft-gate **mutations**, not **reading**. Mirror how Home already soft-gates add-trip / split via `signInRequiredAlert`.

### 5.2 Welcome flow rewrite (`WelcomeView`)

Current pages are 100% expense product. Re-sequence for Explore-primary:

1. **Discover trips worth taking** — curated guides, photo-forward.
2. **Plan days together** — itinerary / map / invite.
3. **Split costs without the spreadsheet** — receipts, fair split, settle (TripSplit differentiator).

Last-page CTA: “Start exploring” (not only “Get Started” into a ledger).

### 5.3 Explore onboarding (`ExploreOnboardingView`)

When Explore is default:

- **Do not** immediately full-screen-cover every new user on first frame of the main tab — it fights the “wow” of photo content.
- Prefer: (a) merge into app welcome, **or** (b) delayed coachmarks on real UI (spotlight search, heart, first card), **or** (c) a dismissible bottom sheet after 1–2 seconds of content visible.
- Keep “Or build from scratch” but secondary.

### 5.4 Splash & brand line

Update splash subtitle from split-only to dual promise, e.g.:

- “Discover trips. Split fairly.”
- “Plan the trip. Share the cost.”

Keep logo animation; messaging must not contradict the new primary tab.

---

## 6. Home / Trips tab as secondary — redesign for support role

The ledger tab should feel **sharp and task-oriented**, not like a competing home feed.

### 6.1 Positioning

| Keep | Demote / compress | Add |
|---|---|---|
| Balance / budget card | Long empty states that teach product basics (Explore already did discovery) | Entry from Explore: “Budget for Tokyo itinerary” deep links later |
| Split + Add Expense quick actions | Feeling like the app’s emotional center | Compact “Planning in Explore” chip if user has itinerary trips with no expenses yet |
| Your Trips | — | Clear archived access |
| Recent transactions | — | — |

### 6.2 Empty state copy (Trips tab)

When `myTrips.isEmpty`:

- **Before:** “Create a trip to start tracking expenses.”
- **After:** dual CTA  
  - Primary: “Browse trip ideas” → switch dock to Explore  
  - Secondary: “Create empty trip” → `AddTripView`

This closes the loop: Explore inspires; Trips records.

### 6.3 Cross-tab continuity

Add lightweight bridges (no new data model required):

| From | To | UX |
|---|---|---|
| Explore itinerary detail | Trips tab | “Track expenses for this trip” if trip already exists in store |
| Destination “Use as plan” | Stays in Explore stack | After create, optional banner “Also track spending in Trips” |
| Home empty / no activity | Explore | “Need inspiration?” card with 3 mini destination thumbs |
| Settings `exploreCard` | Update copy | No longer “promo to a side tab”; can become “Featured guides” or be removed if redundant |

### 6.4 Navigation title

Home currently: `Hi, {name}`.  
If Explore takes personal greeting, Trips can use a functional title: **“Your trips”** or **“Split”** — clearer for a secondary utility tab.

---

## 7. First impression journey (end-to-end)

### 7.1 Cold install (ideal path)

```
Splash (0.45s)
  → Welcome (discover → plan → split)
  → Explore main (hero imagery visible immediately)
  → Optional soft coachmark
  → User opens Tokyo guide
  → “Use as my starting plan” → sign-in if needed
  → Editable itinerary
  → Invite friends
  → Later: Trips tab for expenses / settle
```

### 7.2 Returning user (ideal path)

```
Splash → Explore
  → “Continue” rail: saved Kyoto + “Japan spring” itinerary in progress
  → One tap resumes planning
  → Map for a stop
  → Trips tab only when spending starts
```

### 7.3 Metrics of success (qualitative)

Implementers / designers should judge the redesign against:

1. **0–3 seconds:** Is there beautiful place photography without reading a paragraph?
2. **3–15 seconds:** Can the user start a meaningful action (search, open guide, resume plan)?
3. **Session 2:** Is there a reason to return that isn’t “I have a receipt to split”? (saved + unfinished itinerary)
4. **Does Split still feel 1-tap away?** Dock position 3 + quick actions on Trips tab.

---

## 8. Engagement loops to build into Explore UI

These are product patterns, not optional polish.

### 8.1 Save loop

- Heart on every card + detail.
- Saved section **only when non-empty**, high on page.
- Empty state: do not lecture; show “Popular to save” mini-rail instead of a heart tutorial card at the top.

### 8.2 Resume loop

- Merge **Saved** + **Your itineraries** into a single **Continue** module when either has content:
  - “Saved guides” horizontal
  - “Plans in progress” horizontal
- Badge unfinished itineraries (“3 days unplanned”).

### 8.3 Commit loop (curated → owned)

- Sticky “Use as my starting plan”.
- Post-create: land in `ItineraryDetailView` with a checklist of first edits (add day note, set dates, invite).

### 8.4 Social loop

- From itinerary: invite / friends entry points visible within first screen of planner (not buried).
- Copy should say “plan together”, not only “split later”.

### 8.5 Map loop

- Keep place → Map focus via `ExploreMapModel`.
- On Map, Back returns to Explore detail (already intended via `originTab`) — verify after tab default change that `originTab` still restores Explore, not Trips.

### 8.6 Habit loop (lightweight, no backend)

- Rotating featured set (shuffle weekly from `isFeatured` using a date-seeded RNG) so the main tab doesn’t feel static.
- Optional “Trip of the day” single hero.

### 8.7 What not to do for engagement

- No dark-pattern infinite onboarding.
- No fake live “12 people viewing Tokyo”.
- No notification spam design in this pass.
- No forcing sign-in to scroll.

---

## 9. Content & density notes

Explore already ships ~25 photo destinations (`Assets.xcassets/explore-*.imageset`). That is enough for a strong main tab **if** hierarchy is right.

Recommendations:

1. **Featured set** (`isFeatured`): ensure 6–10 solid heroes; uneven quality hurts main-tab trust.
2. **Collections:** group by existing tags (`Urban`, `Foodie`, `Beach`, `Culture`, etc.) into 3–4 named rails — higher perceived catalog depth without new cities.
3. **Search empty state:** suggest 4 popular queries as tappable chips.
4. **Performance:** keep `LazyVStack` / `LazyHStack`; hero images should use existing asset catalog images (already local). Avoid remote dependency for first paint.

---

## 10. Accessibility, localization, platform rules

From `Claude.md` — non-negotiable:

1. **Localization:** no `Text(stringVariable)` for UI labels; use `LocalizedStringKey` / string catalog keys. New copy (tab rename, CTAs, welcome pages) must be added carefully for en/es/zh-Hans.
2. **Dynamic content:** names, money, city names → `Text(verbatim:)` where appropriate.
3. **VoiceOver:** preserve combined accessibility on cards; sticky CTA needs a clear label; dock labels must match new names.
4. **Hit targets:** 44pt minimum on hearts, chips, dock.
5. **MainActor:** any new store reads/writes stay on main; no background mutation of `@Observable` trip state.
6. **No new SPM / third-party UI kits.**

---

## 11. Implementation phases (for the coding agent)

Ship in order so each phase is reviewable.

### Phase A — Structural swap (must ship together)

1. Reorder `DockTab` cases; rename Home label/icon.
2. Default `selectedTab` + `visitedTabs` to Explore.
3. Auth success → Explore.
4. Soft-gate Explore mutations; remove hard `LockedExploreScreen` wall (or relegate to a non-default edge case).
5. Fix copy references to “Home tab”.
6. Verify Map `originTab` / explore request still works.
7. Sync banner rules updated.

**Exit criteria:** cold launch opens Explore with destinations visible signed-out; dock order Explore · Map · Trips · Profile.

### Phase B — Explore main-tab IA

1. Hero-first layout; compress intro copy.
2. Continue module (saved + itineraries).
3. Intent chips + filter UX polish.
4. Sticky detail CTA.
5. Empty-saved no longer blocks hero.

**Exit criteria:** first viewport is photographic and actionable.

### Phase C — Story & retention

1. Welcome + splash messaging rewrite.
2. Soft Explore coaching (not blocking fullScreen on every first open).
3. Trips-tab empty state bridges back to Explore.
4. Optional weekly featured rotation.

**Exit criteria:** first-run story matches Explore-primary product.

### Phase D — Polish (optional)

1. Collections rails by tag.
2. Personal greeting on Explore.
3. Itinerary progress badges.
4. Settings promo card retuned or removed.

---

## 12. Explicit non-goals / risks

| Risk | Mitigation |
|---|---|
| Expense power users feel lost | Keep Split/Add Expense one dock tap + quick actions; don’t bury settle |
| Explore content feels shallow as “home” | Collections + Continue + sticky CTA > adding dozens of cities in v1 |
| Double onboarding (app + Explore) | Merge messaging; never stack two full-screen tutors |
| Sign-out main tab empty | Browse allowed; save/plan gated |
| Scope creep into Map redesign | Only fix bridges broken by tab default changes |
| Renaming Home breaks muscle memory | Use clear **Trips** iconography + label; avoid vague “Home” |

---

## 13. Suggested acceptance checklist

- [ ] Fresh install → splash → welcome that mentions discovery **and** split → lands on Explore with photos.
- [ ] Signed out: can browse/search/open detail; heart or “Use as plan” prompts sign-in.
- [ ] Signed in: default tab Explore; Continue shows saved/itineraries when present.
- [ ] Dock: Explore · Map · Trips/Split · Profile; active tab label animates as today.
- [ ] Destination detail: primary plan CTA visible without hunting.
- [ ] Creating plan from guide still navigates to itinerary editor.
- [ ] Map open-from-place still returns to Explore via Back.
- [ ] Trips tab still supports balance, split, add expense, trip list, transactions.
- [ ] Empty Trips tab offers path back to Explore.
- [ ] Sync failure visible from Explore.
- [ ] All new user-facing strings localization-safe.
- [ ] `xcodebuild` clean success (no simulator required unless user asks).

---

## 14. File touch list (expected)

| File | Likely changes |
|---|---|
| `ContentView.swift` | Dock enum order/labels/icons, default tab, auth redirect, Explore auth gating, alerts copy |
| `FloatingDock.swift` | Usually none beyond enum-driven labels |
| `ExploreScreen.swift` | Layout IA, hero, continue module, soft-gate hooks, sticky CTA in detail |
| `HomeScreen.swift` | Title, empty states, optional Explore bridge card, secondary positioning |
| `OnboardingFeature.swift` | Welcome pages; Explore onboarding timing/presentation |
| `SplashScreen.swift` | Tagline |
| `ItineraryFeature.swift` | Continue/progress presentation if merged into Explore header module |
| `MapFeature.swift` | Only if `DockTab` rename / origin defaults break |
| `SettingsScreen.swift` | Promo card copy |
| `Localizable.xcstrings` | All new/changed strings |
| `ExploreModels.swift` | Only if adding collection metadata / tag helpers (prefer minimal) |

---

## 15. Design principles (carry through every PR)

1. **Inspiration before accounting.** Money tools remain excellent; they are no longer the front door.
2. **Show the trip, don’t explain the tab.** Photos and plans beat instructional paragraphs.
3. **Return paths beat novelty.** Saved + unfinished itineraries outrank new chrome.
4. **Gate actions, not curiosity.** Browse free; commit requires account.
5. **One primary CTA per screen.** Explore root → open a guide / resume. Detail → start plan. Trips → split or add expense.
6. **Surgical implementation.** Prefer reordering and restyling existing components (`AdventureCard`, `CountryTripCard`, `ItineraryPlannerSection`) over a ground-up rewrite.

---

## 16. Summary for the implementer

You are not “moving Explore to index 0.” You are **re-homing the product’s emotional center** onto discovery while keeping TripSplit’s differentiator (fair splitting) one intentional tap away.

**Minimum lovable outcome:**  
Open app → see a beautiful place immediately → open a guide → start a plan → later track spend on Trips.

**Failure mode to avoid:**  
Open app → still feel like a finance utility with a travel magazine buried in the dock — or open app → locked “members only” wall on the new main tab.

# TripSplit UX/UI App Store Readiness Review

**Review date:** August 3, 2026  
**Status:** Implementation pass complete; remaining manual and external submission gates are listed below  
**Scope:** First launch, navigation, core trip and expense flows, forms, state feedback, accessibility, localization, iPhone/iPad layout, and light/dark appearance.

## Executive summary

At the review baseline, TripSplit already had a stronger visual foundation than a typical pre-release build: a centralized adaptive theme, a real dark appearance, system symbols, useful empty/loading states, visible sync failures, purpose-specific privacy UI, and generally generous control sizes. The app did not need a wholesale redesign.

The repository now implements the consistency and completion pass described here: release UI no longer advertises dormant features or incomplete languages, semantic color pairings are adaptive and tested, financial actions describe what they save, onboarding is shorter, and the first release is deliberately scoped to iPhone portrait. The remaining gates are physical-device accessibility QA, a healthy-host XCUITest run, operational support/reviewer access, screenshots, and App Store Connect metadata.

The deterministic `-app-store-demo` experience was compiled, launched, and visually inspected on an iPhone 17 simulator in dark appearance after implementation. The original first-launch review also covered light and dark appearances. A full signed-device usability study is still required.

## How to use this document

Each item has an editable decision field. Check one option when you are ready:

- **Implement:** include it in an upcoming UX pass.
- **Defer:** valuable, but not required for the first submission.
- **Skip:** consciously retain the current behavior.

Priorities mean:

- **P0:** recommended release gate because it affects completeness, accessibility, or a core journey.
- **P1:** strong pre-launch improvement that materially increases clarity and polish.
- **P2:** optional refinement or optimization.

## Decision board

| ID | Priority | Effort | Recommendation | Decision |
| --- | --- | --- | --- | --- |
| UX-01 | P0 | M | Remove, relabel, or finish nonfunctional/incomplete controls | [x] Implement [ ] Defer [ ] Skip |
| UX-02 | P0 | M–L | Complete Spanish and Simplified Chinese or hide those choices | [x] Implement [ ] Defer [ ] Skip |
| UX-03 | P0 | M | Fix semantic and selected-control contrast in light/dark mode | [x] Implement [ ] Defer [ ] Skip |
| UX-04 | P0 | M–L | Complete Dynamic Type, touch-target, VoiceOver, and accessibility-setting support | [x] Implement [ ] Defer [ ] Skip |
| UX-05 | P0 | M | Shorten launch and replace duplicate onboarding with contextual education | [x] Implement [ ] Defer [ ] Skip |
| UX-06 | P0 | S–M | Unify sign-in routing, terminology, fields, and recovery feedback | [x] Implement [ ] Defer [ ] Skip |
| UX-07 | P0 | M–L | Intentionally scope iPhone, iPad, landscape, macOS, and visionOS support | [x] Implement [ ] Defer [ ] Skip |
| UX-08 | P0 | M | Add UI smoke tests and automated accessibility audits | [x] Implement [ ] Defer [ ] Skip |
| UX-09 | P1 | M–L | Standardize top-level navigation and reduce nested modal stacks | [x] Implement [ ] Defer [ ] Skip |
| UX-10 | P1 | M | Simplify and clarify the expense/split/settle journey | [x] Implement [ ] Defer [ ] Skip |
| UX-11 | P1 | M | Reduce Map control density and preserve more usable map area | [x] Implement [ ] Defer [ ] Skip |
| UX-12 | P1 | M | Improve form hierarchy, labels, validation, and keyboard behavior | [x] Implement [ ] Defer [ ] Skip |
| UX-13 | P1 | M | Reserve glass for chrome and use quieter readable financial surfaces | [x] Implement [ ] Defer [ ] Skip |
| UX-14 | P1 | M | Standardize loading, offline, error, success, and undo feedback | [x] Implement [ ] Defer [ ] Skip |
| UX-15 | P1 | S–M | Simplify Settings and group advanced visual customization | [x] Implement [ ] Defer [ ] Skip |
| UX-16 | P1 | M | Make Profile responsive and clarify what is public/shared | [x] Implement [ ] Defer [ ] Skip |
| UX-17 | P1 | S–M | Tighten copy, empty states, and action naming | [x] Implement [ ] Defer [ ] Skip |
| UX-18 | P2 | M | Prepare App Store screenshots, demo content, and reviewer flows | [x] Implement [ ] Defer [ ] Skip |

## Recommended minimum submission package

Complete **UX-01 through UX-08** before the first App Store submission. UX-09 through UX-17 can be staged, but UX-10, UX-13, and UX-14 would produce the largest perceived-quality improvement after the release gates.

## Implementation result

The implementation choice is now locked for all 18 recommendations. “Complete” below means the repository change is implemented and compiled; it does not replace the manual release validation matrix or App Store Connect work.

| ID | Repository status | Implemented result |
| --- | --- | --- |
| UX-01 | Complete | Removed dormant notification and placeholder UI. **Split Expense** now opens the persistent Add Expense flow with group splitting enabled. |
| UX-02 | Complete | First release is explicitly English-only: removed the language picker, non-English catalog values, and non-English project regions. Restore languages only after complete human review. |
| UX-03 | Complete | Added adaptive semantic text/fill colors, `Theme.onAccent` selection foregrounds, higher-contrast surfaces, and automated light/dark contrast tests for all themes. |
| UX-04 | Code complete; manual audit required | Added Dynamic Type adaptations, 44 pt targets, accessible small-label styles, Reduce Motion/Transparency and Increase Contrast behavior on shared chrome/surfaces. Complete the VoiceOver/device matrix before submission. |
| UX-05 | Complete | Removed the artificial splash hold and reduced first launch to one optional value screen with **Create account** and **Browse without account**. Removed the automatic second carousel. |
| UX-06 | Complete | Added one reusable contextual authentication sheet, intent replay, consistent account terminology, persistent labels, password reveal/requirements, and keyboard focus behavior. |
| UX-07 | Complete | Scoped the first release to iPhone portrait; removed advertised iPad, landscape, macOS, and visionOS support. |
| UX-08 | Tests implemented; execution environment follow-up | Added an XCUITest target with first-launch/navigation smoke tests and `performAccessibilityAudit`, plus deterministic launch flags. The bundle compiles; on this machine the iOS 26.5 simulator rejects the XCUITest runner during preflight before tests start. Rerun on a healthy simulator/CI host. |
| UX-09 | Complete for retained custom dock | Kept the custom dock, made all labels persistent, capped transparency, added accessibility-setting overrides, and preserved presenting-tab intent after authentication. |
| UX-10 | Complete | Made saved Add Expense the split entry point and changed money-transfer-implying labels to **Record payment** where the app records rather than moves funds. |
| UX-11 | Complete | Consolidated secondary Map layers into **Layers & Filters**, shows recents only during search, expands close targets, and provides no-result/network feedback. |
| UX-12 | Core forms complete | Added persistent labels, focus/submit/keyboard behavior, inline password requirements, and locale-aware grouped currency display to authentication, trip, and expense surfaces. Locale input and extreme-content cases remain in the manual matrix. |
| UX-13 | Complete | Reserved glass for chrome and changed information-dense trip, balance, budget, split, and settlement cards to readable adaptive surfaces. |
| UX-14 | Core states complete | Added reusable loading/error views and actionable Map search feedback. Continue applying success/undo patterns when new mutation flows are added. |
| UX-15 | Complete | Reorganized Settings into Account, Money, Appearance, and Privacy & Safety; moved visual controls to Appearance and removed inactive notifications/language controls. |
| UX-16 | Complete | Made profile stat/money groups responsive at accessibility sizes, added shared-profile preview, and added a direct Places empty-state action. |
| UX-17 | Complete | Removed duplicate trip headings and standardized **Split Expense** and **Record payment** terminology plus actionable empty-state copy. |
| UX-18 | Code complete; submission assets external | Added deterministic, local-only `-app-store-demo` data with a collaborative itinerary, mapped stops, itemized expenses, comments, budgets, and a confirmed partial payment. Screenshots, reviewer credentials/notes, and metadata still belong in App Store Connect. |

### Verification recorded on August 3, 2026

- `xcodebuild ... build-for-testing`: passed for the app, unit-test bundle, and UI-test bundle on an iPhone 17 simulator destination.
- `TripsplitAppTests`: all 20 tests passed, including semantic text, all-theme selected-control contrast, AI-consent fallback, and Storage error-sanitization tests.
- `TripsplitAppUITests`: compiled but did not execute because CoreSimulator rejected `TripsplitAppUITests-Runner` with `Application failed preflight checks (Busy)` before test launch, including after a simulator restart and with parallel testing disabled.
- `plutil -lint Tripsplit.xcodeproj/project.pbxproj`: passed.
- `git diff --check`: passed after the final source and document changes.

### Submission work that cannot be completed in source code

- Staff and verify `support@tripsplit.app`; the source now exposes it for privacy and safety contact. Change it before submission if that inbox is not operational.
- Run the full release validation matrix on physical supported iPhones, especially VoiceOver, largest Accessibility Dynamic Type, Reduce Motion, Reduce Transparency, Increase Contrast, offline behavior, permissions, and camera/receipt flows.
- Rerun the new UI tests on a healthy simulator or CI host and address every accessibility-audit finding.
- Capture final screenshots from the shipping Release build and provide App Review with valid credentials/instructions, privacy metadata, AI behavior notes, UGC moderation/reporting steps, and account-deletion steps.

## Light and dark appearance recommendations

### What should remain

- Keep the centralized adaptive palette in [Theme.swift](Tripsplit/Theme.swift).
- Keep `Theme.onAccent`; it correctly switches to dark text when dark-mode accent colors become light.
- Keep `AppBackground`, but make foreground surfaces and secondary text pass contrast independently of the decorative gradient.
- Keep system-following appearance as the default. Light and Dark overrides can remain available.

### Token-level changes

| Element | Current risk | Light appearance recommendation | Dark appearance recommendation |
| --- | --- | --- | --- |
| Secondary text | The onboarding body and **Skip** action look too quiet over the pale Classic gradient | Add an adaptive `textSecondary` token with at least 4.5:1 for normal body text | Lift secondary text enough to separate it from tertiary/disabled content |
| Positive status | Fixed `#10B981` is only **2.54:1** against white | Use a darker green for text/icons; retain the current green for non-text fills if desired | Use a lighter green that remains distinct on raised surfaces |
| Negative status | Fixed `#EF4444` is **3.76:1** against white | Use a darker red for normal-sized text | Use a lighter red, not the same fixed token |
| Warning status | Fixed `#F59E0B` is **2.15:1** against white | Use a dark amber/brown for text and the current orange for fills | Use a lighter amber with a dark foreground when used as a filled control |
| Selected controls | Several selected chips use hardcoded `.white` over `Theme.accent` | White works with the darker light-mode accents, but still use `Theme.onAccent` consistently | White fails against the light dark-mode accents: measured ratios are **1.72:1–2.98:1** across the eight themes; use `Theme.onAccent` |
| Information cards | Glass can disappear into pale theme gradients | Use an opaque or near-opaque surface, a restrained 1 pt edge, and minimal shadow | Use lifted surfaces with a clear luminance step from the background; avoid stacking multiple translucent dark layers |
| Separators | Thin low-opacity separators vanish on some themes | Increase edge contrast slightly; avoid using shadow and border at equal strength | Use separators sparingly and ensure they remain visible with Increase Contrast |
| Photo overlays | White labels depend on a manually chosen black gradient | Standardize one photo-scrim component and test bright images | Use the same component; do not assume a dark appearance makes arbitrary photos safer |
| Disabled state | Opacity-only disabled controls can resemble low-contrast enabled controls | Combine reduced emphasis with disabled semantics and explanatory validation | Keep labels readable; avoid dimming below readable contrast |

Add automated contrast checks for every semantic token and every theme pairing. The current eight themes create at least 16 appearance combinations before accessibility settings and content imagery are considered.

## Original review findings and acceptance criteria

The observations below preserve the pre-implementation baseline and explain why each change was chosen. Use the **Implementation result** table above for current repository status.

### UX-01 — Remove, relabel, or finish incomplete controls

**Observed**

- Notification switches in [SettingsPreferences.swift](Tripsplit/SettingsPreferences.swift) only write `UserDefaults`; no notification delivery code reads them. The footer explicitly says delivery will arrive later.
- The Trips-screen **Split** shortcut opens [SplitFeature.swift](Tripsplit/SplitFeature.swift), whose calculator and settlement history are local view state and are not saved to a trip.
- A dormant `PlaceholderScreen` still contains **Coming soon**, although it is not currently presented.

**Recommended change**

- Hide Notifications until delivery exists, or rename the section to accurately describe an implemented in-app activity preference and wire it to behavior.
- Choose one meaning for **Split**:
  - preferred: open Add Expense directly at the split configuration and save the result to the selected trip; or
  - relabel it **Split calculator**, explain that it is temporary, add a Share result action, and move it out of the primary action row.
- Remove release-build placeholder code and scrub visible “coming soon,” beta, sample, or future-service copy.

**Acceptance criteria**

- Every visible switch or button has an observable effect.
- App Review can complete every visible path without encountering promised future functionality.
- Primary trip financial actions either persist or explicitly state that they do not.

### UX-02 — Finish localization or narrow the supported-language UI

**Observed**

[Localizable.xcstrings](Tripsplit/Localizable.xcstrings) contains **874** keys. Spanish and Simplified Chinese each lack **411** values, and 25 string units are not in the translated state. Many missing keys belong to account deletion, AI privacy, community standards, itinerary, profile, and trip-management journeys.

**Recommended change**

- For the first submission, choose one:
  - complete and review all Spanish and Simplified Chinese entries, including plurals, interpolations, privacy language, and purpose strings; or
  - temporarily remove the in-app language picker and advertise English only.
- Replace user-facing `String` composition with plural-aware catalog variants. Avoid manual `item/items`, `day/days`, and `expense/expenses` suffix construction.
- Test long Spanish labels and Chinese layout on every main screen; do not only validate catalog completeness.

**Acceptance criteria**

- The selected language never falls back to English in a primary, privacy, destructive, or error journey.
- No clipped/truncated controls at Accessibility text sizes in all advertised languages.
- App Store metadata and screenshots advertise only the languages actually shipped.

### UX-03 — Make color communication accessible in both appearances

**Observed**

The adaptive accents are thoughtfully designed, but the fixed `Theme.positive`, `Theme.negative`, and `Theme.warning` values are also used as small text. Several selected pills in expense and split UI still force white text instead of using `Theme.onAccent`.

**Recommended change**

- Define adaptive semantic text, fill, and foreground pairs rather than one color per status.
- Replace hardcoded `.white` on theme-tinted controls with `Theme.onAccent`.
- Pair status colors with text and symbols: **Over budget**, **Pending**, **Confirmed**, and **Declined** must not depend on hue alone.
- Add a high-contrast variant or respond to the system Increase Contrast setting.

**Acceptance criteria**

- Normal text meets 4.5:1; large/bold text meets 3:1 in both appearances.
- Selected/unselected states remain understandable in grayscale and Differentiate Without Color.
- Contrast is verified across all eight themes, not only Classic.

### UX-04 — Complete accessibility support

**Observed**

- Many controls correctly use 44 pt minimum targets and VoiceOver labels.
- Some interactive controls still render at 26–40 pt without an expanded 44 pt hit region.
- `Font.app(size:)` intentionally does not scale. It appears in important totals and labels, while some trip-detail text is 9–10 pt.
- Only the balance card explicitly adapts to accessibility Dynamic Type sizes.
- The app uses glass, spring animation, symbol effects, color states, and custom gestures without app-wide handling for Reduce Motion, Reduce Transparency, Increase Contrast, or Differentiate Without Color.

**Recommended change**

- Use relative text styles for all meaningful text; reserve fixed sizes for decorative symbols and rendered share cards.
- Do not ship essential text below 11 pt. Prefer `.caption2` over fixed 9/10 pt labels.
- Make every interactive target at least 44×44 pt, including close, remove, comment, and chip controls.
- Add responsive vertical/grid alternatives for profile stats, trip stats, financial strips, filters, and dock labels at accessibility sizes.
- Respect accessibility environment values:
  - Reduce Motion: remove bounce/spring movement and use fades.
  - Reduce Transparency: replace glass with opaque readable surfaces.
  - Increase Contrast: strengthen foregrounds, borders, and selected states.
  - Differentiate Without Color: add icons, text, or patterns.
- Define VoiceOver order and custom actions for cards with hidden context menus or swipe actions.

**Acceptance criteria**

- The core journey works at the largest Accessibility text size without clipped amounts or unreachable actions.
- VoiceOver can create a trip, add/split an expense, accept an invitation, report content, and delete an account.
- Accessibility Inspector finds no contrast, clipping, hit-region, or missing-description failures on release-gate screens.

### UX-05 — Shorten launch and consolidate onboarding

**Observed**

- [SplashScreen.swift](Tripsplit/SplashScreen.swift) adds an artificial 0.45-second hold plus a 0.35-second transition after the system launch screen.
- A signed-out first launch can show three welcome pages. Creating an account can then lead to profile setup and another three-page Explore tour.
- The light/dark screenshots show a polished composition, but too much empty vertical space and low-emphasis explanatory text.

**Recommended change**

- Remove the artificial splash delay. Transition as soon as session/bootstrap state is ready.
- Reduce prerequisite onboarding to one concise value screen with **Browse first** and **Create account**.
- Teach saving, map exploration, receipt scanning, and collaborative planning with contextual TipKit-style prompts after the related screen is visible.
- Keep the tutorial replayable from Help, but never automatically show two carousels in one first-use journey.
- Tighten vertical spacing on tall phones and provide an adaptive compact layout in landscape/small screens.

**Acceptance criteria**

- A new user can reach browsable content in one tap or less than a few seconds.
- Onboarding remains optional and is not repeated after Skip.
- Account creation does not immediately trigger another general product tour.

### UX-06 — Unify the authentication experience

**Observed**

- The shared `signInRequiredAlert` says to sign in from the **Settings tab**, but the top-level tabs are Explore, Map, Trips, and Profile.
- Explore opens a contextual sign-in sheet, Profile presents `SettingsScreen` as a route to authentication, and Trips shows a dead-end OK alert.
- Auth fields use placeholders without persistent visible labels and provide no password reveal control.
- The auth primary button is fixed indigo instead of following the selected theme.

**Recommended change**

- Create one reusable authentication sheet and present it directly from every gated action.
- Preserve and replay the action after sign-in, as Explore already does.
- Use visible **Email** and **Password** labels, a show/hide password button, password requirement feedback, keyboard submit actions, and focus movement.
- Standardize terms: **Sign in**, **Create account**, **Forgot password**, and **Log out/Sign out**. Avoid mixing Login, Log in, and Sign In.
- Use `Theme.accent` plus `Theme.onAccent` for the primary action.

**Acceptance criteria**

- A signed-out tap on Add Expense, Create Trip, Save, or Invite opens the same contextual auth surface.
- Successful authentication completes or resumes the original intent.
- No copy points to a nonexistent tab.

### UX-07 — Deliberately choose supported layouts and platforms

**Observed**

The app target currently advertises iPhone, iPad, and device family 7, and lists iPhoneOS, simulator, macOS, and xrOS platforms in the project settings. Both iPhone and iPad permit landscape. Much of the UI is designed as one phone-width column with fixed card widths.

**Recommended change**

- Before submission, choose one release scope:
  - **Recommended first release:** iPhone only, portrait plus any landscape layouts that are actually tested; or
  - build intentional iPad layouts using `NavigationSplitView`, bounded content columns, adaptive grids, and a sidebar/tab-bar relationship.
- Do not advertise macOS or visionOS until navigation, hover/pointer, window resizing, permissions, camera/receipt scanning, and platform-specific presentation are tested.
- If iPad remains supported, avoid a stretched single column and use available width for trip list/detail or map/detail compositions.

**Acceptance criteria**

- Every App Store-supported device family and orientation has a reviewed layout.
- No compact phone card is stretched across an iPad window.
- Unsupported platform destinations are removed from Release settings.

### UX-08 — Add release-gate UI and accessibility tests

**Recommended change**

- Add XCUITest smoke paths for:
  - first launch and Skip;
  - signed-out browse and contextual sign-in;
  - create trip → add expense → select split → save;
  - invite preview → Join/Decline;
  - offline/error retry;
  - report/block;
  - sign out and delete account.
- Run `performAccessibilityAudit` on Welcome, Explore, Trips, Add Expense, Trip Detail, Map, Profile, Settings, auth, AI consent, and account deletion.
- Add launch arguments/fixtures for deterministic empty, populated, loading, error, and large-data states.

**Acceptance criteria**

- UI tests fail on clipped text, missing accessibility descriptions, insufficient contrast, broken navigation, or inactive controls.
- Release QA covers light/dark, small/large phones, largest Dynamic Type, and every supported device family.

### UX-09 — Standardize navigation

**Observed**

The custom floating dock preserves tab state and has 44 pt buttons, which is good. However, active-only labels, swipe navigation, a user-adjustable transparency level, and hiding the dock on Explore details diverge from normal tab-bar expectations. Full destinations sometimes push and sometimes appear as sheets, creating nested modal stacks.

**Recommended change**

- Evaluate a native `TabView` for automatic Liquid Glass, compact/regular adaptation, persistent labels, VoiceOver behavior, and iPad sidebar conversion.
- If retaining the dock, keep all four labels visible at accessibility sizes, cap transparency at a verified readable value, and override it for Reduce Transparency/Increase Contrast.
- Use navigation pushes for durable destinations such as Trip Detail, Itinerary Detail, and Profile Detail. Reserve sheets for creation, editing, confirmation, filters, and short tasks.
- Preserve a visible and predictable route back when the dock is intentionally hidden.

### UX-10 — Clarify the financial journey

**Recommended change**

- Make **Add expense** the primary action and treat split configuration as part of that saved expense.
- Rename ambiguous actions:
  - **Split** → **Split expense** or **Calculator** depending on the chosen behavior.
  - **Settle Up** → **Record payment** when the action records rather than transfers money.
- In Add Expense, lead with amount, title, payer, and participants. Collapse receipt, location, tax/tip, and advanced methods until needed.
- Keep a live “everyone reconciles to total” summary visible near Save.
- Clearly distinguish **recorded**, **pending confirmation**, and **confirmed** settlements.

### UX-11 — Reduce Map overlay density

**Observed**

The Map can simultaneously display trip selection, Explore return, search, recent searches, category chips, itinerary controls, spending controls, search-this-area, loading state, selected place cards, and the app dock. The map itself can become the smallest usable element.

**Recommended change**

- Keep only search and current context visible by default.
- Move Spending, Saved, Trip places, Feed places, map style, route options, and payer/date filters into one **Layers & filters** sheet/menu.
- Show recent searches only while search is focused.
- Collapse itinerary controls into a compact day/route bar.
- Use a single bottom card with progressive detents for selected content.

### UX-12 — Improve form usability

**Recommended change**

- Give every field a persistent label; placeholders should demonstrate format, not carry the only meaning.
- Use `.submitLabel` and focus-state sequencing for email, passwords, trip name, expense title/amount, invite email, and profile fields.
- Put validation beside the affected field and explain why Save is disabled.
- Format currency input by locale and accept locale decimal separators.
- Avoid fixed 64 pt amount fields and one-line member names at large text sizes.
- Preserve unsaved work when a picker, AI-consent sheet, or camera flow interrupts a form.

### UX-13 — Simplify glass and surface hierarchy

**Recommended change**

- Use Liquid Glass for the top-level tab bar, navigation controls, compact floating actions, and short interactive overlays.
- Use `Theme.surface`/system grouped backgrounds for dense financial cards, forms, comments, settings rows, and long reading content.
- Avoid glass nested inside glass and multiple borders/shadows on the same card.
- Standardize corner radii by role:
  - 12–14 pt fields and small controls;
  - 16 pt list cards;
  - 20 pt feature cards;
  - capsule only for chips and short actions.
- Keep dark surfaces separated by luminance, not stronger shadows.

### UX-14 — Standardize system feedback

**What is already good**

- Feed has distinct loading/error/empty states and Retry.
- Trips exposes cloud load failures and failed saves.
- Receipt scan communicates scanning, uploading, offline fallback, and retry.

**Recommended change**

- Create shared `LoadingStateView`, `ErrorStateView`, toast/banner, and undo presentation components.
- Replace silent `try?` network/search failures in Map and profile enrichment with no-results, offline, or retry feedback where the failure affects the user’s action.
- Use skeletons only when content shape is known; use a labeled progress state for short transactional work.
- Show a concise success acknowledgement for invite sent, expense saved, settlement recorded, report submitted, and account blocked.
- Keep optimistic updates reversible with Undo when practical.

### UX-15 — Simplify Settings

**Recommended change**

- Group settings into Account, Money, Appearance, Privacy & Safety, and About.
- Move Theme, Font, tab-bar transparency, and advanced appearance controls into an **Appearance** destination rather than placing each on the main page.
- Rename **Navbar transparency** to **Tab bar background** or **Dock background**; “navbar” is ambiguous on iOS.
- Remove the notification row until it controls a live feature.
- Add Support, Privacy Policy, Terms/Community Standards, and app version/build in one About & Support section.
- Keep Sign Out and Delete Account separated from ordinary preferences with clear destructive hierarchy.

### UX-16 — Make Profile responsive and privacy-aware

**Recommended change**

- Convert the four-count and three-money strips to adaptive grids or vertical groups at accessibility sizes.
- Avoid shrinking labels with `minimumScaleFactor` as the primary strategy.
- Add **Preview shared profile** and clearly label which fields friends can see, particularly birthday, visited places, trip summaries, and money-related data.
- Provide edit/add actions directly in empty Places, Saved, Friends, and Trips sections instead of instructional text alone.
- Bound card widths and use grids on iPad rather than long horizontal rails.

### UX-17 — Tighten language and empty-state actions

**Recommended change**

- Remove duplicated **Your trips** navigation and section titles.
- Keep action vocabulary consistent: **Trip**, **Expense**, **Payment**, **Settlement**, **Invite**, and **Guide** should each mean one thing.
- Give every empty state one primary action and, at most, one quiet alternative.
- Prefer outcome-oriented labels:
  - **Create first trip** instead of generic Add;
  - **Browse guides** instead of Look around;
  - **Record payment** instead of Settle when no money moves;
  - **Try search again** or **Clear filters** for no results.
- Review all destructive and privacy copy in plain language and all localized variants.

### UX-18 — Prepare the App Store presentation

**Recommended change**

- Build deterministic demo data that shows the full value story without exposing real user data: Explore guide, collaborative itinerary, mapped stops, multi-person expense, receipt split, and confirmed settlement.
- Capture screenshots in both appearance modes, but choose one cohesive appearance for each localized product page.
- Ensure screenshots match actual shipping UI and supported devices.
- Prepare reviewer notes that explain demo credentials, receipt scanning, AI decline/fallback, invitations, UGC reporting, and account deletion.

## Screen-by-screen visual direction

| Screen | Keep | Improve first |
| --- | --- | --- |
| Welcome | Strong headline, large target, adaptive accent foreground | Reduce to one screen, strengthen secondary text, remove artificial launch delay, tighten vertical whitespace |
| Explore | Good imagery-first direction, search, contextual empty states | Reduce toolbar duplication; replace the automatic second tour with contextual tips |
| Trips | Useful balance overview, retryable sync, clear empty state | Remove duplicate title; make Add Expense the primary financial action; clarify Split |
| Trip Detail | Strong cover/photo hierarchy and clear financial sections | Reduce 440 pt hero on compact/landscape screens; remove 9–10 pt essential labels; prefer push navigation |
| Add Expense | Powerful receipt/itemization and advanced splits | Progressive disclosure, persistent field labels, locale-aware amount input, clearer disabled Save explanation |
| Map | Rich trip, place, itinerary, and spending layers | Collapse secondary layers/filters; preserve map area; show actionable network/no-result feedback |
| Profile | Distinct identity/travel story and useful saved content | Adaptive stats, explicit sharing/privacy preview, direct empty-state actions |
| Settings | Broad control and privacy coverage | Remove inert notifications, simplify hierarchy, move advanced appearance controls, add Support/About |
| Auth | Sign in with Apple, reset flow, visible privacy link | One shared route, visible labels, password reveal, consistent terms/theme, resume original action |

## Release validation matrix

| Dimension | Required coverage |
| --- | --- |
| Appearance | Classic Light, Classic Dark, plus automated contrast checks for all eight themes |
| Device | Small supported iPhone, standard iPhone, Pro Max, and iPad sizes if iPad remains supported |
| Orientation | Every orientation advertised in Release build settings |
| Type | Default, XXXL, and largest Accessibility Dynamic Type |
| Accessibility | VoiceOver, Increase Contrast, Reduce Motion, Reduce Transparency, Differentiate Without Color, Button Shapes |
| Language | English plus every visible/advertised language; include long-string and plural cases |
| Content | Signed out, new account, empty, populated, long names, many members, large amounts, many trips, archived trips |
| Network | Offline launch, slow load, request failure, retry, sync conflict, upload failure |
| Permissions | Camera denied, Photos denied/limited, Location denied, notification denied if notifications ship |
| Device behavior | Keyboard shown, incoming interruption, background/foreground, expired session, deep link while signed out |

## Suggested implementation order

1. **Release truth:** UX-01, UX-02, UX-06, and UX-07.
2. **Accessibility foundation:** UX-03, UX-04, and UX-08.
3. **First impression:** UX-05, UX-13, and UX-17.
4. **Core task clarity:** UX-10, UX-12, and UX-14.
5. **Navigation and dense screens:** UX-09, UX-11, UX-15, and UX-16.
6. **Submission presentation:** UX-18.

## Existing focused UX documents

- [Explore-as-main-tab redesign](explore-as-main-tab-redesign.md) contains deeper Explore-specific product rationale. This review reflects the current implementation and should be the release-priority source of truth.
- [Balance card UX handoff](balance-card-ux-handoff.md) contains detailed balance-card behavior and accessibility criteria.
- [Security and App Store readiness](SECURITY_APP_STORE_READINESS.md) remains the source of truth for security, privacy, backend, moderation, and deployment gates.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — completeness and design quality.
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/) — contrast, Dynamic Type, target sizing, and inclusive interaction.
- [Performing accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app) — Accessibility Inspector and automated XCUITest audits.
- [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) and [Color](https://developer.apple.com/design/human-interface-guidelines/color) — adaptive color and appearance guidance.
- [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding) and [Launching](https://developer.apple.com/design/human-interface-guidelines/launching) — fast, optional education and immediate launch.
- [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) — stable top-level navigation, labels, and adaptive behavior.
- [String catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) — translation, plurals, and localization testing.

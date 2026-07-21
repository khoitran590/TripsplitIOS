# Map Section Roadmap

Recommendations and phased plan for improving TripSplit’s Map tab.

## Current state

The Map tab is already a solid **Wanderlog-style discovery map**:

- Category chips (restaurants, cafés, attractions, hotels, shopping)
- “Search this area” after panning
- Place cards with Look Around, Save, Directions, Details
- Explore → Map deep-link with careful POI matching
- Curated trip context + “More from this trip”
- Cloud-backed saved place keys on the profile

**Strength today:** inspiration / place browsing  
**Biggest opportunity:** make it useful for **real trips, money, and plans**

---

## Highest-impact recommendations

### 1. Make it trip-aware (biggest unlock)

Right now the map mostly cares about curated Explore destinations. User trips are mostly string locations + itinerary names — no map presence.

**Recommend:**
- Trip switcher on the map: “All trips” / current trip / specific trip
- Pins for that trip’s destination + itinerary stops
- Fit camera to the selected trip’s bounds

This turns Map from “browse the world” into “see *this* trip.”

### 2. “Add to itinerary / trip” from any pin

Users can save a place, but not act on it inside TripSplit.

**Recommend on place cards:**
- **Add to itinerary** (pick trip + day + stop type)
- **Create expense here** (prefill merchant/location)
- **Save to trip wishlist** (not just global bookmarks)

This closes the loop: discover → plan → spend.

### 3. Spending map (unique TripSplit angle)

Competitors do place discovery. TripSplit can do **money on a map**.

**Recommend:**
- Optional expense pins (when location exists)
- Color/size by amount or category
- Filters: who paid, date range, category
- Tap pin → expense detail / settle context

Worth doing even if location starts optional (autocomplete at expense time).

### 4. Real saved-places layer

Saved keys exist, but there’s no first-class “Saved” experience on the map.

**Recommend:**
- “Saved” chip that shows bookmarked pins
- List + map of saved places
- Persist richer data (name, coord, address, category) — keys alone are fragile
- Group by city / trip

### 5. Free-text search + recent searches

Category chips are fine for browsing; weak when the user already knows the place.

**Recommend:**
- Search bar with MapKit autocomplete
- Recent + saved suggestions
- Bias results to visible region / active trip city

---

## Strong next-tier features

| Feature | Why it fits TripSplit |
|---|---|
| **User location + “Near me”** | Default is still SF-ish; travelers want “around me now” |
| **Day-by-day itinerary path** | Connect Day 1 stops with a polyline / numbered pins |
| **Optimize route order** | “Visit these 5 stops with least walking” |
| **Hours / open-now / price level** | Make restaurant/cafe chips actually decision-useful |
| **Cluster pins** | Avoid clutter once trip + expenses + saved stack up |
| **Shared trip map for members** | Everyone sees same pins, saved spots, planned stops |
| **Feed posts on map** | Feed already tags places — surface them on the map |

---

## UX polish that would feel premium

1. **Empty / cold-start state** — if no focus/category, show “Jump to a trip”, “Explore destinations”, or “Search a city” instead of a bare default map.
2. **Map style toggle** — standard / muted / satellite for sightseeing.
3. **Better multi-pin focus** — when opening an Explore trip, show *all* stops, not only the tapped one (put “More from this trip” on the map, not only in the sheet).
4. **Offline-ish resilience** — cache last searched region/results for flaky travel networks.
5. **Directions options** — walk / transit / drive, or in-app ETA between two stops (not only “Open in Maps”).

---

## What not to prioritize early

- Live collaborator location (privacy + complexity)
- Full offline vector maps
- Heavy social “check-in” network features
- AR / 3D city tours

Cool ideas, but farther from expense-splitting + trip planning.

---

## Phased roadmap

### Phase 1 — Make Map “yours”

1. Trip selector + trip destination pin
2. Free-text search
3. Saved places as a real map layer + list
4. “Add to itinerary” from place card

### Phase 2 — Money + plan

5. Optional expense location → spending map
6. Itinerary stop coordinates (extend `ItineraryStop` carefully with `decodeIfPresent`)
7. Day path / numbered stops

### Phase 3 — Trip-group power

8. Shared map for trip members
9. Feed places on map
10. Route optimization + open-now filters

---

## Strategic takeaway

The map is currently an **Explore companion**. The highest-ROI shift is:

> **Discovery map → trip command center**

### If shipping only three features

1. **Trip-aware pins + trip switcher**
2. **Add place → itinerary / expense**
3. **Spending map**

Those make Map feel native to TripSplit instead of a generic POI browser.

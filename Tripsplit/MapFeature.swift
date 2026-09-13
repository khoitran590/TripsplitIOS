import SwiftUI
import Combine
import MapKit
import UIKit
import CoreLocation

private enum TripMapStyle: String, CaseIterable, Identifiable {
    case standard, muted, satellite
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .standard: "map"
        case .muted: "map.fill"
        case .satellite: "globe.americas.fill"
        }
    }
}

private enum SpendingDateFilter: String, CaseIterable, Identifiable {
    case all, today, week, month
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All dates"
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }
    var cutoff: Date? {
        let calendar = Calendar.current
        switch self {
        case .all: return nil
        case .today: return calendar.startOfDay(for: Date())
        case .week: return calendar.date(byAdding: .day, value: -7, to: Date())
        case .month: return calendar.date(byAdding: .day, value: -30, to: Date())
        }
    }
}

private struct MapSearchCache: Codable {
    var query: String
    var places: [SavedMapPlace]
}

@MainActor
private final class MapSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func update(query: String, region: MKCoordinateRegion?) {
        if let region {
            completer.region = region
            completer.regionPriority = .default
        }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            completer.cancel()
            suggestions = []
        } else {
            completer.queryFragment = value
        }
    }

    func clear() {
        completer.cancel()
        suggestions = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { suggestions = Array(completer.results.prefix(5)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}


/// The map screen, Wanderlog-style: a full-bleed map with floating category chips,
/// an "Exploring:" pill + "Search this area" button while a category is active, and
/// a compact place card at the bottom for the selected pin. Also renders places the
/// user tapped inside a curated Explore trip via `ExploreMapModel`.
struct MapScreen: View {
    @Environment(ExploreMapModel.self) private var mapModel
    @Binding var selectedTab: DockTab
    let isActive: Bool

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )
    /// The most recent visible region, captured as the camera settles, so category
    /// searches and "Search this area" cover what the user is actually looking at.
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var userHasMovedMap = false
    @State private var isApplyingCameraUpdate = false
    @State private var hasObservedInitialCamera = false
    @State private var cameraUpdateRevision = 0

    @State private var activeCategory: MapCategory?
    @State private var places: [MapPlace] = []
    @State private var selectedPlaceID: String?
    @State private var isSearching = false
    /// Shown after the camera moves away from the last searched region.
    @State private var showsSearchThisArea = false
    @State private var detailPlace: MapPlace?
    /// Presents the full-detail sheet for the curated focus place.
    @State private var showsFocusDetail = false
    @State private var lastCenteredCoordinateKey: String?
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchFeedback: String?
    @State private var showsSavedPlaces = false
    @State private var showsSavedList = false
    @State private var itineraryPlace: MapPlace?
    @State private var correctingStop: ItineraryStop?
    /// `nil` represents All trips.
    @State private var selectedTripID: Trip.ID?
    @State private var mapRefreshRevision = 0
    @State private var tripDestinations: [TripDestinationPin] = []
    @State private var resolvedStopPreviews: [ItineraryStop.ID: ItineraryStop] = [:]
    @State private var showsSpending = false
    @State private var spendingPayerID: Person.ID?
    @State private var selectedItineraryDay = 0
    @State private var showsItineraryPath = true
    @State private var expenseDetail: ExpenseMapPin?
    @State private var hasInitializedTripSelection = false
    @State private var isResolvingItineraryLocations = false
    @State private var showsTripPlaces = true
    @State private var showsFeedPlaces = false
    @State private var feedPins: [FeedMapPin] = []
    @State private var isLoadingFeedPlaces = false
    @State private var optimizedStopIDs: [ItineraryStop.ID] = []
    @State private var isOptimizingRoute = false
    @State private var openNowOnly = false
    @State private var mapStyle: TripMapStyle = .standard
    @State private var locationManager = MapLocationManager()
    @State private var expenseDraft: MapExpenseDraft?
    @State private var spendingDateFilter: SpendingDateFilter = .all
    @State private var curatedCompanionPlaces: [MapPlace] = []
    @State private var activePlaceSearchTask: Task<Void, Never>?
    @StateObject private var searchCompleter = MapSearchCompleter()
    @State private var detailedRouteCoordinates: [CLLocationCoordinate2D] = []
    @State private var detailedRouteCache: [String: [CLLocationCoordinate2D]] = [:]
    @State private var isLoadingDetailedRoute = false
    @State private var isTripDrawerExpanded = false
    @AppStorage("mapRecentSearches") private var recentSearchesData = Data()
    @AppStorage("mapLastSearchCache") private var lastSearchCacheData = Data()
    @AppStorage("mapValidatedItineraryStops") private var validatedItineraryStopsData = Data()
    @AppStorage("mapResolvedItineraryCacheV3") private var resolvedItineraryCacheData = Data()
    // Local-only, opaque review keys measure the confirmation/correction ratio without
    // uploading itinerary names, addresses, or coordinates as analytics.
    @AppStorage("mapConfirmedAutomaticStopsV1") private var confirmedAutomaticStopsData = Data()
    @AppStorage("mapCorrectedAutomaticStopsV1") private var correctedAutomaticStopsData = Data()

    /// `MapPlace.saveKey`s the user bookmarked from the place card, cloud-backed on
    /// the profile so they survive reinstalls.
    @Environment(TripStore.self) private var store

    private var selectedPlace: MapPlace? {
        (visiblePlaces + sharedTripPlaces + curatedCompanionPlaces).first { $0.id == selectedPlaceID }
    }

    private var savedLayerPlaces: [MapPlace] {
        var snapshots = store.userProfile.savedMapPlaces
        let richKeys = Set(snapshots.map(\.key))
        snapshots += store.userProfile.savedPlaceKeys.compactMap { key in
            richKeys.contains(key) ? nil : SavedMapPlace(legacyKey: key)
        }
        return snapshots.map { saved in
            MapPlace(saved: saved)
        }
    }

    private var visiblePlaces: [MapPlace] {
        guard showsSavedPlaces else { return places }
        let saved = savedLayerPlaces
        let savedKeys = Set(saved.map(\.saveKey))
        return saved + places.filter { !savedKeys.contains($0.saveKey) }
    }

    private var scopedTrips: [Trip] {
        selectedTripID.map { id in store.myTrips.filter { $0.id == id } } ?? store.myTrips
    }

    private var scopedMembers: [Person] {
        var seen: Set<Person.ID> = []
        return scopedTrips.flatMap(\.members).filter { seen.insert($0.id).inserted }
    }

    private var expensePins: [ExpenseMapPin] {
        guard showsSpending else { return [] }
        return scopedTrips.flatMap { trip in
            trip.expenses.compactMap { expense in
                guard let location = expense.location,
                      spendingPayerID == nil || expense.payerID == spendingPayerID,
                      spendingDateFilter.cutoff.map({ expense.date >= $0 }) ?? true else { return nil }
                return ExpenseMapPin(trip: trip, expense: expense, location: location)
            }
        }
    }

    private var selectedExpensePin: ExpenseMapPin? {
        expensePins.first { $0.id == selectedPlaceID }
    }

    private var selectedFeedPin: FeedMapPin? {
        feedPins.first { $0.id == selectedPlaceID }
    }

    private var sharedTripPlaces: [MapPlace] {
        guard showsTripPlaces else { return [] }
        return scopedTrips.flatMap(\.sharedMapPlaces).map { MapPlace(saved: $0) }
    }

    private var userLocationKey: String? {
        guard let coordinate = locationManager.coordinate else { return nil }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }

    private var selectedItinerary: Itinerary? {
        guard let selectedTripID else { return nil }
        return store.myTrips.first { $0.id == selectedTripID }?.itinerary
    }

    private var itineraryMapStops: [ItineraryDayMapStop] {
        guard showsItineraryPath,
              let itinerary = selectedItinerary,
              itinerary.days.indices.contains(selectedItineraryDay) else { return [] }
        var stops = itinerary.days[selectedItineraryDay].sortedStops
        if !optimizedStopIDs.isEmpty {
            let order = Dictionary(uniqueKeysWithValues: optimizedStopIDs.enumerated().map { ($1, $0) })
            stops.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
        return stops.enumerated().compactMap { index, stop in
            let displayed = ItineraryPinPreview.displayedStop(stop, previews: resolvedStopPreviews)
            guard let coordinate = displayed.coordinate else { return nil }
            return ItineraryDayMapStop(stop: displayed, number: index + 1, coordinate: coordinate)
        }
    }

    private var clusteredVisiblePlaces: [MapPlaceCluster] {
        MapPlaceClusterer.clusters(for: visiblePlaces, in: visibleRegion)
    }

    private var selectedDayStops: [ItineraryStop] {
        guard let itinerary = selectedItinerary,
              itinerary.days.indices.contains(selectedItineraryDay) else { return [] }
        return itinerary.days[selectedItineraryDay].sortedStops.map {
            ItineraryPinPreview.displayedStop($0, previews: resolvedStopPreviews)
        }
    }

    private var locatedStopCount: Int { selectedDayStops.filter { $0.coordinate != nil }.count }

    private var unreviewedAutomaticStop: ItineraryStop? {
        selectedDayStops.first { stop in
            stop.locationSource == .automatic
                && !confirmedAutomaticStopKeys.contains(automaticReviewKey(for: stop))
                && !correctedAutomaticStopKeys.contains(automaticReviewKey(for: stop))
        }
    }

    private var automaticAccuracySummary: (reviewed: Int, percent: Int)? {
        let confirmed = confirmedAutomaticStopKeys.count
        let corrected = correctedAutomaticStopKeys.count
        let reviewed = confirmed + corrected
        guard reviewed >= 5 else { return nil }
        return (reviewed, Int((Double(confirmed) / Double(reviewed) * 100).rounded()))
    }

    private var itineraryResolutionKey: String {
        guard let selectedTripID,
              let trip = store.myTrips.first(where: { $0.id == selectedTripID }),
              let itinerary = trip.itinerary else { return "none" }
        let stops = itinerary.days.flatMap(\.stops).map { stop in
            "\(stop.id.uuidString):\(stop.name):\(stop.area ?? ""):\(stop.kind.rawValue):\(stop.isUserPlaced)"
        }
        return "\(selectedTripID.uuidString)|\(trip.location ?? "")|\(trip.startDate?.timeIntervalSince1970 ?? 0)|\(trip.endDate?.timeIntervalSince1970 ?? 0)|\(itinerary.days.count)|\(stops.joined(separator: "|"))"
    }

    /// Includes visibility so leaving Map cancels geocoding/search work, while coming
    /// back re-runs it with the latest trip state.
    private var tripRefreshKey: String {
        "\(isActive)|\(mapRefreshRevision)|\(selectedTripID?.uuidString ?? "all")|\(store.myTrips.map { "\($0.id.uuidString):\($0.name):\($0.location ?? "")" }.joined(separator: "|"))"
    }

    private var activeItineraryResolutionKey: String {
        isActive ? "\(mapRefreshRevision)|\(itineraryResolutionKey)|day:\(selectedItineraryDay)" : "inactive"
    }

    /// A string that changes whenever the focus coordinate does, so `onChange` can
    /// recenter once the async POI search refines the city-center fallback.
    private var coordinateKey: String? {
        guard let c = mapModel.focus?.coordinate else { return nil }
        return "\(c.latitude),\(c.longitude)"
    }

    var body: some View {
        // Keep the expensive Map surface and its tile/rendering state alive after the
        // first visit. The parent tab container already hides and disables inactive tabs;
        // `isActive` below only controls network work.
        mapSurface
        .sheet(item: $detailPlace) { place in
            PlaceDetailSheet(
                place: place,
                isSaved: savedBinding(for: place),
                onAddToItinerary: { itineraryPlace = place }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSavedList) {
            SavedPlacesSheet(
                places: savedLayerPlaces,
                onSelect: showSavedPlace,
                onRemove: removeSavedPlace
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $itineraryPlace) { place in
            AddPlaceToItinerarySheet(place: place)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $correctingStop) { stop in
            ItineraryStopEditorView(
                stop: stop,
                currencyCode: selectedTripID.flatMap { store.trip($0) }?.currencyCode ?? "USD",
                locationHint: selectedTripID.flatMap { store.trip($0) }?.location
            ) { updated in
                replaceSelectedDayStop(updated)
            }
        }
        .sheet(item: $expenseDetail) { pin in
            NavigationStack {
                ExpenseDetailView(tripID: pin.trip.id, expense: pin.expense)
            }
        }
        .sheet(item: $expenseDraft) { draft in
            AddExpenseView(
                tripID: draft.tripID,
                prefillTitle: draft.place.name,
                prefillLocation: ExpenseLocation(
                    name: draft.place.name,
                    address: draft.place.addressText,
                    latitude: draft.place.coordinate.latitude,
                    longitude: draft.place.coordinate.longitude
                )
            )
        }
        .sheet(isPresented: $showsFocusDetail) {
            FocusDetailSheet { item, destination in
                mapModel.showOnMap(item, in: destination)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mapModel.navigateRequest) { recenterOnFocus(force: true) }
        .onChange(of: coordinateKey) { recenterOnFocus() }
        // A curated tap can occur before the Map tab has been mounted for the first
        // time. `onChange` alone then has no prior value to compare; this task runs
        // once the active Map view exists, guaranteeing that the pin is centered.
        .task(id: mapModel.navigateRequest) {
            guard isActive, mapModel.focus != nil else { return }
            await Task.yield()
            recenterOnFocus(force: true)
            await resolveCuratedCompanionPlaces()
        }
        .task(id: tripRefreshKey) {
            guard isActive else { return }
            initializeTripSelectionIfNeeded()
            fitTripCamera()
            await refreshTripDestinations()
        }
        .task(id: "\(tripRefreshKey)|feed:\(showsFeedPlaces)") {
            guard isActive else { return }
            await refreshFeedPins()
        }
        .task(id: activeItineraryResolutionKey) {
            guard isActive else { return }
            resolvedStopPreviews = [:]
            fitTripCamera()
            await resolveMissingItineraryCoordinates()
        }
        .task(id: isActive) {
            if isActive { restoreCachedSearchIfNeeded() }
        }
        .onChange(of: searchQuery) { _, query in
            guard isSearchFocused else { return }
            searchCompleter.update(query: query, region: visibleRegion)
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { searchCompleter.update(query: searchQuery, region: visibleRegion) }
            else { searchCompleter.clear() }
        }
        .onChange(of: userLocationKey) {
            guard let coordinate = locationManager.coordinate else { return }
            userHasMovedMap = false
            applyCamera(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
            ))
        }
    }

    private var mapSurface: some View {
        Map(position: $position, selection: $selectedPlaceID) {
            ForEach(clusteredVisiblePlaces) { cluster in
                if cluster.places.count == 1, let place = cluster.places.first {
                    Annotation(place.name, coordinate: place.coordinate) {
                        CategoryPin(
                            icon: place.category.icon,
                            isSelected: place.id == selectedPlaceID
                        )
                    }
                    .tag(place.id)
                } else {
                    Annotation("\(cluster.places.count) places", coordinate: cluster.coordinate) {
                        Button {
                            userHasMovedMap = false
                            fitCamera(to: cluster.places.map(\.coordinate), force: true)
                        } label: {
                            Text(verbatim: "\(cluster.places.count)")
                                .font(.app(.caption, .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.indigo, in: .circle)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Zoom into \(cluster.places.count) places"))
                    }
                }
            }
            ForEach(sharedTripPlaces) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    CategoryPin(icon: "person.2.fill", isSelected: place.id == selectedPlaceID)
                }
                .tag(place.id)
            }
            ForEach(curatedCompanionPlaces) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    CategoryPin(icon: place.category.icon, isSelected: place.id == selectedPlaceID)
                }
                .tag(place.id)
            }
            ForEach(tripDestinations) { destination in
                Marker(destination.tripName, systemImage: "suitcase.rolling.fill", coordinate: destination.coordinate)
                    .tint(.indigo)
            }
            ForEach(expensePins) { pin in
                Annotation(pin.expense.title, coordinate: pin.coordinate) {
                    ExpenseMapMarker(
                        amount: pin.expense.amount,
                        currencyCode: pin.trip.currencyCode,
                        isSelected: pin.id == selectedPlaceID
                    )
                }
                .tag(pin.id)
            }
            ForEach(feedPins) { pin in
                Annotation(pin.post.locationName ?? "Trip post", coordinate: pin.coordinate) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.app(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.teal, in: .circle)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                }
                .tag(pin.id)
            }
            UserAnnotation()
            if detailedRouteCoordinates.count > 1 {
                MapPolyline(coordinates: detailedRouteCoordinates)
                    .stroke(.indigo, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            } else if itineraryMapStops.count > 1 {
                MapPolyline(coordinates: itineraryMapStops.map(\.coordinate))
                    .stroke(.indigo.opacity(0.8), style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [7, 6]
                    ))
            }
            ForEach(itineraryMapStops) { item in
                Annotation(item.stop.name, coordinate: item.coordinate) {
                    NumberedItineraryPin(
                        number: item.number,
                        kind: item.stop.kind,
                        quality: item.stop.mapLocationQuality
                    )
                }
            }
            if let focus = mapModel.focus {
                Marker(focus.title, coordinate: focus.coordinate)
                    .tint(Color.accentColor)
            }
        }
        .mapStyle(mapStyle == .satellite ? .imagery : .standard(elevation: .flat, emphasis: mapStyle == .muted ? .muted : .automatic))
        .ignoresSafeArea(edges: .bottom)
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            let wasProgrammatic = isApplyingCameraUpdate
            isApplyingCameraUpdate = false
            if hasObservedInitialCamera, !wasProgrammatic {
                userHasMovedMap = true
            }
            hasObservedInitialCamera = true
            if activeCategory != nil, !isSearching, !places.isEmpty, !showsSearchThisArea {
                showsSearchThisArea = true
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topControls
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeCategory)
                .animation(.easeInOut(duration: 0.2), value: showsSearchThisArea)
        }
        .overlay(alignment: .trailing) {
            if userHasMovedMap, selectedTripID != nil, mapModel.focus == nil {
                Button {
                    userHasMovedMap = false
                    fitTripCamera(force: true)
                } label: {
                    Image(systemName: "scope")
                        .font(.app(.body, .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.trailing, 14)
                .offset(y: 55)
                .accessibilityLabel("Recenter trip")
            }
        }
        .overlay(alignment: .bottom) {
            bottomCard
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedPlaceID)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mapModel.focus != nil)
        }
        .overlay {
            if selectedTripID == nil, places.isEmpty, tripDestinations.isEmpty, sharedTripPlaces.isEmpty,
               mapModel.focus == nil, activeCategory == nil {
                coldStartCard
            }
        }
        .onAppear { recenterOnFocus(force: true, animated: false) }
    }

    // MARK: Floating top controls

    private var coldStartCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "map.fill")
                .font(.app(.title2))
                .foregroundStyle(.tint)
            Text("Where should we explore?")
                .font(.app(.headline, .semibold))
            Text("Jump to a trip, search a city, or find places around you.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if let trip = store.myTrips.first {
                    Button("Jump to \(trip.name)") { selectTrip(trip.id) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Near me") { locationManager.locate() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(maxWidth: 310)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding()
    }

    /// Back pill (when arriving from Explore), the "Exploring:" pill, the category
    /// chip rail, and the "Search this area" button — all floating over the map.
    private var topControls: some View {
        VStack(spacing: 10) {
            HStack {
                if mapModel.focus != nil {
                    Button {
                        let destinationTab = mapModel.originTab
                        mapModel.clearFocus()
                        var transaction = SwiftUI.Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            selectedTab = destinationTab
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.app(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                Spacer()

                Menu {
                    Button {
                        selectTrip(nil)
                    } label: {
                        if selectedTripID == nil { Label("All trips", systemImage: "checkmark") }
                        else { Text("All trips") }
                    }
                    ForEach(store.myTrips) { trip in
                        Button {
                            selectTrip(trip.id)
                        } label: {
                            if selectedTripID == trip.id { Label(trip.name, systemImage: "checkmark") }
                            else { Text(trip.name) }
                        }
                    }
                } label: {
                    Label(selectedTripName, systemImage: "suitcase.rolling")
                        .font(.app(.subheadline, .semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                if let selectedTripID, selectedItinerary != nil {
                    Button {
                        mapModel.openItineraryInExplore(selectedTripID)
                        var transaction = SwiftUI.Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            selectedTab = .explore
                        }
                    } label: {
                        Label("Explore", systemImage: "arrow.up.forward.app")
                            .font(.app(.caption, .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityLabel(Text("Open \(selectedTripName) in Explore"))
                }
            }
            .overlay {
                if let focus = mapModel.focus {
                    Text("Exploring: \(focus.destination.city)")
                        .font(.app(.subheadline, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                }
            }

            searchBar

            if isSearchFocused, !searchCompleter.suggestions.isEmpty {
                mapSearchSuggestions
            } else if isSearchFocused, searchQuery.isEmpty, !recentSearches.isEmpty {
                recentSearchChips
            }

            if let category = activeCategory {
                exploringPill(category)
            } else {
                categoryChips
            }

            if showsSearchThisArea, activeCategory != nil {
                Button {
                    startCategorySearch()
                } label: {
                    Label("Search this area", systemImage: "arrow.clockwise")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.85), in: .capsule)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…")
                        .font(.app(.caption, .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }

            if let searchFeedback {
                Label(searchFeedback, systemImage: "wifi.exclamationmark")
                    .font(.app(.caption, .medium))
                    .foregroundStyle(Theme.negative)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .readableSurface(cornerRadius: 14)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Wanderlog's "Exploring: Restaurants ✕" pill shown while a category is active.
    private func exploringPill(_ category: MapCategory) -> some View {
        HStack(spacing: 8) {
            Text("Exploring:")
                .font(.app(.subheadline, .bold))
            Text(category.title)
                .font(.app(.subheadline))
            Button(action: clearCategory) {
                Image(systemName: "xmark")
                    .font(.app(.caption, .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop exploring \(category.title)"))

            Divider().frame(height: 18)

            Button {
                openNowOnly.toggle()
                startCategorySearch()
            } label: {
                Label("Open now", systemImage: openNowOnly ? "clock.badge.checkmark.fill" : "clock")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(openNowOnly ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    locationManager.locate()
                } label: {
                    Label("Near me", systemImage: "location.fill")
                        .font(.app(.subheadline, .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Menu {
                    Button {
                        showsSavedPlaces.toggle()
                        if showsSavedPlaces { fitSavedPlaces() }
                    } label: {
                        Label("Saved places", systemImage: showsSavedPlaces ? "checkmark" : "bookmark")
                    }
                    Button("View saved list", systemImage: "list.bullet") { showsSavedList = true }
                    Button {
                        showsSpending.toggle()
                        selectedPlaceID = nil
                        if showsSpending {
                            userHasMovedMap = false
                            fitCamera(to: expensePins.map(\.coordinate), force: true)
                        }
                    } label: {
                        Label("Spending", systemImage: showsSpending ? "checkmark" : "dollarsign.circle")
                    }
                    if selectedTripID != nil {
                        Button {
                            showsTripPlaces.toggle()
                            selectedPlaceID = nil
                            if showsTripPlaces {
                                userHasMovedMap = false
                                fitTripCamera(force: true)
                            }
                        } label: {
                            Label("Shared trip places", systemImage: showsTripPlaces ? "checkmark" : "person.2")
                        }
                        Button {
                            showsFeedPlaces.toggle()
                            selectedPlaceID = nil
                        } label: {
                            Label("Trip feed places", systemImage: showsFeedPlaces ? "checkmark" : "photo")
                        }
                    }
                    Menu("Map style", systemImage: mapStyle.icon) {
                        ForEach(TripMapStyle.allCases) { style in
                            Button {
                                mapStyle = style
                            } label: {
                                if mapStyle == style { Label(style.title, systemImage: "checkmark") }
                                else { Label(style.title, systemImage: style.icon) }
                            }
                        }
                    }
                } label: {
                    Label("Layers & Filters", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.app(.subheadline, .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                ForEach(MapCategory.discoveryCases) { category in
                    Button {
                        activeCategory = category
                        startCategorySearch()
                    } label: {
                        Label(category.title, systemImage: category.icon)
                            .font(.app(.subheadline, .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(.horizontal)
        }
        .padding(.horizontal, -16)
    }

    private var itineraryControls: some View {
        HStack(spacing: 8) {
            if isResolvingItineraryLocations {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Locating…").font(.app(.caption2, .medium))
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button {
                    showsItineraryPath.toggle()
                    if showsItineraryPath { fitTripCamera(force: true) }
                } label: {
                    Label(showsItineraryPath ? "Hide route" : "Show route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }

                if itineraryMapStops.count > 2 {
                    Button {
                        Task { await optimizeRouteOrder() }
                    } label: {
                        Label(optimizedStopIDs.isEmpty ? "Optimize stop order" : "Route optimized", systemImage: "arrow.triangle.swap")
                    }
                    .disabled(isOptimizingRoute)
                }

                if itineraryMapStops.count > 1 {
                    Button {
                        Task { await loadDetailedRoute() }
                    } label: {
                        Label(detailedRouteCoordinates.isEmpty ? "Load walking route" : "Walking route ready", systemImage: "figure.walk")
                    }
                    .disabled(isLoadingDetailedRoute)
                }
            } label: {
                Label("Route", systemImage: "ellipsis.circle")
                    .font(.app(.caption2, .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var spendingControls: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Everyone") {
                    spendingPayerID = nil
                    selectedPlaceID = nil
                }
                ForEach(scopedMembers) { member in
                    Button(member.id == store.currentUser.id ? "You" : member.name) {
                        spendingPayerID = member.id
                        selectedPlaceID = nil
                    }
                }
            } label: {
                Label(spendingPayerName, systemImage: "person.crop.circle")
                    .font(.app(.caption, .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)

            Menu {
                ForEach(SpendingDateFilter.allCases) { filter in
                    Button {
                        spendingDateFilter = filter
                        selectedPlaceID = nil
                    } label: {
                        if spendingDateFilter == filter { Label(filter.title, systemImage: "checkmark") }
                        else { Text(filter.title) }
                    }
                }
            } label: {
                Label(spendingDateFilter.title, systemImage: "calendar")
                    .font(.app(.caption, .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: recentSearchesData)) ?? []
    }

    private var recentSearchChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(recentSearches, id: \.self) { query in
                    Button {
                        searchQuery = query
                        startTextSearch()
                    } label: {
                        Label(query, systemImage: "clock.arrow.circlepath")
                            .font(.app(.caption, .medium))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        }
    }

    private var mapSearchSuggestions: some View {
        VStack(spacing: 0) {
            ForEach(Array(searchCompleter.suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    selectSearchSuggestion(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.indigo)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: suggestion.title)
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(verbatim: suggestion.subtitle)
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if index < searchCompleter.suggestions.count - 1 { Divider() }
            }
        }
        .readableSurface(cornerRadius: 16)
    }

    private var spendingPayerName: String {
        guard let spendingPayerID else { return "Everyone" }
        if spendingPayerID == store.currentUser.id { return "You" }
        return scopedTrips.flatMap(\.members).first { $0.id == spendingPayerID }?.name ?? "Payer"
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places or addresses", text: $searchQuery)
                .font(.app(.subheadline))
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit { isSearchFocused = false; startTextSearch() }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            if !store.userProfile.savedMapPlaces.isEmpty {
                Button {
                    showsSavedList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View saved places list")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: Bottom card

    @ViewBuilder
    private var bottomCard: some View {
        if let pin = selectedExpensePin {
            ExpenseMapCard(
                pin: pin,
                payerName: pin.trip.members.first { $0.id == pin.expense.payerID }?.name ?? "Unknown",
                onDetails: { expenseDetail = pin },
                onClose: { selectedPlaceID = nil }
            )
            .padding(.horizontal)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let pin = selectedFeedPin {
            FeedMapCard(pin: pin, onClose: { selectedPlaceID = nil })
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let place = selectedPlace {
            PlaceCard(
                place: place,
                isSaved: savedBinding(for: place),
                onAddToItinerary: { itineraryPlace = place },
                onCreateExpense: { startExpense(at: place) },
                onSaveToTrip: { savePlaceToSelectedTrip(place) },
                canSaveToTrip: selectedTripID != nil,
                onDirections: { place.mapItem.openInMaps() },
                onDetails: { detailPlace = place },
                onClose: { selectedPlaceID = nil }
            )
            .padding(.horizontal)
            .padding(.bottom, 4) // The overlay already respects the dock's safe-area inset.
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let focus = mapModel.focus {
            FocusPlaceCard(
                focus: focus,
                onAddToItinerary: {
                    itineraryPlace = mapPlace(for: focus)
                },
                onCreateExpense: { startExpense(at: mapPlace(for: focus)) },
                onSaveToTrip: { savePlaceToSelectedTrip(mapPlace(for: focus)) },
                canSaveToTrip: selectedTripID != nil,
                onDirections: { focus.routableMapItem.openInMaps() },
                onDetails: { showsFocusDetail = true },
                onClose: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        mapModel.clearFocus()
                    }
                }
            )
            .padding(.horizontal)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if selectedTripID != nil, selectedItinerary != nil {
            tripMapDrawer
                .padding(.horizontal)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var tripMapDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.app(.caption2, .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 26, height: 26)
                    .background(Color.indigo.opacity(0.1), in: .circle)

                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: selectedTripName)
                        .font(.app(.subheadline, .semibold))
                        .lineLimit(1)
                    Text("Day \(selectedItineraryDay + 1)  ·  \(locatedStopCount)/\(selectedDayStops.count) pinned")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if let stop = selectedDayStops.first(where: {
                    $0.mapLocationQuality == .missing || $0.mapLocationQuality == .review
                }) {
                    Button { correctingStop = stop } label: {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.app(.caption, .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Fix a stop location")
                }

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        isTripDrawerExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isTripDrawerExpanded ? "chevron.down" : "chevron.up")
                        .font(.app(.caption2, .bold))
                        .frame(width: 28, height: 28)
                        .background(Theme.fieldBackground, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTripDrawerExpanded ? "Collapse trip controls" : "Expand trip controls")
            }

            if isTripDrawerExpanded {
                HStack(spacing: 8) {
                    if let itinerary = selectedItinerary, itinerary.days.count > 1 {
                        Menu {
                            ForEach(itinerary.days.indices, id: \.self) { index in
                                Button {
                                    selectItineraryDay(index)
                                } label: {
                                    if index == selectedItineraryDay {
                                        Label("Day \(index + 1)", systemImage: "checkmark")
                                    } else {
                                        Text("Day \(index + 1)")
                                    }
                                }
                            }
                        } label: {
                            Label("Day \(selectedItineraryDay + 1)", systemImage: "calendar")
                                .font(.app(.caption2, .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if let summary = automaticAccuracySummary {
                        Label("\(summary.percent)% verified", systemImage: "checkmark.seal")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                    }

                    itineraryControls
                }

                if let stop = unreviewedAutomaticStop {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.app(.caption2))
                            .foregroundStyle(.indigo)
                        Text("Is \(stop.name) correct?")
                            .font(.app(.caption2, .medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Button("Yes") { confirmAutomaticStop(stop) }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                        Button("Fix") { correctingStop = stop }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.mini)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.indigo.opacity(0.07), in: .rect(cornerRadius: 10))
                }

                if !selectedDayStops.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(selectedDayStops.enumerated()), id: \.element.id) { index, stop in
                                Button { correctingStop = stop } label: {
                                    HStack(spacing: 5) {
                                        Text(verbatim: "\(index + 1)")
                                            .font(.app(size: 10, weight: .bold))
                                            .frame(width: 17, height: 17)
                                            .background(stop.mapLocationQuality.tint.opacity(0.18), in: .circle)
                                        Text(verbatim: stop.name)
                                            .lineLimit(1)
                                        Image(systemName: stop.mapLocationQuality.icon)
                                            .font(.app(size: 10))
                                            .foregroundStyle(stop.mapLocationQuality.tint)
                                    }
                                    .font(.app(.caption2, .medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(Theme.fieldBackground, in: .capsule)
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }

                if showsSpending { spendingControls }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .readableSurface(cornerRadius: 16)
    }

    // MARK: Search + saved state

    /// MapKit enforces a fairly small burst allowance. Keep only one foreground
    /// place search alive so quick category taps or repeated submits cannot stack
    /// requests that are obsolete before their responses arrive.
    private func startTextSearch() {
        activePlaceSearchTask?.cancel()
        activePlaceSearchTask = Task { await runTextSearch() }
    }

    private func startCategorySearch() {
        activePlaceSearchTask?.cancel()
        activePlaceSearchTask = Task { await runCategorySearch() }
    }

    private var selectedTripName: String {
        guard let selectedTripID,
              let trip = store.myTrips.first(where: { $0.id == selectedTripID }) else {
            return "All trips"
        }
        return trip.name
    }

    /// Free-text MapKit search biased to the visible map (or selected trip). Unlike
    /// category search this accepts venues, cities, and full addresses.
    private func runTextSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchFeedback = nil
        selectedPlaceID = nil
        activeCategory = nil
        showsSearchThisArea = false

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let visibleRegion { request.region = visibleRegion }
        let result = await MapLookupPacer.shared.perform {
            try await MKLocalSearch(request: request).start().mapItems
        }
        guard let result else { return }
        guard case .success(let items) = result else {
            guard !Task.isCancelled else { return }
            isSearching = false
            searchFeedback = "Couldn't search right now. Check your connection and try again."
            return
        }
        guard !Task.isCancelled,
              query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        applyPlaceSearchResults(items, query: query)
    }

    private func selectSearchSuggestion(_ suggestion: MKLocalSearchCompletion) {
        searchQuery = suggestion.title
        isSearchFocused = false
        searchCompleter.clear()
        activePlaceSearchTask?.cancel()
        activePlaceSearchTask = Task { await runCompletionSearch(suggestion) }
    }

    private func runCompletionSearch(_ suggestion: MKLocalSearchCompletion) async {
        let query = suggestion.title
        isSearching = true
        searchFeedback = nil
        selectedPlaceID = nil
        activeCategory = nil
        let request = MKLocalSearch.Request(completion: suggestion)
        let result = await MapLookupPacer.shared.perform {
            try await MKLocalSearch(request: request).start().mapItems
        }
        guard !Task.isCancelled, searchQuery == query else { return }
        guard let result, case .success(let items) = result else {
            isSearching = false
            searchFeedback = "Couldn't search right now. Check your connection and try again."
            return
        }
        applyPlaceSearchResults(items, query: query)
    }

    private func applyPlaceSearchResults(_ items: [MKMapItem], query: String) {
        places = items.prefix(30).map { MapPlace(mapItem: $0, category: .search) }
        if places.isEmpty,
           let cache = try? JSONDecoder().decode(MapSearchCache.self, from: lastSearchCacheData),
           cache.query.normalizedForSearch == query.normalizedForSearch {
            places = cache.places.map { MapPlace(saved: $0) }
        } else if !places.isEmpty {
            rememberSearch(query)
            cacheSearch(query, places: places)
        }
        isSearching = false
        if let first = places.first {
            selectedPlaceID = first.id
            applyCamera(MKCoordinateRegion(
                center: first.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
            ))
        } else {
            searchFeedback = "No places matched “\(query)”. Try a broader name or move the map."
        }
    }

    /// Search the visible region for the active category and pin the results.
    private func runCategorySearch() async {
        guard let category = activeCategory else { return }
        let region = visibleRegion ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        if !isSearching { isSearching = true }
        if showsSearchThisArea { showsSearchThisArea = false }
        if selectedPlaceID != nil { selectedPlaceID = nil }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = openNowOnly ? "\(category.searchQuery) open now" : category.searchQuery
        request.region = region
        request.resultTypes = .pointOfInterest
        let result = await MapLookupPacer.shared.perform {
            try await MKLocalSearch(request: request).start().mapItems
        }
        guard let result else { return }
        guard case .success(let items) = result else {
            guard !Task.isCancelled else { return }
            isSearching = false
            searchFeedback = "Couldn't load nearby places. Check your connection and try again."
            return
        }

        guard !Task.isCancelled, category == activeCategory else { return }
        places = items.prefix(20).map { MapPlace(mapItem: $0, category: category) }
        isSearching = false
        searchFeedback = places.isEmpty ? "No nearby \(category.title.lowercased()) matched this area." : nil
    }

    private func clearCategory() {
        activePlaceSearchTask?.cancel()
        activePlaceSearchTask = nil
        isSearching = false
        if activeCategory != nil { activeCategory = nil }
        if !places.isEmpty { places = [] }
        if selectedPlaceID != nil { selectedPlaceID = nil }
        if showsSearchThisArea { showsSearchThisArea = false }
        openNowOnly = false
        searchFeedback = nil
    }

    private func rememberSearch(_ query: String) {
        var searches = recentSearches.filter { $0.localizedCaseInsensitiveCompare(query) != .orderedSame }
        searches.insert(query, at: 0)
        recentSearchesData = (try? JSONEncoder().encode(Array(searches.prefix(6)))) ?? Data()
    }

    private func cacheSearch(_ query: String, places: [MapPlace]) {
        let cache = MapSearchCache(query: query, places: places.prefix(30).map(\.snapshot))
        lastSearchCacheData = (try? JSONEncoder().encode(cache)) ?? Data()
    }

    private func restoreCachedSearchIfNeeded() {
        guard places.isEmpty, mapModel.focus == nil,
              let cache = try? JSONDecoder().decode(MapSearchCache.self, from: lastSearchCacheData) else { return }
        places = cache.places.map { MapPlace(saved: $0) }
    }

    /// When Explore opens one curated stop, quietly resolve the rest of that trip's
    /// recommendations into map pins as well. Weak name matches are omitted.
    private func resolveCuratedCompanionPlaces() async {
        guard let focus = mapModel.focus else {
            curatedCompanionPlaces = []
            return
        }
        let allItems = focus.destination.places + focus.destination.restaurants
        var resolved: [MapPlace] = []
        // Companion pins are a convenience layer, not a reason to consume MapKit's
        // entire per-minute search allowance for a large curated collection.
        for item in allItems.filter({ $0.id != focus.item.id }).prefix(10) {
            guard !Task.isCancelled, mapModel.focus?.destination.id == focus.destination.id else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "\(item.name), \(focus.destination.city), \(focus.destination.country)"
            request.region = MKCoordinateRegion(
                center: focus.destination.coordinate,
                latitudinalMeters: 120_000,
                longitudinalMeters: 120_000
            )
            request.resultTypes = .pointOfInterest
            let result = await MapLookupPacer.shared.perform {
                try await MKLocalSearch(request: request).start().mapItems
            }
            guard let result, case .success(let candidates) = result,
                  let match = candidates.max(by: {
                      itineraryNameScore($0.name ?? "", expected: item.name)
                          < itineraryNameScore($1.name ?? "", expected: item.name)
                  }),
                  itineraryNameScore(match.name ?? "", expected: item.name) >= 60 else { continue }
            let category: MapCategory = focus.destination.restaurants.contains(where: { $0.id == item.id })
                ? .restaurants : .attractions
            resolved.append(MapPlace(mapItem: match, category: category))
        }
        guard !Task.isCancelled, mapModel.focus?.destination.id == focus.destination.id else { return }
        curatedCompanionPlaces = resolved
    }

    private func savedBinding(for place: MapPlace) -> Binding<Bool> {
        Binding(
            get: {
                store.userProfile.savedPlaceKeys.contains(place.saveKey)
                    || store.userProfile.savedMapPlaces.contains { $0.key == place.saveKey }
            },
            set: { isSaved in
                var keys = Set(store.userProfile.savedPlaceKeys)
                var snapshots = store.userProfile.savedMapPlaces
                if isSaved {
                    keys.insert(place.saveKey)
                    if let index = snapshots.firstIndex(where: { $0.key == place.saveKey }) {
                        snapshots[index] = place.snapshot
                    } else {
                        snapshots.append(place.snapshot)
                    }
                } else {
                    keys.remove(place.saveKey)
                    snapshots.removeAll { $0.key == place.saveKey }
                    if selectedPlaceID == place.id, showsSavedPlaces { selectedPlaceID = nil }
                }
                store.updateSavedPlaces(mapKeys: keys.sorted(), mapPlaces: snapshots)
            }
        )
    }

    private func removeSavedPlace(_ place: MapPlace) {
        var keys = Set(store.userProfile.savedPlaceKeys)
        keys.remove(place.saveKey)
        let snapshots = store.userProfile.savedMapPlaces.filter { $0.key != place.saveKey }
        store.updateSavedPlaces(mapKeys: keys.sorted(), mapPlaces: snapshots)
        if selectedPlaceID == place.id { selectedPlaceID = nil }
    }

    private func showSavedPlace(_ place: MapPlace) {
        showsSavedList = false
        showsSavedPlaces = true
        selectedPlaceID = place.id
        userHasMovedMap = false
        applyCamera(MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
        ))
    }

    private func mapPlace(for focus: MapFocus) -> MapPlace {
        MapPlace(mapItem: focus.routableMapItem, category: .search, savedAddress: focus.addressText)
    }

    private func fitSavedPlaces() {
        userHasMovedMap = false
        fitCamera(to: savedLayerPlaces.map(\.coordinate), force: true)
    }

    private func startExpense(at place: MapPlace) {
        guard let tripID = selectedTripID ?? store.myTrips.first?.id else { return }
        expenseDraft = MapExpenseDraft(tripID: tripID, place: place)
    }

    private func savePlaceToSelectedTrip(_ place: MapPlace) {
        guard let tripID = selectedTripID, var trip = store.trip(tripID) else { return }
        if trip.sharedMapPlaces.contains(where: { $0.key == place.saveKey }) {
            trip.sharedMapPlaces.removeAll { $0.key == place.saveKey }
        } else {
            trip.sharedMapPlaces.append(place.snapshot)
        }
        store.updateTrip(trip)
        showsTripPlaces = true
    }

    /// Greedy nearest-neighbor ordering is intentionally local and immediate. Detailed
    /// road geometry is a separate on-demand action, avoiding the previous O(n²) burst
    /// of directions requests every time the traveler tapped Optimize.
    private func optimizeRouteOrder() async {
        guard optimizedStopIDs.isEmpty else {
            optimizedStopIDs = []
            detailedRouteCoordinates = []
            return
        }
        isOptimizingRoute = true
        defer { isOptimizingRoute = false }
        var remaining = itineraryMapStops
        guard let first = remaining.first else { return }
        var ordered = [first]
        remaining.removeFirst()
        while let current = ordered.last, !remaining.isEmpty {
            guard !Task.isCancelled else { return }
            var bestIndex = remaining.startIndex
            var bestDistance = CLLocationDistance.greatestFiniteMagnitude
            for index in remaining.indices {
                let distance = directDistance(from: current.coordinate, to: remaining[index].coordinate)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            let nextIndex = bestIndex
            ordered.append(remaining.remove(at: nextIndex))
        }
        optimizedStopIDs = ordered.map(\.stop.id)
        detailedRouteCoordinates = []
    }

    private var detailedRouteKey: String {
        let stops = itineraryMapStops.map {
            "\($0.stop.id.uuidString)@\(String(format: "%.5f,%.5f", $0.coordinate.latitude, $0.coordinate.longitude))"
        }.joined(separator: "|")
        return "\(selectedTripID?.uuidString ?? "none")|\(selectedItineraryDay)|\(stops)"
    }

    private func loadDetailedRoute() async {
        let key = detailedRouteKey
        if let cached = detailedRouteCache[key] {
            detailedRouteCoordinates = cached
            return
        }
        let stops = itineraryMapStops
        guard stops.count > 1 else { return }
        isLoadingDetailedRoute = true
        defer { isLoadingDetailedRoute = false }
        var coordinates: [CLLocationCoordinate2D] = []
        for pair in zip(stops, stops.dropFirst()) {
            guard !Task.isCancelled, key == detailedRouteKey else { return }
            let request = MKDirections.Request()
            request.source = MKMapItem(
                location: CLLocation(latitude: pair.0.coordinate.latitude, longitude: pair.0.coordinate.longitude),
                address: nil
            )
            request.destination = MKMapItem(
                location: CLLocation(latitude: pair.1.coordinate.latitude, longitude: pair.1.coordinate.longitude),
                address: nil
            )
            request.transportType = .walking
            if let route = try? await MKDirections(request: request).calculate().routes.first {
                var segment = [CLLocationCoordinate2D](
                    repeating: kCLLocationCoordinate2DInvalid,
                    count: route.polyline.pointCount
                )
                route.polyline.getCoordinates(
                    &segment,
                    range: NSRange(location: 0, length: route.polyline.pointCount)
                )
                if !coordinates.isEmpty, !segment.isEmpty { segment.removeFirst() }
                coordinates += segment
            } else {
                if coordinates.isEmpty { coordinates.append(pair.0.coordinate) }
                coordinates.append(pair.1.coordinate)
            }
        }
        guard !Task.isCancelled, key == detailedRouteKey else { return }
        detailedRouteCache[key] = coordinates
        detailedRouteCoordinates = coordinates
    }

    private func directDistance(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: source.latitude, longitude: source.longitude).distance(
            from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        )
    }

    private func refreshFeedPins() async {
        guard showsFeedPlaces,
              let tripID = selectedTripID,
              let trip = store.trip(tripID) else {
            feedPins = []
            return
        }
        isLoadingFeedPlaces = true
        defer { isLoadingFeedPlaces = false }
        guard let posts = try? await store.feedPlaces(for: tripID) else { return }
        let destination = await itineraryDestination(for: trip)
        var resolved: [FeedMapPin] = []
        for post in posts {
            guard !Task.isCancelled, selectedTripID == tripID, showsFeedPlaces else { return }
            if let location = post.location {
                resolved.append(FeedMapPin(
                    trip: trip,
                    post: post,
                    coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
                ))
            } else if let name = post.locationName {
                let stop = ItineraryStop(name: name, kind: .location)
                if let match = await bestItineraryLocation(for: stop, trip: trip, destination: destination) {
                    resolved.append(FeedMapPin(trip: trip, post: post, coordinate: match.coordinate))
                }
            }
        }
        guard !Task.isCancelled, selectedTripID == tripID, showsFeedPlaces else { return }
        feedPins = resolved
        fitTripCamera()
    }

    private func selectTrip(_ tripID: Trip.ID?) {
        guard tripID != selectedTripID else {
            mapRefreshRevision += 1
            mapModel.clearFocus()
            userHasMovedMap = false
            fitTripCamera(force: true)
            return
        }
        resolvedStopPreviews = [:]
        userHasMovedMap = false
        mapModel.clearFocus()
        curatedCompanionPlaces = []
        selectedTripID = tripID
        selectedItineraryDay = 0
        spendingPayerID = nil
        selectedPlaceID = nil
        optimizedStopIDs = []
        detailedRouteCoordinates = []
        feedPins = []
        tripDestinations = []
    }

    private func selectItineraryDay(_ index: Int) {
        guard selectedItinerary?.days.indices.contains(index) == true else { return }
        selectedItineraryDay = index
        selectedPlaceID = nil
        optimizedStopIDs = []
        detailedRouteCoordinates = []
        userHasMovedMap = false
        Task { @MainActor in
            await Task.yield()
            fitTripCamera(force: true)
        }
    }

    private func replaceSelectedDayStop(_ updated: ItineraryStop) {
        guard let tripID = selectedTripID,
              var itinerary = store.trip(tripID)?.itinerary,
              itinerary.days.indices.contains(selectedItineraryDay),
              let stopIndex = itinerary.days[selectedItineraryDay].stops.firstIndex(where: { $0.id == updated.id })
        else { return }
        let original = itinerary.days[selectedItineraryDay].stops[stopIndex]
        if original.locationSource == .automatic, updated.locationSource == .userSelected {
            let originalKey = automaticReviewKey(for: original)
            removeReviewKey(originalKey, from: &confirmedAutomaticStopsData)
            removeReviewKey(originalKey, from: &correctedAutomaticStopsData)
            if let oldCoordinate = original.coordinate, let newCoordinate = updated.coordinate,
               directDistance(from: oldCoordinate, to: newCoordinate) <= 50 {
                insertReviewKey(originalKey, into: &confirmedAutomaticStopsData)
            } else {
                insertReviewKey(originalKey, into: &correctedAutomaticStopsData)
            }
        }
        itinerary.days[selectedItineraryDay].stops[stopIndex] = updated
        resolvedStopPreviews[updated.id] = nil
        detailedRouteCoordinates = []
        store.updateItinerary(itinerary, in: tripID)
    }

    private var confirmedAutomaticStopKeys: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: confirmedAutomaticStopsData)) ?? [])
    }

    private var correctedAutomaticStopKeys: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: correctedAutomaticStopsData)) ?? [])
    }

    private func automaticReviewKey(for stop: ItineraryStop) -> String {
        guard let tripID = selectedTripID, let coordinate = stop.coordinate else { return stop.id.uuidString }
        return "\(tripID.uuidString)|\(stop.id.uuidString)|\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))"
    }

    private func confirmAutomaticStop(_ stop: ItineraryStop) {
        let key = automaticReviewKey(for: stop)
        removeReviewKey(key, from: &correctedAutomaticStopsData)
        insertReviewKey(key, into: &confirmedAutomaticStopsData)
    }

    private func insertReviewKey(_ key: String, into data: inout Data) {
        var keys = Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
        keys.insert(key)
        data = (try? JSONEncoder().encode(Array(keys.suffix(1_000)))) ?? Data()
    }

    private func removeReviewKey(_ key: String, from data: inout Data) {
        var keys = Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
        guard keys.remove(key) != nil else { return }
        data = (try? JSONEncoder().encode(Array(keys))) ?? Data()
    }

    /// Treat the first itinerary-bearing trip as the initial "current trip" so the
    /// map opens with a day route instead of requiring a hidden extra selection. Once
    /// the user chooses All trips, their choice is left alone for the rest of the view.
    private func initializeTripSelectionIfNeeded() {
        guard !hasInitializedTripSelection, !store.myTrips.isEmpty else { return }
        hasInitializedTripSelection = true
        guard selectedTripID == nil else { return }

        let now = Date()
        let itineraryTrips = store.myTrips.filter { $0.itinerary?.days.isEmpty == false }
        let current = itineraryTrips.first { trip in
            guard let start = trip.startDate, let end = trip.endDate else { return false }
            return start <= now && now <= end
        }
        selectedTripID = (current ?? itineraryTrips.first)?.id
    }

    /// Backfills and revalidates planner coordinates. Ranking is deliberately stricter
    /// than taking MapKit's first result: a weak same-region match is worse than no pin.
    /// Revalidation also repairs coordinates persisted by the original loose resolver.
    private func resolveMissingItineraryCoordinates() async {
        guard let tripID = selectedTripID,
              let trip = store.myTrips.first(where: { $0.id == tripID }),
              var itinerary = trip.itinerary else {
            isResolvingItineraryLocations = false
            return
        }

        // Older trips and trips whose dates were edited can have fewer planner days
        // than their inclusive date range. Preserve every existing day and append only
        // the missing ones so the Map day picker always covers the full trip.
        let requiredDayCount = itineraryDayCount(for: trip)
        if itinerary.days.count < requiredDayCount {
            itinerary.days.append(contentsOf: (itinerary.days.count..<requiredDayCount).map { _ in ItineraryDay() })
            store.updateItinerary(itinerary, in: tripID)
        }

        let dayIndex = min(selectedItineraryDay, max(itinerary.days.count - 1, 0))
        var validatedKeys = validatedItineraryStopKeys
        let searchableCount = itinerary.days.indices.contains(dayIndex)
            ? itinerary.days[dayIndex].stops.filter { stop in
                let hasName = !stop.name.trimmingCharacters(in: .whitespaces).isEmpty
                return hasName && (stop.coordinate == nil || !validatedKeys.contains(itineraryValidationKey(for: stop, trip: trip)))
            }.count
            : 0
        guard searchableCount > 0 else {
            isResolvingItineraryLocations = false
            if showsItineraryPath { fitTripCamera() }
            return
        }

        isResolvingItineraryLocations = true
        defer { isResolvingItineraryLocations = false }

        let destination = await itineraryDestination(for: trip)
        var validationCacheChanged = false
        guard itinerary.days.indices.contains(dayIndex) else { return }
        let jobs = itinerary.days[dayIndex].stops.indices.compactMap { index -> (Int, ItineraryStop)? in
            let stop = itinerary.days[dayIndex].stops[index]
            guard !stop.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(stop.isUserPlaced && stop.coordinate != nil) else { return nil }
            let key = itineraryValidationKey(for: stop, trip: trip)
            return stop.coordinate != nil && validatedKeys.contains(key) ? nil : (index, stop)
        }

        for offset in stride(from: 0, to: jobs.count, by: 2) {
            guard !Task.isCancelled, selectedTripID == tripID,
                  store.trip(tripID)?.location == trip.location else { return }
            let firstJob = jobs[offset]
            let firstTask = Task {
                await bestItineraryLocation(for: firstJob.1, trip: trip, destination: destination)
            }
            let secondTask: Task<ResolvedItineraryLocation?, Never>? = jobs.indices.contains(offset + 1)
                ? Task { await bestItineraryLocation(for: jobs[offset + 1].1, trip: trip, destination: destination) }
                : nil
            let firstMatch = await firstTask.value
            let secondMatch = await secondTask?.value
            var batch: [((Int, ItineraryStop), ResolvedItineraryLocation?)] = [
                (firstJob, firstMatch)
            ]
            if jobs.indices.contains(offset + 1) {
                batch.append((jobs[offset + 1], secondMatch))
            }

            var batchChanged = false
            for (job, match) in batch {
                guard let match else { continue }
                let (stopIndex, originalStop) = job
                guard itinerary.days[dayIndex].stops.indices.contains(stopIndex),
                      itinerary.days[dayIndex].stops[stopIndex].name == originalStop.name else { continue }
                let validationKey = itineraryValidationKey(for: originalStop, trip: trip)
                if validatedKeys.insert(validationKey).inserted { validationCacheChanged = true }
                var resolved = itinerary.days[dayIndex].stops[stopIndex]
                resolved.latitude = match.latitude
                resolved.longitude = match.longitude
                resolved.address = match.address
                resolved.placeIdentifier = match.placeIdentifier
                resolved.resolvedName = match.resolvedName
                resolved.resolutionConfidence = match.confidence
                resolved.locationSource = match.source
                resolved.resolutionVersion = 3
                itinerary.days[dayIndex].stops[stopIndex] = resolved
                resolvedStopPreviews[resolved.id] = resolved
                batchChanged = true
            }
            if batchChanged {
                // Save each two-stop batch so cancellation or a tab switch never throws
                // away already completed lookups.
                store.updateItinerary(itinerary, in: tripID)
                await Task.yield()
            }
        }

        if validationCacheChanged {
            validatedItineraryStopsData = (try? JSONEncoder().encode(Array(validatedKeys))) ?? Data()
        }
        fitTripCamera()
    }

    private func itineraryDayCount(for trip: Trip) -> Int {
        guard let start = trip.startDate, let end = trip.endDate else {
            return max(trip.itinerary?.days.count ?? 0, 1)
        }
        let calendar = Calendar.current
        let span = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
        return min(max(span + 1, 1), 30)
    }

    /// Resolves a stop against its own neighborhood context first, then ranks every
    /// in-region candidate by name, place category, address, proximity, and ambiguity.
    /// A weak or tied result is deliberately left unpinned for traveler review.
    private func bestItineraryLocation(
        for stop: ItineraryStop,
        trip: Trip,
        destination: ResolvedDestination?
    ) async -> ResolvedItineraryLocation? {
        let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard location.isEmpty || destination != nil else { return nil }
        if let placeIdentifier = stop.placeIdentifier,
           let item = await DestinationResolver.shared.mapItem(forPlaceIdentifier: placeIdentifier),
           destination.map({ ItineraryPinScope.isInScope(
               candidate: item.location.coordinate,
               candidateRegion: item.addressRepresentations?.regionName ?? item.address?.fullAddress,
               destination: $0
           ) }) ?? true {
            return ResolvedItineraryLocation(
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude,
                address: item.address?.fullAddress,
                resolvedName: item.name,
                placeIdentifier: item.identifier?.rawValue ?? placeIdentifier,
                confidence: 0.99,
                source: .placeIdentifier,
                resolvedAt: Date()
            )
        }
        let cacheKey = itineraryLocationCacheKey(for: stop, trip: trip)
        if let cached = resolvedItineraryCache[cacheKey],
           Date().timeIntervalSince(cached.resolvedAt) < 30 * 86_400,
           cached.confidence >= ItineraryMatchScoring.acceptanceThreshold {
            return cached
        }

        let rawArea = stop.area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var areaDestination: ResolvedDestination?
        if !rawArea.isEmpty, rawArea.normalizedForSearch != location.normalizedForSearch {
            let resolvedArea = await DestinationResolver.shared.resolve(rawArea)
            if let resolvedArea {
                if let destination {
                    if ItineraryPinScope.isInScope(
                        candidate: resolvedArea.coordinate,
                        candidateRegion: resolvedArea.regionName,
                        destination: destination
                    ) { areaDestination = resolvedArea }
                } else {
                    areaDestination = resolvedArea
                }
            }
        }
        let searchAnchor = areaDestination ?? destination
        let searchContext = areaDestination == nil ? location : rawArea
        let searchRegion = searchAnchor.map {
            itinerarySearchRegion(around: $0, meters: areaDestination == nil ? 180_000 : 90_000)
        }
        let nameVariants = itineraryNameVariants(stop.name)
        var searches: [String] = []
        for name in nameVariants {
            searches.append(searchContext.isEmpty ? name : "\(name), \(searchContext)")
        }
        if searchRegion != nil { searches += nameVariants }
        var seenSearches: Set<String> = []
        searches = searches.filter { seenSearches.insert($0.normalizedForSearch).inserted }

        var candidates: [(score: Double, nameScore: Double, contextScore: Double, categoryMatches: Bool, item: MKMapItem)] = []
        var seen: Set<String> = []
        for search in searches.prefix(3) {
            guard !Task.isCancelled else { return nil }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = search
            if let searchRegion {
                request.region = searchRegion
                request.regionPriority = .required
            }
            configureItineraryRequest(request, for: stop.kind)
            let result = await MapLookupPacer.shared.perform {
                try await MKLocalSearch(request: request).start().mapItems
            }
            guard let result, case .success(let items) = result else { continue }
            for item in items.prefix(15) {
                let coordinate = item.location.coordinate
                let key = "\((item.name ?? "").normalizedForSearch)|\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))"
                guard seen.insert(key).inserted else { continue }
                // Geography is a gate, not a tiebreaker: a same-named venue outside the
                // trip's part of the world never becomes this stop's pin.
                if let destination, !ItineraryPinScope.isInScope(
                    candidate: coordinate,
                    candidateRegion: item.addressRepresentations?.regionName ?? item.address?.fullAddress,
                    destination: destination
                ) { continue }
                let nameScore = nameVariants.map {
                    itineraryNameScore(item.name ?? "", expected: $0)
                }.max() ?? 0
                let categoryMatches = itineraryCategoryMatches(item, kind: stop.kind)
                let contextScore = itineraryContextScore(
                    item,
                    tripLocation: searchContext,
                    destination: searchAnchor
                )
                let score = nameScore + contextScore + (categoryMatches ? 12 : 0)
                candidates.append((score, nameScore, contextScore, categoryMatches, item))
            }
        }

        let ranked = candidates.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.nameScore >= 60 else { return nil }
        let runnerUpMargin = best.score - (ranked.dropFirst().first?.score ?? best.score - 28)
        let confidence = ItineraryMatchScoring.confidence(
            nameScore: best.nameScore,
            contextScore: best.contextScore,
            categoryMatches: best.categoryMatches,
            runnerUpMargin: runnerUpMargin
        )
        guard confidence >= ItineraryMatchScoring.acceptanceThreshold else { return nil }
        let result = ResolvedItineraryLocation(
            latitude: best.item.location.coordinate.latitude,
            longitude: best.item.location.coordinate.longitude,
            address: best.item.address?.fullAddress,
            resolvedName: best.item.name,
            placeIdentifier: best.item.identifier?.rawValue,
            confidence: confidence,
            source: .automatic,
            resolvedAt: Date()
        )
        cacheResolvedItineraryLocation(result, for: cacheKey)
        return result
    }

    private var resolvedItineraryCache: [String: ResolvedItineraryLocation] {
        (try? JSONDecoder().decode([String: ResolvedItineraryLocation].self, from: resolvedItineraryCacheData)) ?? [:]
    }

    private func itineraryLocationCacheKey(for stop: ItineraryStop, trip: Trip) -> String {
        "v3|\(stop.name.normalizedForSearch)|\((stop.area ?? "").normalizedForSearch)|\((trip.location ?? "").normalizedForSearch)|\(stop.kind.rawValue)"
    }

    private func cacheResolvedItineraryLocation(_ location: ResolvedItineraryLocation, for key: String) {
        var cache = resolvedItineraryCache
        cache[key] = location
        if cache.count > 300 {
            for oldKey in cache.sorted(by: { $0.value.resolvedAt < $1.value.resolvedAt }).prefix(cache.count - 300).map(\.key) {
                cache[oldKey] = nil
            }
        }
        resolvedItineraryCacheData = (try? JSONEncoder().encode(cache)) ?? Data()
    }

    private func itineraryNameVariants(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = [trimmed]
        for separator in [" + ", " & ", " or ", " / "] {
            values += trimmed.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        for suffix in [" at night", " at sunset", " day trip", " walking tour", " walk", " loop"] {
            if trimmed.lowercased().hasSuffix(suffix) {
                values.append(String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0.normalizedForSearch).inserted }
    }

    private func configureItineraryRequest(_ request: MKLocalSearch.Request, for kind: ItineraryStopKind) {
        switch kind {
        case .restaurant:
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket,
            ])
        case .activity:
            request.resultTypes = [.pointOfInterest, .physicalFeature]
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .amusementPark, .aquarium, .beach, .campground, .fitnessCenter,
                .marina, .movieTheater, .museum, .nationalPark, .nightlife,
                .park, .stadium, .theater, .winery, .zoo,
            ])
        case .location:
            request.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        }
    }

    private func itineraryCategoryMatches(_ item: MKMapItem, kind: ItineraryStopKind) -> Bool {
        guard let raw = item.pointOfInterestCategory?.rawValue.normalizedForSearch else {
            return kind == .location
        }
        let isFood = ["restaurant", "cafe", "bakery", "brewery", "winery", "food market"]
            .contains { raw.contains($0) }
        switch kind {
        case .restaurant: return isFood
        case .activity: return !isFood
        case .location: return true
        }
    }

    private var validatedItineraryStopKeys: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: validatedItineraryStopsData)) ?? [])
    }

    /// The version prefix retires every key written by the ungated resolver, so stops
    /// it "validated" onto the wrong continent are checked once more against the scope
    /// gate instead of being trusted forever.
    private func itineraryValidationKey(for stop: ItineraryStop, trip: Trip) -> String {
        let location = (trip.location ?? "").normalizedForSearch
        return "v3|\(trip.id.uuidString)|\(stop.id.uuidString)|\(stop.name.normalizedForSearch)|\((stop.area ?? "").normalizedForSearch)|\(stop.kind.rawValue)|\(location)"
    }

    private func itineraryNameScore(_ candidateName: String, expected: String) -> Double {
        let candidate = candidateName.normalizedForSearch
        let expected = expected.normalizedForSearch
        guard !candidate.isEmpty, !expected.isEmpty else { return 0 }
        if candidate == expected { return 100 }

        let candidateCompact = candidate.replacingOccurrences(of: " ", with: "")
        let expectedCompact = expected.replacingOccurrences(of: " ", with: "")
        if candidateCompact == expectedCompact { return 96 }
        if min(candidateCompact.count, expectedCompact.count) >= 5,
           candidateCompact.contains(expectedCompact) || expectedCompact.contains(candidateCompact) {
            return 82
        }

        let candidateTokens = Set(candidate.searchTokens)
        let expectedTokens = Set(expected.searchTokens)
        guard !expectedTokens.isEmpty else { return 0 }
        let overlap = candidateTokens.intersection(expectedTokens).count
        return (Double(overlap) / Double(expectedTokens.count)) * 65
    }

    /// Only ranks candidates the scope gate already accepted, so distance here is a
    /// preference (the venue in town over the one two hours out), never a veto.
    private func itineraryContextScore(
        _ item: MKMapItem,
        tripLocation: String,
        destination: ResolvedDestination?
    ) -> Double {
        var score = 0.0
        let address = (item.address?.fullAddress ?? "").normalizedForSearch
        let locationTokens = Set(tripLocation.searchTokens)
        if !locationTokens.isEmpty {
            let addressTokens = Set(address.searchTokens)
            score += Double(addressTokens.intersection(locationTokens).count) * 7
        }

        if let destination {
            score += ItineraryPinScope.proximityScore(
                candidate: item.location.coordinate,
                destination: destination.coordinate
            )
        }
        return score
    }

    /// The trip's destination as a map location plus the country MapKit puts it in —
    /// the anchor every planner pin is judged against.
    private func itineraryDestination(for trip: Trip) async -> ResolvedDestination? {
        guard let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty else { return nil }
        return await DestinationResolver.shared.resolve(location)
    }

    /// The search bias around a destination. Narrower than `ItineraryPinScope.radius`
    /// on purpose: this only tilts MapKit's ranking toward the trip, while the scope
    /// gate decides what may actually be kept.
    private func itinerarySearchRegion(around destination: ResolvedDestination, meters: CLLocationDistance = 180_000) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: destination.coordinate,
            latitudinalMeters: meters,
            longitudinalMeters: meters
        )
    }

    /// Resolves each selected trip's string destination with MapKit and fits all
    /// resulting pins. A missing/ambiguous destination simply omits that trip.
    private func refreshTripDestinations() async {
        let requestedTripID = selectedTripID
        let trips = requestedTripID.map { id in store.myTrips.filter { $0.id == id } } ?? store.myTrips
        let inputs = trips.compactMap { trip -> (Trip, String)? in
            guard let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty else { return nil }
            return (trip, location)
        }

        var resolved: [TripDestinationPin] = []
        for offset in stride(from: 0, to: inputs.count, by: 2) {
            guard !Task.isCancelled else { return }
            let firstInput = inputs[offset]
            let firstTask = Task { await DestinationResolver.shared.coordinate(for: firstInput.1) }
            let secondTask: Task<CLLocationCoordinate2D?, Never>? = inputs.indices.contains(offset + 1)
                ? Task { await DestinationResolver.shared.coordinate(for: inputs[offset + 1].1) }
                : nil
            let firstCoordinate = await firstTask.value
            let secondCoordinate = await secondTask?.value
            var batch: [((Trip, String), CLLocationCoordinate2D?)] = [
                (firstInput, firstCoordinate)
            ]
            if inputs.indices.contains(offset + 1) {
                batch.append((inputs[offset + 1], secondCoordinate))
            }
            for ((trip, location), coordinate) in batch {
                guard let coordinate else { continue }
                resolved.append(TripDestinationPin(
                    tripID: trip.id,
                    tripName: trip.name,
                    location: location,
                    coordinate: coordinate
                ))
            }
            guard !Task.isCancelled, requestedTripID == selectedTripID else { return }
        }
        guard !Task.isCancelled, requestedTripID == selectedTripID else { return }
        tripDestinations = resolved
        fitTripCamera()
    }

    /// Every async layer uses the same bounds, so the last lookup to finish cannot
    /// hide pins from another enabled trip layer. An explicit Explore focus wins.
    private func fitTripCamera(force: Bool = false) {
        guard mapModel.focus == nil, force || !userHasMovedMap else { return }
        fitCamera(to: tripDestinations.map(\.coordinate)
            + sharedTripPlaces.map(\.coordinate)
            + itineraryMapStops.map(\.coordinate)
            + feedPins.map(\.coordinate)
            + expensePins.map(\.coordinate), force: force)
    }

    private func fitCamera(to coordinates: [CLLocationCoordinate2D], force: Bool = false) {
        guard force || !userHasMovedMap, let first = coordinates.first else { return }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.45, 0.08),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.45, 0.08)
            )
        )
        applyCamera(region)
    }

    private func applyCamera(_ region: MKCoordinateRegion, animated: Bool = true) {
        cameraUpdateRevision += 1
        let revision = cameraUpdateRevision
        isApplyingCameraUpdate = true
        let update = { position = .region(region) }
        if animated { withAnimation(.easeInOut) { update() } }
        else { update() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if revision == cameraUpdateRevision { isApplyingCameraUpdate = false }
        }
    }

    /// Move the camera to the current curated focus, zoomed to a neighborhood span.
    private func recenterOnFocus(force: Bool = false, animated: Bool = true) {
        guard let focus = mapModel.focus, let key = coordinateKey else { return }
        guard force || key != lastCenteredCoordinateKey else { return }
        lastCenteredCoordinateKey = key

        userHasMovedMap = false
        applyCamera(
            MKCoordinateRegion(
                center: focus.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            ),
            animated: animated
        )
    }
}

/// A Wanderlog-style teardrop pin: dark circle with the category icon, white ring,
/// and a pointer tail. Grows and tints when selected.

import SwiftUI
import MapKit
import UIKit
import CoreLocation

private struct DirectionsModeMenu: View {
    let mapItem: MKMapItem

    var body: some View {
        Button { open(MKLaunchOptionsDirectionsModeWalking) } label: {
            Label("Walking directions", systemImage: "figure.walk")
        }
        Button { open(MKLaunchOptionsDirectionsModeTransit) } label: {
            Label("Transit directions", systemImage: "tram.fill")
        }
        Button { open(MKLaunchOptionsDirectionsModeDriving) } label: {
            Label("Driving directions", systemImage: "car.fill")
        }
    }

    private func open(_ mode: String) {
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }
}

/// The downward-pointing triangle under a `CategoryPin`.

struct SavedPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let places: [MapPlace]
    let onSelect: (MapPlace) -> Void
    let onRemove: (MapPlace) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if places.isEmpty {
                    ContentUnavailableView(
                        "No saved places",
                        systemImage: "bookmark",
                        description: Text("Save a map result and it will appear here.")
                    )
                } else {
                    List {
                        ForEach(places) { place in
                            Button {
                                dismiss()
                                onSelect(place)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: place.category.icon)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28, height: 28)
                                        .background(.tint.opacity(0.12), in: .circle)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(place.name)
                                            .font(.app(.body, .semibold))
                                            .foregroundStyle(.primary)
                                        if let address = place.addressText {
                                            Text(address)
                                                .font(.app(.caption))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { onRemove(place) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Trip/day/type picker used by every map place card. Adding a place creates a basic
/// itinerary when needed, then persists through the same shared-trip path as planner edits.
struct AddPlaceToItinerarySheet: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let place: MapPlace

    @State private var tripID: Trip.ID?
    @State private var dayIndex = 0
    @State private var kind: ItineraryStopKind = .location

    private var selectedTrip: Trip? {
        guard let tripID else { return nil }
        return store.myTrips.first { $0.id == tripID }
    }

    private var dayCount: Int {
        guard let trip = selectedTrip else { return 1 }
        if let count = trip.itinerary?.days.count, count > 0 { return count }
        guard let start = trip.startDate, let end = trip.endDate else { return 1 }
        return max((Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1, 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    Label(place.name, systemImage: place.category.icon)
                    if let address = place.addressText {
                        Text(address)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                if store.myTrips.isEmpty {
                    ContentUnavailableView(
                        "Create a trip first",
                        systemImage: "suitcase",
                        description: Text("A trip is needed before this place can be added to an itinerary.")
                    )
                } else {
                    Section("Plan") {
                        Picker("Trip", selection: $tripID) {
                            ForEach(store.myTrips) { trip in
                                Text(trip.name).tag(Optional(trip.id))
                            }
                        }
                        Picker("Day", selection: $dayIndex) {
                            ForEach(0..<dayCount, id: \.self) { index in
                                Text("Day \(index + 1)").tag(index)
                            }
                        }
                        Picker("Type", selection: $kind) {
                            ForEach(ItineraryStopKind.allCases) { kind in
                                Label(kind.label, systemImage: kind.icon).tag(kind)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to itinerary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addPlace() }
                        .disabled(selectedTrip == nil)
                }
            }
            .onAppear {
                tripID = tripID ?? store.myTrips.first?.id
                kind = place.category.itineraryKind
            }
            .onChange(of: tripID) {
                dayIndex = min(dayIndex, dayCount - 1)
            }
        }
    }

    private func addPlace() {
        guard let trip = selectedTrip else { return }
        var itinerary = trip.itinerary ?? Itinerary()
        if itinerary.days.isEmpty {
            itinerary.days = (0..<dayCount).map { _ in ItineraryDay() }
        }
        let safeDay = min(max(dayIndex, 0), itinerary.days.count - 1)
        itinerary.days[safeDay].stops.append(ItineraryStop(
            name: place.name,
            kind: kind,
            latitude: place.coordinate.latitude,
            longitude: place.coordinate.longitude,
            address: place.addressText,
            // The traveler tapped this exact pin on the map; nothing should second-guess it.
            isUserPlaced: true
        ))
        store.updateItinerary(itinerary, in: trip.id)
        dismiss()
    }
}

/// The compact bottom card for a selected search-result pin: name + category on the
/// left, a Look Around thumbnail on the right, address below, and Save / Directions
/// / Details actions — mirroring Wanderlog's place card.
struct PlaceCard: View {
    let place: MapPlace
    @Binding var isSaved: Bool
    let onAddToItinerary: () -> Void
    let onCreateExpense: () -> Void
    let onSaveToTrip: () -> Void
    let canSaveToTrip: Bool
    let onDirections: () -> Void
    let onDetails: () -> Void
    let onClose: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.app(.body))
                            .foregroundStyle(.tint)
                        Text(place.name)
                            .font(.app(.subheadline, .semibold))
                            .lineLimit(1)
                    }
                    Text(place.category.title)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    if let address = place.addressText {
                        Text(address)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                thumbnail
            }

            HStack(spacing: 8) {
                Button {
                    isSaved.toggle()
                } label: {
                    Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

                Button(action: onDirections) {
                    Text("Directions")
                        .font(.app(.subheadline, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contextMenu { DirectionsModeMenu(mapItem: place.mapItem) }

                Button(action: onDetails) {
                    Text("Details")
                        .font(.app(.subheadline, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Menu {
                    Button(action: onAddToItinerary) {
                        Label("Add to itinerary", systemImage: "calendar.badge.plus")
                    }
                    Button(action: onCreateExpense) {
                        Label("Create expense here", systemImage: "dollarsign.circle")
                    }
                    Button(action: onSaveToTrip) {
                        Label("Save to trip places", systemImage: "person.2.fill")
                    }
                    .disabled(!canSaveToTrip)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.app(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Place actions")

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .readableSurface(cornerRadius: Theme.cardRadius)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.app(.title3))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .task(id: place.id) {
            lookAroundScene = nil
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: place.mapItem).scene
        }
    }

    private var thumbnail: some View {
        Group {
            if let lookAroundScene {
                LookAroundPreview(initialScene: lookAroundScene, allowsNavigation: false, badgePosition: .bottomTrailing)
            } else {
                ZStack {
                    LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: place.category.icon)
                        .font(.app(.title3))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: 76, height: 60)
        .clipShape(.rect(cornerRadius: 10))
        .padding(.trailing, 26) // Keep clear of the close button.
    }
}

/// Full details for a search-result place, presented as a sheet from the card's
/// "Details" button: Look Around preview, address, phone, website, and directions.
struct PlaceDetailSheet: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    let place: MapPlace
    @Binding var isSaved: Bool
    let onAddToItinerary: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    private var phoneURL: URL? {
        guard let phone = place.mapItem.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let lookAroundScene {
                    LookAroundPreview(initialScene: lookAroundScene)
                        .frame(height: 180)
                        .clipShape(.rect(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.app(.title2, .bold))
                    Text(place.category.title)
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let address = place.addressText {
                        Label(address, systemImage: "mappin.and.ellipse")
                    }
                    if let phone = place.mapItem.phoneNumber {
                        Label(phone, systemImage: "phone.fill")
                    }
                    if let website = place.mapItem.url {
                        Label(website.absoluteString, systemImage: "safari.fill")
                            .lineLimit(1)
                            .onTapGesture { openURL(website) }
                    }
                }
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        place.mapItem.openInMaps()
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.app(.headline))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                    .contextMenu { DirectionsModeMenu(mapItem: place.mapItem) }

                    Button {
                        isSaved.toggle()
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.app(size: 17, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    if let phoneURL {
                        Button {
                            openURL(phoneURL)
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.app(size: 17, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                    }
                }

                Button {
                    dismiss()
                    onAddToItinerary()
                } label: {
                    Label("Add to itinerary", systemImage: "calendar.badge.plus")
                        .font(.app(.headline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(20)
        }
        .task {
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: place.mapItem).scene
        }
    }
}

/// The bottom card for a place opened from a curated Explore trip: Look Around (or
/// the trip photo), the resolved details, the trip's own note, and quick actions.
struct FocusPlaceCard: View {
    @Environment(\.openURL) private var openURL

    let focus: MapFocus
    let onAddToItinerary: () -> Void
    let onCreateExpense: () -> Void
    let onSaveToTrip: () -> Void
    let canSaveToTrip: Bool
    let onDirections: () -> Void
    let onDetails: () -> Void
    let onClose: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.app(.body))
                            .foregroundStyle(.tint)
                        Text(focus.title)
                            .font(.app(.subheadline, .semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let category = focus.categoryText {
                            Text(category)
                        }
                        Text("· \(focus.destination.city), \(focus.destination.country)")
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    if focus.isResolving {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding exact location…")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                    } else if let address = focus.addressText {
                        Text(address)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                header
            }

            // Curated context from the trip itself.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(focus.item.cost)
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: .capsule)
                    Text("From \(focus.destination.title)")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Text(focus.item.detail)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            actions
        }
        .padding(12)
        .readableSurface(cornerRadius: Theme.cardRadius)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.app(.title3))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .task(id: focus.mapItem) {
            lookAroundScene = nil
            guard let mapItem = focus.mapItem else { return }
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: mapItem).scene
        }
    }

    /// The visual thumbnail: Look Around when available, otherwise the trip photo.
    private var header: some View {
        Group {
            if let lookAroundScene {
                LookAroundPreview(initialScene: lookAroundScene, allowsNavigation: false, badgePosition: .bottomTrailing)
            } else {
                DestinationPhoto(destination: focus.destination, symbolSize: 26)
            }
        }
        .frame(width: 76, height: 60)
        .clipShape(.rect(cornerRadius: 10))
        .padding(.trailing, 26) // Keep clear of the close button.
    }

    /// Directions and Details are always available; Call appears once the POI
    /// search resolves a place that has a phone number (the website lives in
    /// the Details sheet).
    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onDirections) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
            .contextMenu { DirectionsModeMenu(mapItem: focus.routableMapItem) }

            Button(action: onDetails) {
                Text("Details")
                    .font(.app(.subheadline, .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)

            Menu {
                Button(action: onAddToItinerary) {
                    Label("Add to itinerary", systemImage: "calendar.badge.plus")
                }
                Button(action: onCreateExpense) {
                    Label("Create expense here", systemImage: "dollarsign.circle")
                }
                Button(action: onSaveToTrip) {
                    Label("Save to trip places", systemImage: "person.2.fill")
                }
                .disabled(!canSaveToTrip)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.app(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Add to itinerary")

            if let phoneURL = focus.phoneURL {
                actionCircle(icon: "phone.fill", label: "Call") {
                    openURL(phoneURL)
                }
            }
        }
    }

    private func actionCircle(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.app(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text(label))
    }
}

/// Full details for a place opened from a curated Explore trip, presented from the
/// focus card's "Details" button: Look Around (or the trip photo), the trip's full
/// note and budget context, the resolved address/phone/website, and a "More from
/// this trip" list so the user can hop between the trip's stops without leaving
/// the map. Reads the live focus from `ExploreMapModel` so details fill in as the
/// POI search resolves while the sheet is open.
struct FocusDetailSheet: View {
    @Environment(ExploreMapModel.self) private var mapModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Called when the user picks another stop of the same trip; the sheet dismisses
    /// itself first so the map card underneath is visible when the focus moves.
    let onShowItem: (TravelPlanItem, Destination) -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        if let focus = mapModel.focus {
            content(for: focus)
        }
    }

    private func content(for focus: MapFocus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview(for: focus)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 4) {
                    Text(focus.title)
                        .font(.app(.title2, .bold))
                    HStack(spacing: 6) {
                        if let category = focus.categoryText {
                            Text(category)
                            Text(verbatim: "·")
                        }
                        Text(verbatim: "\(focus.destination.city), \(focus.destination.country)")
                    }
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                }

                curatedSection(for: focus)

                resolvedDetails(for: focus)

                actionButtons(for: focus)

                moreFromTrip(for: focus)
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .task(id: focus.mapItem) {
            lookAroundScene = nil
            guard let mapItem = focus.mapItem else { return }
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: mapItem).scene
        }
    }

    /// Look Around when available, otherwise the trip's bundled photo.
    @ViewBuilder
    private func preview(for focus: MapFocus) -> some View {
        if let lookAroundScene {
            LookAroundPreview(initialScene: lookAroundScene)
        } else {
            DestinationPhoto(destination: focus.destination, symbolSize: 44)
        }
    }

    /// The trip's own context: full note (unclipped, unlike the map card), the cost
    /// level, and who planned the trip it comes from.
    private func curatedSection(for focus: MapFocus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(focus.item.cost)
                    .font(.app(.caption, .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.15), in: .capsule)
                Text("From \(focus.destination.title)")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(focus.item.detail)
                .font(.app(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
            Label("Planned by \(focus.destination.planner)", systemImage: "person.circle.fill")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }

    /// Address / phone / website resolved by the POI search, with a progress row
    /// while the search is still in flight.
    @ViewBuilder
    private func resolvedDetails(for focus: MapFocus) -> some View {
        if focus.isResolving {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding exact location…")
            }
            .font(.app(.subheadline))
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let address = focus.addressText {
                    Label(address, systemImage: "mappin.and.ellipse")
                }
                if let phone = focus.mapItem?.phoneNumber {
                    Label(phone, systemImage: "phone.fill")
                }
                if let website = focus.websiteURL {
                    Label(website.absoluteString, systemImage: "safari.fill")
                        .lineLimit(1)
                        .onTapGesture { openURL(website) }
                }
            }
            .font(.app(.subheadline))
            .foregroundStyle(.secondary)
        }
    }

    private func actionButtons(for focus: MapFocus) -> some View {
        HStack(spacing: 10) {
            Button {
                focus.routableMapItem.openInMaps()
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.app(.headline))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

            if let phoneURL = focus.phoneURL {
                Button {
                    openURL(phoneURL)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.app(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(Text("Call"))
            }
        }
    }

    /// The trip's other stops, so the user can jump straight to the next place
    /// without going back to the Explore tab.
    @ViewBuilder
    private func moreFromTrip(for focus: MapFocus) -> some View {
        let places = focus.destination.places.filter { $0.id != focus.item.id }
        let restaurants = focus.destination.restaurants.filter { $0.id != focus.item.id }
        if !places.isEmpty || !restaurants.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("More from this trip")
                    .font(.app(.headline))
                ForEach(places) { item in
                    tripItemRow(item, icon: "mappin.circle.fill", focus: focus)
                }
                ForEach(restaurants) { item in
                    tripItemRow(item, icon: "fork.knife.circle.fill", focus: focus)
                }
            }
            .padding(.top, 4)
        }
    }

    private func tripItemRow(_ item: TravelPlanItem, icon: String, focus: MapFocus) -> some View {
        Button {
            dismiss()
            onShowItem(item, focus.destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.app(.title3))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.primary)
                    Text(item.detail)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(item.cost)
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: .capsule)
                Image(systemName: "chevron.right")
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .readableSurface(cornerRadius: Theme.cardRadius)
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import MapKit
import UIKit

/// Resolves a guide's stops to coordinates for the detail page's preview map.
///
/// The curated data carries names, not coordinates, so the pins have to be geocoded.
/// Searches run one at a time and results are cached by destination id for the life of
/// the process, so reopening a guide is instant and MapKit isn't asked the same
/// question twice.
@MainActor
@Observable
final class DestinationStopsLoader {
    struct Stop: Identifiable {
        let id: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private static var cache: [String: [Stop]] = [:]
    /// A guide can list a dozen places; this map is a glance, not a replacement for
    /// the Map tab, so only the first few are worth a network round trip.
    private static let maxStops = 8

    private(set) var stops: [Stop] = []
    private(set) var isLoading = false

    func load(_ destination: Destination) async {
        if let cached = Self.cache[destination.id] {
            stops = cached
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var resolved: [Stop] = []
        for item in destination.recommendedPlaces.prefix(Self.maxStops) {
            if Task.isCancelled { return }
            guard let coordinate = await Self.coordinate(for: item, in: destination) else { continue }
            resolved.append(Stop(id: item.id, name: item.name, coordinate: coordinate))
            // Show pins as they land rather than waiting for the whole set.
            stops = resolved
        }
        Self.cache[destination.id] = resolved
    }

    /// One search per stop, biased to the city and then distance-checked against it.
    /// `mapSearchTerm` is reused from the Map tab because several curated labels name a
    /// neighbourhood or a walk rather than a single place, which MapKit resolves badly.
    ///
    /// Stays main-actor isolated, unlike `DestinationImageCache.downsampled`: the only
    /// real cost here is the network round trip, which is an `await` suspension rather
    /// than CPU work, and the query it builds reads main-actor-isolated model
    /// properties. Nothing blocks the main thread.
    private static func coordinate(
        for item: TravelPlanItem,
        in destination: Destination
    ) async -> CLLocationCoordinate2D? {
        if let latitude = item.latitude, let longitude = item.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(item.mapSearchTerm), \(destination.city), \(destination.country)"
        request.region = MKCoordinateRegion(
            center: destination.coordinate,
            latitudinalMeters: 60_000,
            longitudinalMeters: 60_000
        )
        guard let response = try? await MKLocalSearch(request: request).start(),
              let coordinate = response.mapItems.first?.location.coordinate else { return nil }

        let city = CLLocation(
            latitude: destination.coordinate.latitude,
            longitude: destination.coordinate.longitude
        )
        let found = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // 150km is wide enough for the genuine day trips in the corpus (Sintra,
        // Jiufen, Chichén Itzá) and narrow enough to reject a same-named business on
        // another continent.
        return found.distance(from: city) <= 150_000 ? coordinate : nil
    }
}

/// A glance-level map of a guide's stops. Deliberately not interactive: a pannable map
/// inside a vertical `ScrollView` fights the scroll gesture, and the Map tab is one tap
/// away for anything more than orientation.
private struct DestinationStopsMap: View {
    let destination: Destination
    let onOpenMap: () -> Void

    @State private var loader = DestinationStopsLoader()
    /// `.automatic` frames whatever pins exist, so the camera tightens as stops land.
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Where you'll be", systemImage: "map.fill")
                    .font(Theme.Typography.sectionTitle)
                if loader.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            Map(position: $position) {
                Marker(destination.city, systemImage: "building.2.fill", coordinate: destination.coordinate)
                    .tint(.secondary)
                ForEach(loader.stops) { stop in
                    Marker(stop.name, systemImage: "mappin", coordinate: stop.coordinate)
                        .tint(Theme.accent)
                }
            }
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .allowsHitTesting(false)
            // Added after `allowsHitTesting`, so the button itself stays tappable.
            .overlay(alignment: .bottomTrailing) {
                Button(action: onOpenMap) {
                    Label("Open in Map", systemImage: "arrow.up.forward")
                        .font(.app(.caption, .semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .controlSurface(in: .capsule)
                .padding(10)
            }
            .task { await loader.load(destination) }
        }
    }
}

/// TripAdvisor-style destination page with Overview / Things to do / Restaurants tabs.
struct DestinationDetailView: View {
    @Environment(ExploreMapModel.self) private var mapModel

    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void
    /// Creates an editable itinerary seeded from this curated trip and navigates to
    /// it, so users don't have to start planning from scratch. The date is optional —
    /// an undated copy is still a perfectly good wish-list.
    var onUseAsPlan: (Date?) -> Void = { _ in }
    /// Community guides are public rather than profile bookmarks, so their detail
    /// page swaps the editorial save control for reporting or owner management.
    var showsSaveAction = true
    var onReport: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() async throws -> Void)? = nil

    @State private var showUseAsPlanConfirm = false
    @State private var hasStartDate = false
    @State private var startDate = Date()
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var managementError: String?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case thingsToDo = "Things to do"
        case restaurants = "Restaurants"

        var id: Self { self }
    }

    @State private var tab: DetailTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            ScrollView {
                hero
                    .padding(.horizontal)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .overview: overviewSection
                    case .thingsToDo: planList(destination.places, isRestaurant: false)
                    case .restaurants: planList(destination.restaurants, isRestaurant: true)
                    }
                }
                .padding()
                .padding(.bottom, 80)
            }
        }
        .background { AppBackground() }
        .navigationTitle(destination.city)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Plain text, not a link: the guides are bundled in the app, so there
                // is no URL that would mean anything to whoever receives this.
                ShareLink(item: shareText, subject: Text(verbatim: destination.title)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share this guide")

                if showsSaveAction {
                    Button(action: onToggleSave) {
                        Image(systemName: isSaved ? "heart.fill" : "heart")
                            .foregroundStyle(isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    }
                    .accessibilityLabel(Text(isSaved ? "Remove from saved" : "Save"))
                } else if onReport != nil || onEdit != nil || onDelete != nil {
                    Menu {
                        if let onEdit {
                            Button(action: onEdit) {
                                Label("Edit guide", systemImage: "pencil")
                            }
                        }
                        if let onReport {
                            Button(role: .destructive, action: onReport) {
                                Label("Report guide", systemImage: "exclamationmark.bubble")
                            }
                        }
                        if onDelete != nil {
                            Divider()
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete guide", systemImage: "trash")
                            }
                        }
                    } label: {
                        if isDeleting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .disabled(isDeleting)
                    .accessibilityLabel("Community guide options")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            detailActionBar
        }
        .confirmationDialog(
            "Delete this community guide?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Guide", role: .destructive) { deleteGuide() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the guide for everyone. It won’t delete itineraries that travelers already created from it.")
        }
        .alert(
            "Couldn’t delete guide",
            isPresented: Binding(
                get: { managementError != nil },
                set: { if !$0 { managementError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: managementError ?? "Please try again.")
        }
    }

    /// The plain-text summary handed to the share sheet. Curated content is English
    /// only, so this is built with string interpolation rather than localized keys.
    private var shareText: String {
        var lines = [
            "\(destination.title) — \(destination.city), \(destination.country)",
            "",
            destination.blurb,
            "",
            "\(destination.days) days · \(destination.price) · \(destination.recommendedStopCount) recommended stops",
        ]
        let highlights = destination.recommendedPlaces.prefix(4).map(\.name)
        if !highlights.isEmpty {
            lines.append("Highlights: \(highlights.joined(separator: ", "))")
        }
        let eats = destination.recommendedRestaurants.prefix(3).map(\.name)
        if !eats.isEmpty {
            lines.append("Eat at: \(eats.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Shared from TripSplit")
        return lines.joined(separator: "\n")
    }

    private func deleteGuide() {
        guard let onDelete, !isDeleting else { return }
        isDeleting = true
        Task {
            do {
                try await onDelete()
            } catch {
                managementError = (error as? AuthError)?.message ?? "The community guide could not be deleted."
                isDeleting = false
            }
        }
    }

    /// The guide section selector below the navigation bar.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        tab = option
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(LocalizedStringKey(option.rawValue))
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(tab == option ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Capsule()
                            .fill(tab == option ? Color.primary : .clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey(option.rawValue))
                .accessibilityIdentifier("curated-guide-section-\(option.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var hero: some View {
        ZStack {
            DestinationPhoto(destination: destination, symbolSize: 100)

            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(height: 240)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                ForEach(destination.tags, id: \.self) { tag in
                    Text(LocalizedStringKey(tag))
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.92), in: .rect(cornerRadius: 8))
                }
            }
            .padding(12)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(destination.title)
                .font(Theme.Typography.pageTitle)

            Text(destination.blurb)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                statTile(value: destination.price, label: "Est. total")
                statTile(value: destination.dailyBudget, label: "Budget")
                statTile(value: "\(destination.recommendedStopCount)", label: "Recommended")
            }

            recommendationSummary

            DestinationStopsMap(destination: destination) {
                if let firstPlace = destination.recommendedPlaces.first {
                    mapModel.showOnMap(firstPlace, in: destination)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Planned by \(destination.planner)", systemImage: "person.circle.fill")
                    .font(Theme.Typography.rowTitle)
                Text(destination.plannerNote)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .readableSurface(cornerRadius: Theme.cardRadius)

            planningEssentials
        }
    }

    /// Primary call-to-action: turn this curated trip into the user's own editable
    /// itinerary instead of starting from a blank plan.
    private var useAsPlanButton: some View {
        Button {
            showUseAsPlanConfirm = true
        } label: {
            Label("Use as my starting plan", systemImage: "wand.and.stars")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .actionFill(tint: Theme.accent)
        // A sheet rather than a confirmation dialog: dialogs can't host a date picker,
        // and the copied plan used to land with no dates at all — a set of unanchored
        // days the user then had to date by hand in the planner.
        .sheet(isPresented: $showUseAsPlanConfirm) {
            useAsPlanSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Scrolling body plus a pinned action button, mirroring `CreateItineraryView` —
    /// the content grows when the date picker appears and again under Dynamic Type, so
    /// a fixed-height layout would clip it.
    private var useAsPlanSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(destination.days)-day plan · \(destination.price) budget. Edit after adding.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Set a start date", isOn: $hasStartDate.animation(.snappy))
                        .font(.app(.subheadline, .medium))
                        .tint(Theme.accent)

                    if hasStartDate {
                        DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                            .font(Theme.Typography.secondary)
                        Label(
                            "Your \(destination.days) days will be scheduled from here.",
                            systemImage: "calendar"
                        )
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Start from \(destination.city)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showUseAsPlanConfirm = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showUseAsPlanConfirm = false
                    onUseAsPlan(hasStartDate ? startDate : nil)
                } label: {
                    Label("Create my itinerary", systemImage: "wand.and.stars")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .actionFill(tint: Theme.accent)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    /// Keep the conversion action reachable from every detail tab, with Map as a
    /// clear secondary escape hatch instead of another competing primary button.
    private var detailActionBar: some View {
        HStack(spacing: 10) {
            Button {
                if let firstPlace = destination.places.first {
                    mapModel.showOnMap(firstPlace, in: destination)
                }
            } label: {
                Label("Map", systemImage: "map.fill")
                    .font(Theme.Typography.rowTitle)
                    .frame(minWidth: 76, minHeight: 50)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .readableSurface(cornerRadius: 25, elevated: true)

            useAsPlanButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// Destination-level guidance turns the card collection into a trip a user can
    /// actually follow: where to base themselves, how to move between clusters, and
    /// the one thing worth arranging before arrival.
    private var planningEssentials: some View {
        let guide = destination.practicalGuide
        return VStack(alignment: .leading, spacing: 12) {
            Label("Plan it like a local", systemImage: "map.fill")
                .font(Theme.Typography.sectionTitle)

            guideRow(icon: "bed.double.fill", title: "Best base", detail: guide.base)
            guideRow(icon: "tram.fill", title: "Getting around", detail: guide.transport)
            guideRow(icon: "calendar.badge.clock", title: "Book first", detail: guide.booking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }

    /// Makes the guide's constraints actionable at the top of the overview. The
    /// detailed tabs still expose every curated option, but these are the places that
    /// will be copied into a new itinerary for this guide's length and budget.
    private var recommendationSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recommended for your trip", systemImage: "wand.and.stars")
                .font(Theme.Typography.sectionTitle)

            Text(destination.recommendationSummary)
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(destination.recommendedPlaces.prefix(3).enumerated()), id: \.element.id) { index, item in
                Button {
                    mapModel.showOnMap(item, in: destination)
                } label: {
                    recommendationRow(index: index, item: item)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.tint)
                Text("Plus \(destination.recommendedRestaurants.count) meal picks matched to the same budget.")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            Button("See all recommended stops") {
                withAnimation(.snappy(duration: 0.2)) { tab = .thingsToDo }
            }
            .font(.app(.subheadline, .semibold))
            .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }

    private func recommendationRow(index: Int, item: TravelPlanItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.app(.caption, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.app(.subheadline, .semibold))
                    Text(item.cost)
                        .font(.app(.caption2, .bold))
                        .foregroundStyle(.secondary)
                }
                Text(item.detail)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "map")
                .font(.app(.caption, .semibold))
                .foregroundStyle(.tint)
        }
        .contentShape(.rect)
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(.caption, .bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(Theme.Typography.secondary)
            }
        }
    }

    private func statTile(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.app(.subheadline, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(Theme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }

    /// A numbered TripAdvisor-style list of places or restaurants. Tapping a row
    /// drops a pin on the Map tab so the user can see where it is.
    private func planList(_ items: [TravelPlanItem], isRestaurant: Bool) -> some View {
        let recommended = isRestaurant ? destination.recommendedRestaurants : destination.recommendedPlaces
        let recommendedIDs = Set(recommended.map(\.id))
        let remaining = items.filter { !recommendedIDs.contains($0.id) }
        let emptyStateTitle: LocalizedStringKey = isRestaurant ? "No restaurants yet" : "No things to do yet"

        return VStack(alignment: .leading, spacing: 12) {
            if recommended.isEmpty && remaining.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: isRestaurant ? "fork.knife" : "mappin.and.ellipse",
                    description: Text("This guide does not have any curated recommendations in this section yet.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Label {
                    Text(
                        isRestaurant
                            ? "Recommended meal picks for this budget"
                            : "Recommended locations for this trip"
                    )
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)

                ForEach(Array(recommended.enumerated()), id: \.element.id) { index, item in
                    Button {
                        mapModel.showOnMap(item, in: destination)
                    } label: {
                        planRow(index: index, item: item, isRestaurant: isRestaurant)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.rect)
                    .accessibilityHint("Opens \(item.mapSearchTerm) on the map")
                }

                if !remaining.isEmpty {
                    Label("More curated options", systemImage: "ellipsis.circle")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    ForEach(Array(remaining.enumerated()), id: \.element.id) { index, item in
                        Button {
                            mapModel.showOnMap(item, in: destination)
                        } label: {
                            planRow(index: recommended.count + index, item: item, isRestaurant: isRestaurant)
                        }
                        .buttonStyle(.plain)
                        .contentShape(.rect)
                        .accessibilityHint("Opens \(item.mapSearchTerm) on the map")
                    }
                }
            }
        }
    }

    private func planRow(index: Int, item: TravelPlanItem, isRestaurant: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("\(index + 1)").font(Theme.Typography.sectionTitle).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.app(.body, .semibold)).foregroundStyle(.primary)
                    Text(item.cost)
                        .font(.app(.caption2, .bold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: .capsule)
                }
                Text(item.detail)
                    .font(Theme.Typography.secondary).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Label(item.visitAdvice(isRestaurant: isRestaurant), systemImage: "checkmark.circle")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "map").font(.app(.callout, .semibold)).foregroundStyle(.tint)
        }
        .padding(14)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }
}

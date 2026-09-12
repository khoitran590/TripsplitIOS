import SwiftUI
import MapKit
import UIKit

struct NextTripHeroCard: View {
    let trip: Trip

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 210

    private var dayCount: Int { trip.itinerary?.days.count ?? 0 }

    /// The eyebrow above the name, keyed to where the trip sits in time.
    private var eyebrow: LocalizedStringKey {
        if trip.isOngoing { return "HAPPENING NOW" }
        if let days = trip.daysUntilStart, days >= 0 { return "NEXT TRIP" }
        return "YOUR TRIP"
    }

    var body: some View {
        cardBody
    }

    // MARK: Card

    /// The card version: the cover *is* the card. Countdown pill and avatar stack on the
    /// photo, the name and two fact chips on the scrim, and an arrow disc. The old
    /// text panel + three-stat strip said the same things in three more lines.
    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.05), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.72), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: trip.name)
                    .font(.app(.title2, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(alignment: .center, spacing: 6) {
                    if let range = trip.dateRangeText {
                        coverChip(Text(verbatim: range), icon: "calendar")
                    }
                    if dayCount > 0 {
                        coverChip(Text(verbatim: "\(plannedDays) / \(dayCount)"), icon: "map")
                            .accessibilityLabel("\(plannedDays) of \(dayCount) days planned")
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.94), in: .circle)
                }
            }
            .padding(16)
        }
        .frame(height: cardHeight)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle()
                    .fill(trip.isOngoing ? Theme.positive : Theme.accent)
                    .frame(width: 7, height: 7)
                Text(countdown)
            }
            .font(.app(.caption, .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.white.opacity(0.94), in: .capsule)
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            memberStack.padding(14)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .shadow(color: Theme.elevatedShadow, radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }

    /// Days with at least one stop — the "planned" half of the day chip.
    private var plannedDays: Int {
        trip.itinerary?.days.filter { !$0.stops.isEmpty }.count ?? 0
    }

    /// The pill's wording, keyed to where the trip sits in time.
    private var countdown: LocalizedStringKey {
        if trip.isOngoing { return "Happening now" }
        if let days = trip.daysUntilStart {
            if days == 0 { return "Today" }
            if days == 1 { return "Tomorrow" }
            if days > 1 { return "In \(days) days" }
        }
        return "Your trip"
    }

    private func coverChip(_ label: Text, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.app(.caption2, .semibold))
            label
                .font(.app(.caption, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(.white.opacity(0.22), in: .capsule)
    }

    private var memberStack: some View {
        let shown = Array(trip.members.prefix(3))
        let extra = trip.members.count - shown.count
        return HStack(spacing: -8) {
            ForEach(shown) { person in
                AvatarView(person: person, size: 26)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.3), in: .circle)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trip.members.count) members")
    }

}

struct UpcomingTripCard: View {
    let trip: Trip

    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 176
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 124

    /// The badge over (or above) the photo — "In N days" while it's ahead, the plan
    /// length once it isn't.
    private var badgeText: LocalizedStringKey {
        if trip.isOngoing { return "Happening now" }
        if let days = trip.daysUntilStart {
            if days == 0 { return "Today" }
            if days == 1 { return "Tomorrow" }
            if days > 1 { return "In \(days) days" }
        }
        let count = trip.itinerary?.days.count ?? 0
        return count == 1 ? "1 day" : "\(count) days"
    }

    var body: some View {
        cardBody
    }

    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: trip.name)
                    .font(.app(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let range = trip.dateRangeText {
                    Text(verbatim: range)
                        .font(.app(.caption2, .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(alignment: .topLeading) {
            Text(badgeText)
                .font(.app(.caption2, .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.white.opacity(0.94), in: .capsule)
                .padding(10)
        }
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

}

/// A tall photo-style carousel card, TripAdvisor's "Plan your next adventure" look:
/// tag chips and a heart floating over the image, city name anchored at the bottom.
struct AdventureCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void
    var showsCTA = false

    /// Grows with Dynamic Type so the city/country/budget stack and the CTA still fit
    /// at large sizes, but clamped — an unbounded carousel card would run off screen.
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 300
    /// The plate is shorter than the card because the caption below it needs room that
    /// the card reversed out of the image.

    @ViewBuilder
    var body: some View {
        cardBody
    }

    private var cardBody: some View {
        ZStack {
            DestinationPhoto(destination: destination, symbolSize: 110)

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(cardHeight, 520))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .font(.app(.caption2, .bold))
                Text("Editor's pick")
                    .font(.app(.caption, .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(.white.opacity(0.94), in: .capsule)
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            HeartButton(isSaved: isSaved, action: onToggleSave)
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                // City is a proper noun (verbatim); country goes through
                // `LocalizedStringKey` the way the grid tiles already do — the two card
                // styles used to disagree, so a country localized in one list and not
                // in the other.
                Text(verbatim: destination.city)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(LocalizedStringKey(destination.country))
                    .font(.app(.subheadline, .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                // Length, stops and price as three glyph chips — the same facts the
                // text line carried, but scannable.
                HStack(spacing: 6) {
                    coverChip(Text("\(destination.days) days"), icon: "calendar")
                    coverChip(Text(verbatim: "\(destination.stops)"), icon: "mappin.and.ellipse")
                        .accessibilityLabel("\(destination.stops) stops")
                    coverChip(Text(verbatim: destination.price), icon: nil)
                    Spacer(minLength: 6)
                    if showsCTA {
                        HStack(spacing: 6) {
                            Text("Open")
                            Image(systemName: "arrow.right")
                        }
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.white.opacity(0.94), in: .capsule)
                    }
                }
                .padding(.top, 12)
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .shadow(color: Theme.elevatedShadow, radius: 10, y: 4)
    }

    private func coverChip(_ label: Text, icon: String?) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.app(.caption2, .semibold))
            }
            label
                .font(.app(.caption, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(.white.opacity(0.22), in: .capsule)
    }
}

/// The rail card: photo on top, facts underneath.
///
/// Everything this card said used to be white text over an uncontrolled photo — the
/// city and "5 days · $$", and nothing else. That is pretty, but it never answers the
/// question someone browsing is actually asking, which is what they get if they open
/// it. The strip below the image carries the length, the total budget, the stop count
/// and two of the stops *by name*, on a readable surface.
struct CountryTripCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void

    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 200
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 226
    /// Narrower than the card: with no surface to fill, the entry is only as wide as its
    /// photograph needs to be, and more of the rail is visible at once.

    /// The travel style the card shows as its third fact, with its glyph.
    private var style: ExploreStyle? {
        ExploreStyle.allCases.first { $0.matches(destination) }
    }

    @ViewBuilder
    var body: some View {
        cardBody
    }

    /// Photo with the price pinned to it and the heart in the corner; underneath, the
    /// place and three glyph-led facts (length, stops, style) instead of a sentence.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            DestinationPhoto(destination: destination, symbolSize: 64)
                .frame(height: 130)
                .clipShape(.rect(
                    topLeadingRadius: Theme.cardRadius,
                    topTrailingRadius: Theme.cardRadius
                ))
                .overlay(alignment: .topTrailing) {
                    HeartButton(isSaved: isSaved, action: onToggleSave)
                        .padding(4)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: destination.price)
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(.white.opacity(0.94), in: .capsule)
                        .padding(10)
                }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    // City is a proper noun; the country goes through the catalog, the
                    // way the grid tiles already do it.
                    Text(verbatim: destination.city)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(LocalizedStringKey(destination.country))
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    fact(Text(verbatim: "\(destination.days)"), icon: "calendar")
                        .accessibilityLabel("\(destination.days) days")
                    fact(Text(verbatim: "\(destination.stops)"), icon: "mappin.and.ellipse")
                        .accessibilityLabel("\(destination.stops) stops")
                    if let style {
                        fact(Text(style.title), icon: style.systemImage)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(width: min(cardWidth, 320), height: min(cardHeight, 320), alignment: .top)
        .readableSurface(cornerRadius: Theme.cardRadius, elevated: true)
    }

    private func fact(_ label: Text, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.app(.caption2, .semibold))
            label
                .font(.app(.caption, .semibold))
        }
        .foregroundStyle(.secondary)
    }
}

/// The compact photo tile used for filtered results and the region directory. It
/// carries the country because the directory groups by region, where a city name
/// alone isn't always enough to place it.
///
/// The save button is *not* part of this card — callers overlay it outside the
/// enclosing `NavigationLink` (see `destinationGrid`), because a `HeartButton`
/// nested inside the link was folded into the link's combined accessibility
/// element and became unreachable with VoiceOver.
struct MatchingTripCard: View {
    let destination: Destination

    /// The whole tile is the photograph; the place and the figures print on its scrim.
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DestinationPhoto(destination: destination, symbolSize: 44)
            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .init(x: 0.5, y: 0.45),
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: destination.city)
                    .font(.app(.headline, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(LocalizedStringKey(destination.country))
                    .font(.app(.caption2))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                // Same facts as the rail cards, so a guide reads the same wherever it
                // appears.
                Text("\(destination.days)d · \(destination.stops) stops · \(destination.price)")
                    .font(.app(.caption2, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 5)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 176)
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }
}

/// A compact row used for search results and the saved list. `matchedStop` names
/// the place/restaurant inside the trip that matched a search, so results can show
/// *why* a city came up.
struct DestinationRow: View {
    let destination: Destination
    var matchedStop: String? = nil

    private var localizedCountry: String {
        String(localized: String.LocalizationValue(destination.country))
    }

    @ViewBuilder
    var body: some View {
        cardRow
    }

    private var cardRow: some View {
        HStack(spacing: 14) {
            DestinationPhoto(destination: destination, symbolSize: 22)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                // The country is resolved *before* interpolation, then rendered
                // verbatim. `Text("\(city), \(country)")` builds a LocalizedStringKey
                // that matches no catalogue entry, so the country was never translated
                // here — while the grid tiles alongside it were. `String(localized:)`
                // reads through the bundle `LocalizationManager` swizzles, so it honors
                // the in-app language switch.
                Text(verbatim: "\(destination.city), \(localizedCountry)")
                    .font(.app(.body, .semibold))
                    .foregroundStyle(.primary)
                Text("\(destination.tags.joined(separator: " · ")) · \(destination.price)")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
                if let matchedStop {
                    Label("Includes \(matchedStop)", systemImage: "mappin")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.app(.footnote, .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .readableSurface(cornerRadius: Theme.cardRadius, elevated: true)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }
}

/// The circular white heart button floating over card imagery.
struct HeartButton: View {
    let isSaved: Bool
    let action: () -> Void

    private var mark: AnyShapeStyle {
        isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.black)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.app(size: 16, weight: .semibold))
                .foregroundStyle(mark)
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(.white.opacity(0.95))
                }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isSaved)
        .accessibilityLabel(Text(isSaved ? "Remove from saved" : "Save"))
    }
}

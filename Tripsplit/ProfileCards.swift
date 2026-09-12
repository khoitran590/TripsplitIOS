import SwiftUI

/// A visited place on the profile's "Where I've been" rail: its stamp, the full place
/// name, and the month the trip there was.
struct VisitedPlaceCard: View {
    let place: VisitedPlace

    private var monthYear: String? {
        place.date?.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaceStampBadge(place: place)
                .frame(width: 168, height: 176)

            Text(verbatim: place.name)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)
            Text(verbatim: monthYear ?? " ")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 168, alignment: .leading)
    }
}

/// A saved Explore guide on the profile's "Saved" rail, drawn in the guide's own
/// colors so it reads the same as it does on the Explore tab.
struct SavedDestinationCard: View {
    let destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: destination.symbol)
                        .font(.app(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(12)
                }
                .frame(width: 168, height: 110)
                .clipShape(.rect(cornerRadius: 18))

            Text(verbatim: destination.title)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)
            Text(verbatim: "\(destination.city), \(destination.country)")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 168, alignment: .leading)
    }
}

/// A place bookmarked on the Map tab, shown on the profile's "Saved" rail.
struct SavedMapPlaceCard: View {
    let place: SavedMapPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.accent.opacity(0.15))
                .overlay {
                    Image(systemName: "mappin.circle.fill")
                        .font(.app(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 168, height: 110)

            Text(verbatim: place.name)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)
            Text(verbatim: place.address ?? place.category.capitalized)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 168, alignment: .leading)
    }
}

/// A compact trip card for the profile's "My trips" rail: cover image with the
/// trip name, location, and dates beneath. Tapping opens the trip detail sheet.
struct ProfileTripCard: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TripCoverView(trip: trip)
                .frame(width: 220, height: 148)
                .clipShape(.rect(cornerRadius: 18))

            Text(verbatim: trip.name)
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let location = trip.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty {
                Label {
                    Text(verbatim: location)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if let dates = trip.dateRangeText {
                Text(verbatim: dates)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 220, alignment: .leading)
    }
}

/// A minimal left-aligned wrapping layout for chips.

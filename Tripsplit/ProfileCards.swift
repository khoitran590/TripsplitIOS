import SwiftUI

/// A visited place on the profile's "Where I've been" rail: its stamp, the full place
/// name, and the month the trip there was.
struct VisitedPlaceCard: View {
    let place: VisitedPlace

    private var monthYear: String? {
        place.date?.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(spacing: 4) {
            PlaceStampBadge(place: place, size: 128, compact: true)
                .frame(width: 136, height: 136)
                .accessibilityHidden(true)

            Text(verbatim: place.shortName)
                .font(.app(.footnote, .semibold))
                .lineLimit(1)
                .padding(.top, 4)
            Text(verbatim: monthYear ?? " ")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 128)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [place.name, monthYear].compactMap { $0 }.joined(separator: ", ")))
    }
}

/// A saved Explore guide on the profile's "Saved" rail, drawn in the guide's own
/// colors so it reads the same as it does on the Explore tab.
struct SavedDestinationCard: View {
    let destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DestinationPhoto(destination: destination, symbolSize: 36)
                .frame(width: 120, height: 120)
                .clipShape(.rect(cornerRadius: 22))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "heart.fill")
                        .font(.app(.caption2, .bold))
                        .foregroundStyle(.red)
                        .frame(width: 26, height: 26)
                        .background(Theme.surface, in: .circle)
                        .padding(8)
                        .accessibilityHidden(true)
                }

            Text(verbatim: destination.city)
                .font(.app(.footnote, .semibold))
                .lineLimit(1)
            Text("\(destination.country) · \(destination.days) days")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 120, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A place bookmarked on the Map tab, shown on the profile's "Saved" rail.
struct SavedMapPlaceCard: View {
    let place: SavedMapPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 22)
                .fill(Theme.accent.opacity(0.12))
                .overlay {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.app(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .overlay(alignment: .bottomLeading) {
                    if !place.category.isEmpty {
                        Text(verbatim: place.category.capitalized)
                            .font(.app(.caption2, .semibold))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 22)
                            .background(Theme.surface, in: .capsule)
                            .padding(8)
                    }
                }
                .frame(width: 120, height: 120)

            Text(verbatim: place.name)
                .font(.app(.footnote, .semibold))
                .lineLimit(1)
            Text(verbatim: place.address ?? " ")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 120, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A compact trip card for the profile's "My trips" rail: cover image with the
/// trip name, location, and dates beneath. Tapping opens the trip detail sheet.
struct ProfileTripCard: View {
    let trip: Trip

    var body: some View {
        TripCoverView(trip: trip)
            .frame(width: 210, height: 150)
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.4),
                                       .init(color: .black.opacity(0.7), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: trip.name)
                        .font(.app(.callout, .bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let location = trip.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty {
                            coverChip(Text(verbatim: location), icon: "mappin.and.ellipse")
                        }
                        if let dates = trip.dateRangeText {
                            coverChip(Text(verbatim: dates), icon: nil)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .clipShape(.rect(cornerRadius: 22))
            .shadow(color: Theme.elevatedShadow, radius: 8, y: 4)
            .accessibilityElement(children: .combine)
    }

    private func coverChip(_ label: Text, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.app(size: 9, weight: .bold)) }
            label.font(.app(.caption2, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 22)
        .background(.white.opacity(0.22), in: .capsule)
    }
}

/// A minimal left-aligned wrapping layout for chips.

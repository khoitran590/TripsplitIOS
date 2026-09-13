import SwiftUI
import MapKit
import UIKit
import CoreLocation

struct CategoryPin: View {
    let icon: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: -3) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color(white: 0.13))
                Image(systemName: icon)
                    .font(.app(size: isSelected ? 15 : 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: isSelected ? 40 : 32, height: isSelected ? 40 : 32)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))

            PinTail()
                .fill(isSelected ? Color.accentColor : Color(white: 0.13))
                .frame(width: 12, height: isSelected ? 11 : 9)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

/// Spending-map bubble. Area grows logarithmically so a large hotel bill stands out
/// without making smaller meals impossible to tap.
struct ExpenseMapMarker: View {
    let amount: Double
    let currencyCode: String
    let isSelected: Bool

    private var diameter: CGFloat {
        let scaled = CGFloat(log10(max(amount, 1)) * 7 + 24)
        return min(max(scaled, 28), 52) + (isSelected ? 6 : 0)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.orange : Color.orange.opacity(0.88))
            Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                .font(.app(size: diameter > 40 ? 11 : 9, weight: .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .padding(3)
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .accessibilityLabel("Expense \(money(amount, currencyCode))")
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }
}

struct NumberedItineraryPin: View {
    let number: Int
    let kind: ItineraryStopKind
    let quality: ItineraryLocationQuality

    var body: some View {
        ZStack {
            Circle().fill(kind.tint)
            Text("\(number)")
                .font(.app(.caption, .bold))
                .foregroundStyle(.white)
            Image(systemName: quality.icon)
                .font(.app(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(quality.tint, in: .circle)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .offset(x: 13, y: -13)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}

struct ExpenseMapCard: View {
    let pin: ExpenseMapPin
    let payerName: String
    let onDetails: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(pin.expense.title, systemImage: "dollarsign.circle.fill")
                        .font(.app(.headline, .semibold))
                        .foregroundStyle(.primary)
                    Text(money(pin.expense.amount, pin.trip.currencyCode))
                        .font(.app(.title3, .bold))
                    Text("\(pin.trip.name) · Paid by \(payerName)")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                    Text(pin.location.address ?? pin.location.name)
                        .font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(.title3)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: onDetails) {
                Label("Expense details", systemImage: "list.bullet.rectangle")
                    .font(.app(.subheadline, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.orange).interactive(), in: .capsule)
        }
        .padding(14)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }
}

struct FeedMapCard: View {
    let pin: FeedMapPin
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(pin.post.locationName ?? "Trip post", systemImage: "photo.on.rectangle.angled")
                        .font(.app(.headline, .semibold))
                        .foregroundStyle(.teal)
                    Text("\(pin.post.authorName) · \(pin.trip.name)")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(.title3)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if !pin.post.text.isEmpty {
                Text(pin.post.text)
                    .font(.app(.subheadline))
                    .lineLimit(3)
            }
            Text(pin.post.date, style: .date)
                .font(.app(.caption2)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }
}


struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// First-class list companion to the Saved map layer. It works entirely from durable
/// snapshots, so bookmarks remain browseable before a new MapKit search has run.

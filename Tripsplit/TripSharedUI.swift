import SwiftUI
import ImageIO
import UIKit

/// Prepares user-picked images for upload/display without keeping full-resolution originals
/// around in SwiftUI state. ImageIO thumbnails avoid a large decode for camera-roll photos.
enum UploadImagePreparation {
    static func preparedImage(
        from data: Data,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) async -> (image: UIImage, jpeg: Data)? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                let image = UIImage(cgImage: cgImage)
                guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else { return nil }
                return (image, jpeg)
            }
        }.value
    }

    static func jpegData(
        from data: Data,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) async -> Data? {
        (await preparedImage(from: data, maxPixelSize: maxPixelSize, compressionQuality: compressionQuality))?.jpeg
    }

    static func jpegData(
        from image: UIImage,
        maxPixelSize: CGFloat,
        compressionQuality: CGFloat
    ) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let longestSide = max(image.size.width, image.size.height)
                let output: UIImage
                if longestSide > maxPixelSize {
                    let scale = maxPixelSize / longestSide
                    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    // scale = 1 so `newSize` IS the pixel size — the renderer default is
                    // the screen scale (3x on device), which would triple the dimensions
                    // and can OOM-kill the app on a full-size photo.
                    let format = UIGraphicsImageRendererFormat.default()
                    format.scale = 1
                    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
                    output = renderer.image { _ in
                        image.draw(in: CGRect(origin: .zero, size: newSize))
                    }
                } else {
                    output = image
                }
                return output.jpegData(compressionQuality: compressionQuality)
            }
        }.value
    }
}

// MARK: - Shared pieces

/// One button revealed by swiping a `SwipeActionsRow` left.
struct RowSwipeAction: Identifiable {
    let id = UUID()
    /// Accessibility name for the action (e.g. "Delete", "Archive").
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let handler: () -> Void
}

/// A row wrapper that reveals action buttons when swiped left, giving the app's custom
/// card rows the `List` swipe-actions affordance without adopting `List`. Actions are
/// ordered inner → outer; the outermost (last) one hugs the screen edge and also fires
/// on a Mail-style full swipe. A flick opens/closes the row even short of halfway, and
/// tapping an open row closes it instead of activating the row's own button.
struct SwipeActionsRow<Content: View>: View {
    let actions: [RowSwipeAction]
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    /// Dragged far enough that releasing fires the edge action.
    @State private var isPastFullSwipe = false
    private let actionWidth: CGFloat = 76
    private let settle = Animation.spring(response: 0.3, dampingFraction: 0.8)

    private var openWidth: CGFloat { CGFloat(actions.count) * actionWidth }
    private var fullSwipeThreshold: CGFloat { max(openWidth + 76, rowWidth * 0.55) }

    var body: some View {
        ZStack(alignment: .trailing) {
            // The actions are sized to exactly the swiped-open width and only drawn while
            // open, so they never sit behind (and bleed through) a translucent glass row.
            if offset < 0 {
                actionButtons
            }

            content
                .offset(x: offset)
                .overlay {
                    // First tap on an open row closes it instead of triggering the
                    // row's own tap/navigation.
                    if offset != 0 {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { close() }
                            .offset(x: offset)
                    }
                }
                .highPriorityGesture(drag)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var actionButtons: some View {
        let revealed = -offset
        return HStack(spacing: isPastFullSwipe ? 0 : 5) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let isEdge = index == actions.count - 1
                let width: CGFloat = isPastFullSwipe
                    ? (isEdge ? revealed : 0)
                    : max((revealed - 5 * CGFloat(actions.count - 1)) / CGFloat(actions.count), 0)
                Button {
                    trigger(action)
                } label: {
                    Image(systemName: action.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(action.tint, in: .rect(cornerRadius: 20))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(action.label))
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Only react to predominantly-horizontal drags so vertical
                // scrolling still wins inside the enclosing ScrollView.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let travelLimit = rowWidth > 0 ? rowWidth : openWidth
                offset = min(0, max(startOffset + value.translation.width, -travelLimit))
                let nowPast = rowWidth > 0 && offset < -fullSwipeThreshold
                if nowPast != isPastFullSwipe {
                    withAnimation(settle) { isPastFullSwipe = nowPast }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { value in
                if isPastFullSwipe, let edge = actions.last {
                    trigger(edge)
                    return
                }
                // Settle using the projected end point so a quick flick opens or
                // closes the row without needing to drag past halfway.
                let projected = startOffset + value.predictedEndTranslation.width
                let opened = projected < -openWidth / 2
                withAnimation(settle) { offset = opened ? -openWidth : 0 }
                startOffset = opened ? -openWidth : 0
            }
    }

    private func trigger(_ action: RowSwipeAction) {
        close()
        action.handler()
    }

    private func close() {
        withAnimation(settle) {
            offset = 0
            isPastFullSwipe = false
        }
        startOffset = 0
    }
}

/// A `SwipeActionsRow` with the single destructive delete action, preserving the
/// original swipe-to-delete call sites.
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        SwipeActionsRow(actions: [
            RowSwipeAction(label: "Delete", icon: "trash.fill", tint: Theme.negative, handler: onDelete)
        ]) {
            content
        }
    }
}

/// A standard Liquid Glass card with a labeled header, used across the trip screens.
struct TripCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

// MARK: - Trip cover

/// The hero image for a trip: the uploaded cover photo if one exists, otherwise a
/// deterministic gradient (seeded by the trip id) topped with a travel glyph, so every
/// trip looks distinct even before a photo is added. Used by the home cards and the
/// trip detail hero header.
struct TripCoverView: View {
    let trip: Trip

    /// Curated cover gradients; one is chosen deterministically per trip.
    private static let palettes: [[UInt32]] = [
        [0x6366F1, 0x8B5CF6, 0xA855F7],
        [0x0EA5E9, 0x2563EB, 0x4338CA],
        [0x10B981, 0x059669, 0x047857],
        [0xF59E0B, 0xEA580C, 0xDC2626],
        [0xEC4899, 0xDB2777, 0x9333EA],
        [0x14B8A6, 0x0D9488, 0x0F766E],
        [0xF43F5E, 0xE11D48, 0xBE123C],
        [0x3B82F6, 0x6366F1, 0x8B5CF6],
    ]

    private var palette: [Color] {
        // Seed from raw UUID bytes, not `hashValue`: String hashing is seeded per launch,
        // so hashValue-based selection re-rolled every cover's gradient on each run (and
        // hashed the string on every render). Byte math is stable and effectively free.
        let bytes = trip.id.uuid
        let index = Int(bytes.0 ^ bytes.7 ^ bytes.15) % Self.palettes.count
        return Self.palettes[index].map { Color(hex: $0) }
    }

    private var gradient: some View {
        LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        // The gradient is the layout base: it has no intrinsic size, so it always fills
        // exactly the proposed frame. The photo is drawn as an *overlay* — overlays never
        // influence the parent's layout size, so a wide `scaledToFill` image can't make the
        // cover (and the scroll content above it) grow beyond the screen. `.clipped()` then
        // trims the overflow to the cover's bounds.
        gradient
            .overlay { photoOrGlyph }
            .clipped()
    }

    @ViewBuilder
    private var photoOrGlyph: some View {
        if let stored = trip.coverImageURL, !stored.isEmpty {
            CachedStorageImage(path: stored) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .loading:
                    ProgressView().tint(.white)
                case .failure:
                    glyph
                }
            }
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: "airplane.departure")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white.opacity(0.28))
    }
}

/// A colored initials avatar for a person (no image — initials only).
func avatar(_ person: Person, size: CGFloat) -> some View {
    InitialsAvatar(person: person, size: size)
}

/// Soft-tinted initials circle: the member's color as a light wash with tinted
/// initials, instead of a fully saturated disc. Lists full of members read much
/// calmer this way while each person keeps their identifying hue.
struct InitialsAvatar: View {
    let person: Person
    let size: CGFloat

    var body: some View {
        Text(person.initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(person.color)
            .frame(width: size, height: size)
            .background(person.color.opacity(0.16), in: .circle)
            .overlay(Circle().strokeBorder(person.color.opacity(0.28), lineWidth: 1))
    }
}

/// Avatar that shows a real photo when available.
/// Priority: local `imageData` (current user) → remote `person.avatarURL` → colored initials.
struct AvatarView: View {
    let person: Person
    var imageData: Data? = nil
    let size: CGFloat

    var body: some View {
        Group {
            if let data = imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else if let stored = person.avatarURL, !stored.isEmpty {
                CachedStorageImage(path: stored) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(.circle)
                    } else {
                        initialsCircle
                    }
                }
            } else {
                initialsCircle
            }
        }
    }

    private var initialsCircle: some View {
        InitialsAvatar(person: person, size: size)
    }
}

/// Formats a value with a currency code's symbol, e.g. `€12.50`.
func money(_ value: Double, _ code: String) -> String {
    "\(currencySymbol(code))\(String(format: "%.2f", value))"
}

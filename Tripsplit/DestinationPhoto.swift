import SwiftUI
import MapKit
import UIKit

/// Downsampled copies of the bundled destination photos.
///
/// The source assets are roughly 1400×746 JPEGs — about 4 MB each once decoded — and
/// the region directory can have a dozen of them on screen at once. Handing
/// `UIImage(named:)` straight to `Image` kept a full-resolution bitmap alive per
/// visible card, including 56pt search rows and 140pt grid tiles. Every card renders
/// through here instead, so what stays resident is sized for the frame it is drawn in.
final class DestinationImageCache {
    static let shared = DestinationImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 60
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    /// A bucketed thumbnail request. Sizes round up to 64pt steps so cards of
    /// similar-but-unequal widths share one bitmap, and so a resize of a point or two
    /// neither invalidates the cache nor restarts the load.
    struct Request: Hashable {
        let name: String
        /// Square box, in points, that the thumbnail has to cover. Square because
        /// `scaledToFill` needs coverage on both axes; the slight overshoot on wide
        /// frames buys far fewer distinct cache entries.
        let edge: CGFloat
        let scale: CGFloat

        init(name: String, size: CGSize, scale: CGFloat) {
            self.name = name
            self.edge = max(64, (max(size.width, size.height) / 64).rounded(.up) * 64)
            self.scale = scale
        }

        var cacheKey: NSString { "\(name)@\(Int(edge))@\(scale)x" as NSString }
    }

    func cached(_ request: Request) -> UIImage? {
        cache.object(forKey: request.cacheKey)
    }

    func thumbnail(_ request: Request) async -> UIImage? {
        if let hit = cached(request) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsampled(request)
        }.value
        guard let image else { return nil }
        cache.setObject(image, forKey: request.cacheKey, cost: Self.cost(of: image))
        return image
    }

    /// Draws the bundled asset once at the size it will actually be shown. The
    /// full-resolution decode happens here, off the main thread, and is released when
    /// the draw finishes — only the small copy is retained.
    ///
    /// `nonisolated` matters: the type picks up main-actor isolation by default, which
    /// would send the detached task's work straight back to the main thread and undo
    /// the point of doing it off it. Mirrors `ImageCache.decodedImage` in
    /// `ReceiptService.swift`.
    nonisolated private static func downsampled(_ request: Request) -> UIImage? {
        guard let source = UIImage(named: request.name) else { return nil }
        let ratio = max(request.edge / source.size.width, request.edge / source.size.height)
        // Nothing to gain from rendering a copy that's the same size or larger.
        guard ratio < 1 else { return source }

        let target = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = request.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    nonisolated private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// A featured destination, rendered as a photo-style card.
struct DestinationPhoto: View {
    let destination: Destination
    var symbolSize: CGFloat = 54

    @Environment(\.displayScale) private var displayScale
    @State private var size: CGSize = .zero
    @State private var image: UIImage?

    private var request: DestinationImageCache.Request? {
        guard destination.coverImagePath == nil, size.width > 0, size.height > 0 else { return nil }
        return .init(name: destination.imageName, size: size, scale: displayScale)
    }

    var body: some View {
        Color.clear
            .overlay {
                if let coverImagePath = destination.coverImagePath {
                    CachedStorageImage(path: coverImagePath) { phase in
                        if case .success(let photo) = phase {
                            photo
                                .resizable()
                                .scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .animation(.easeOut(duration: 0.15), value: image == nil)
            .clipped()
            // Measured rather than read from a GeometryReader so the view keeps its
            // existing, layout-neutral shape at all seven call sites.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .task(id: request) {
                guard let request else { return }
                // A cache hit resolves within the same frame, so scrolling back over a
                // card that has already been sized never flashes the placeholder.
                if let hit = DestinationImageCache.shared.cached(request) {
                    image = hit
                } else {
                    image = await DestinationImageCache.shared.thumbnail(request)
                }
            }
    }

    // Also what a destination with no bundled asset falls back to, so a future id
    // without a photo still degrades gracefully.
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: destination.symbol)
                .font(.app(size: symbolSize))
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}

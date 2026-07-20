import SwiftUI
import UIKit

// MARK: - Cover photo cropping

/// A just-picked photo waiting to be cropped; `Identifiable` so it can drive
/// a `.sheet(item:)` presentation.
struct CoverCropCandidate: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Full-screen crop step shown after picking a trip cover photo: pinch to zoom and
/// drag to reposition the image under a fixed cover-shaped window, then confirm.
/// The framed region is rendered out as a new `UIImage` via `onCrop`.
struct CoverCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Cover images render in wide cards (the 170pt-tall add-trip hero, trip rows),
    /// so the crop window matches that landscape shape.
    private static let cropAspect: CGFloat = 16.0 / 9.0

    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    /// The crop window's on-screen size, captured from layout so `crop()` can map
    /// gesture points back to image pixels.
    @State private var lastCropSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let cropSize = cropWindowSize(in: geo.size)
                ZStack {
                    Color.black.ignoresSafeArea()

                    imageLayer(cropSize: cropSize)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    // Dim everything outside the crop window.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .reverseMask {
                            RoundedRectangle(cornerRadius: 20)
                                .frame(width: cropSize.width, height: cropSize.height)
                        }
                        .allowsHitTesting(false)
                        .ignoresSafeArea()

                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: cropSize.width, height: cropSize.height)
                        .allowsHitTesting(false)

                    Text("Pinch to zoom, drag to reposition")
                        .font(.app(.footnote, .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.4), in: .capsule)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
                .gesture(dragGesture(cropSize: cropSize).simultaneously(with: zoomGesture(cropSize: cropSize)))
                .onAppear { lastCropSize = cropSize }
                .onChange(of: geo.size) { _, newSize in
                    lastCropSize = cropWindowSize(in: newSize)
                    offset = clampedOffset(offset, zoom: zoom, cropSize: lastCropSize)
                    steadyOffset = offset
                }
            }
            .navigationTitle("Adjust photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        crop()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cropWindowSize(in container: CGSize) -> CGSize {
        let width = max(container.width - 40, 1)
        return CGSize(width: width, height: width / Self.cropAspect)
    }

    /// The image size on screen at zoom 1: aspect-fill of the crop window.
    private func fittedSize(cropSize: CGSize) -> CGSize {
        let fill = max(cropSize.width / max(image.size.width, 1),
                       cropSize.height / max(image.size.height, 1))
        return CGSize(width: image.size.width * fill, height: image.size.height * fill)
    }

    private func imageLayer(cropSize: CGSize) -> some View {
        let fitted = fittedSize(cropSize: cropSize)
        return Image(uiImage: image)
            .resizable()
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(zoom)
            .offset(offset)
    }

    private func dragGesture(cropSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: steadyOffset.width + value.translation.width,
                                height: steadyOffset.height + value.translation.height)
            }
            .onEnded { _ in
                offset = clampedOffset(offset, zoom: zoom, cropSize: cropSize)
                steadyOffset = offset
            }
    }

    private func zoomGesture(cropSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(steadyZoom * value, 1), 6)
            }
            .onEnded { _ in
                steadyZoom = zoom
                offset = clampedOffset(offset, zoom: zoom, cropSize: cropSize)
                steadyOffset = offset
            }
    }

    /// Keeps the image covering the whole crop window (no gaps at the edges).
    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat, cropSize: CGSize) -> CGSize {
        let fitted = fittedSize(cropSize: cropSize)
        let shownWidth = fitted.width * zoom
        let shownHeight = fitted.height * zoom
        let maxX = max((shownWidth - cropSize.width) / 2, 0)
        let maxY = max((shownHeight - cropSize.height) / 2, 0)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    /// Renders the crop window's contents into a new image (capped at 1600px wide —
    /// the same budget `UploadImagePreparation` uses for cover uploads).
    private func crop() {
        let outputWidth: CGFloat = 1_600
        let screenCrop = lastCropSize
        guard screenCrop.width > 0 else { return onCrop(image) }
        let fitted = fittedSize(cropSize: screenCrop)
        let shown = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let originX = (screenCrop.width - shown.width) / 2 + offset.width
        let originY = (screenCrop.height - shown.height) / 2 + offset.height
        let renderScale = outputWidth / screenCrop.width
        let outputSize = CGSize(width: outputWidth, height: outputWidth / Self.cropAspect)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(x: originX * renderScale,
                                  y: originY * renderScale,
                                  width: shown.width * renderScale,
                                  height: shown.height * renderScale))
        }
        onCrop(cropped)
    }
}

private extension View {
    /// Punches `mask` out of the view (inverse mask), used for the crop-window dimming.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

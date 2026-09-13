import SwiftUI

/// A single-ink passport seal. Illustration assets contain only geometry; place names,
/// country labels and actual visit dates remain live text in every profile/share size.
struct PlaceStampBadge: View {
    let place: VisitedPlace
    var size: CGFloat = 150
    @Environment(\.locale) private var locale

    private let design: PassportStampDesign?
    private let theme: PlaceTheme
    private let sceneSeed: UInt64
    private let pageStock: Color?
    private let compact: Bool
    private let entryDate: Date?

    init(place: VisitedPlace, size: CGFloat = 150, page: Color? = nil, compact: Bool = false,
         entryDate: Date? = nil) {
        self.place = place
        self.size = size
        self.pageStock = page
        self.compact = compact
        self.entryDate = entryDate
        design = PassportStampDesign.matching(place.name)
        theme = PlaceTheme.inferred(from: place.name)
        var seed: UInt64 = 5381
        for scalar in place.id.unicodeScalars { seed = seed &* 33 &+ UInt64(scalar.value) }
        sceneSeed = seed
    }

    private var scale: CGFloat { size / 240 }
    private var square: Bool { design?.isSquare ?? false }
    private var ink: Color {
        (design?.ink ?? StampInk.allCases[Int(sceneSeed % UInt64(StampInk.allCases.count))]).color
    }
    private var visitDate: Date? { entryDate ?? place.date }
    private var dateText: String? {
        visitDate.map {
            $0.formatted(Date.FormatStyle().month(.abbreviated).year().locale(locale)).uppercased()
        }
    }
    private var regionText: String {
        if let code = design?.countryCode {
            if code == "US", locale.language.languageCode?.identifier == "en" { return "USA" }
            return (locale.localizedString(forRegionCode: code) ?? code).uppercased()
        }
        let region = PlaceRegion.regionWords(in: place.name).joined(separator: " ")
        return (region.isEmpty ? Bundle.main.localizedString(forKey: theme.label, value: theme.label, table: nil) : region)
            .uppercased()
    }
    private var accessibilityText: String {
        guard let visitDate else { return place.name }
        return "\(place.name), \(visitDate.formatted(Date.FormatStyle().month(.wide).year().locale(locale)))"
    }

    var body: some View {
        ZStack {
            PassportStampOutline(square: square)
                .fill(pageStock == nil ? Color(light: 0xFCFAF3, dark: 0x181510) : .clear)
            PassportStampOutline(square: square)
                .stroke(ink, lineWidth: 3.8 * scale)
            PassportStampOutline(square: square, inner: true)
                .stroke(ink, lineWidth: 1.1 * scale)

            Image(design?.assetName ?? theme.stampAssetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(ink)
                .accessibilityHidden(true)

            if square {
                stampText(place.shortName.uppercased(), fontSize: 18, tracking: 2.5, width: 174)
                    .position(x: size / 2, y: 43 * scale)
                stampText(regionText, fontSize: 10, tracking: 2.8, width: 170)
                    .position(x: size / 2, y: 201 * scale)
            } else {
                StampArcText(text: place.shortName.uppercased(), color: ink,
                             fontSize: (place.shortName.count < 13 ? 14 : 12.5) * scale,
                             weight: .bold, radiusRatio: 0.76, maxAngle: .pi * 0.86,
                             letterSpacing: scale)
                StampArcText(text: regionText, color: ink, fontSize: 9.5 * scale,
                             weight: .bold, radiusRatio: 0.74, atBottom: true,
                             maxAngle: .pi * 0.82, letterSpacing: scale)
                ForEach([28.0, 212.0], id: \.self) { x in
                    Circle().fill(ink)
                        .frame(width: 5.2 * scale, height: 5.2 * scale)
                        .position(x: x * scale, y: 122 * scale)
                }
            }

            if let dateText {
                Path { path in
                    path.move(to: CGPoint(x: 76 * scale, y: 169 * scale))
                    path.addLine(to: CGPoint(x: 164 * scale, y: 169 * scale))
                }
                .stroke(ink, lineWidth: 1.3 * scale)
                stampText(dateText, fontSize: 11, tracking: 1.3, width: 132)
                    .position(x: size / 2, y: 181 * scale)
            }
        }
        .frame(width: size, height: size)
        // Compact rows stay almost level; large passport layouts retain a hand-stamped tilt.
        .rotationEffect(.degrees(compact ? Double(sceneSeed % 3) - 1 : Double(sceneSeed % 5) - 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private func stampText(_ value: String, fontSize: CGFloat, tracking: CGFloat, width: CGFloat) -> some View {
        Text(verbatim: value)
            .font(.app(size: fontSize * scale, weight: .bold))
            .tracking(tracking * scale)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .frame(width: width * scale)
    }
}

private struct PassportStampOutline: Shape {
    var square: Bool
    var inner = false

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 240
        if !square {
            let inset: CGFloat = inner ? 18 : 11
            return Path(ellipseIn: CGRect(x: inset * scale, y: inset * scale,
                                          width: (240 - 2 * inset) * scale,
                                          height: (240 - 2 * inset) * scale))
        }
        let edge: CGFloat = inner ? 24 : 17
        let corner: CGFloat = inner ? 40 : 38
        let points: [CGPoint] = [
            .init(x: corner, y: edge), .init(x: 240 - corner, y: edge),
            .init(x: 240 - edge, y: corner), .init(x: 240 - edge, y: 240 - corner),
            .init(x: 240 - corner, y: 240 - edge), .init(x: corner, y: 240 - edge),
            .init(x: edge, y: 240 - corner), .init(x: edge, y: corner)
        ]
        return Path { path in
            path.addLines(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
            path.closeSubpath()
        }
    }
}

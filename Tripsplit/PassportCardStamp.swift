import SwiftUI

/// The outline a place is stamped in on the passport card. Real passports fill with
/// stamps of every shape, so the card's three never have to match.
enum PassportStampShape: CaseIterable {
    case round, entry, hexagon, oval, octagon, arch, ticket, banner, postage
}

/// Which outline an illustration is struck in and where it sits inside it: the
/// 240-unit artwork scaled by `scale`, then moved by `x`/`y`. Each fit was measured so
/// every stroke of the illustration clears the outline's inner border — change an
/// illustration or its shape and the fit has to be measured again.
struct PassportStampFit {
    let shape: PassportStampShape
    let scale: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension PassportStampDesign {
    var cardFit: PassportStampFit {
        switch self {
        case .paris: .init(shape: .entry, scale: 0.85, x: -37.3, y: 14.2)
        case .nara: .init(shape: .entry, scale: 0.9, x: -32.6, y: 5.4)
        case .newYork: .init(shape: .arch, scale: 1.07, x: -16.5, y: -10.2)
        case .london: .init(shape: .arch, scale: 1.06, x: -7.2, y: -8.6)
        case .rome: .init(shape: .oval, scale: 0.92, x: 10.1, y: -2.3)
        case .tahoe: .init(shape: .oval, scale: 0.98, x: -3.4, y: 5.9)
        case .sanFrancisco: .init(shape: .ticket, scale: 0.91, x: -1.7, y: 17.1)
        case .miami: .init(shape: .ticket, scale: 0.92, x: -7.3, y: 10.9)
        case .kyoto: .init(shape: .octagon, scale: 0.91, x: -3.2, y: 14.8)
        case .seoul: .init(shape: .octagon, scale: 1.03, x: -12.2, y: 1.4)
        case .yosemite: .init(shape: .hexagon, scale: 1.04, x: -7.7, y: -4.7)
        case .honolulu: .init(shape: .hexagon, scale: 1.04, x: 4.6, y: -6.8)
        case .sydney: .init(shape: .banner, scale: 1.01, x: -5, y: -36)
        case .singapore: .init(shape: .banner, scale: 0.98, x: 9.4, y: -26.8)
        case .chicago: .init(shape: .round, scale: 0.92, x: 7.6, y: 10.2)
        case .osaka: .init(shape: .round, scale: 0.92, x: 18.8, y: 5.9)
        case .tokyo: .init(shape: .postage, scale: 0.93, x: 18.6, y: -10.1)
        case .seattle: .init(shape: .postage, scale: 0.95, x: 7.1, y: -13.5)
        }
    }
}

extension PlaceTheme {
    /// Places without a landmark keep their generic illustration. The entry rectangle
    /// is left out: its name column is too narrow for an arbitrary place name. Forests
    /// take the ticket for the same reason — "Redwood National Park" needs its width.
    var cardFit: PassportStampFit {
        switch self {
        case .city: .init(shape: .round, scale: 1.01, x: -1.5, y: -24.7)
        case .mountain: .init(shape: .hexagon, scale: 0.99, x: 1, y: 1.6)
        case .lake: .init(shape: .oval, scale: 0.98, x: -3.4, y: 5.9)
        case .coast: .init(shape: .banner, scale: 0.99, x: -3.3, y: -31.4)
        case .island: .init(shape: .ticket, scale: 0.8, x: 12.6, y: 31.1)
        case .desert: .init(shape: .ticket, scale: 0.82, x: 9.1, y: 30.3)
        case .forest: .init(shape: .ticket, scale: 0.86, x: 4.4, y: 24.7)
        case .snow: .init(shape: .arch, scale: 1.01, x: 0, y: -0.3)
        case .historic: .init(shape: .postage, scale: 1.09, x: -10.3, y: -49.3)
        }
    }
}

/// One place stamped on the passport card: its landmark (or its generic illustration)
/// inside one of nine outlines, with the place, region and date as live text.
///
/// Drawn in the same 240-unit square as `PlaceStampBadge` and laid out at its real size
/// — never `scaleEffect`, which keeps the unscaled footprint. Shapes, template images,
/// text and `Canvas` only, so `ImageRenderer` rasterizes all of it.
struct PassportCardStamp: View {
    let place: VisitedPlace
    let ink: Color
    /// The visit date, already written in the cover's convention. Nil for an undated place.
    let dateText: String?
    /// The cover's display face at a given point size.
    let display: (CGFloat) -> Font
    var size: CGFloat = 96
    @Environment(\.locale) private var locale

    private let design: PassportStampDesign?
    private let theme: PlaceTheme

    init(place: VisitedPlace, ink: Color, dateText: String?, size: CGFloat = 96,
         display: @escaping (CGFloat) -> Font) {
        self.place = place
        self.ink = ink
        self.dateText = dateText
        self.size = size
        self.display = display
        design = PassportStampDesign.matching(place.name)
        theme = PlaceTheme.inferred(from: place.name)
    }

    private var k: CGFloat { size / 240 }
    private var fit: PassportStampFit { design?.cardFit ?? theme.cardFit }
    private var name: String { place.shortName.uppercased() }

    /// The country for a landmark place, else whatever follows the place's first comma.
    private var regionText: String? {
        if let code = design?.countryCode {
            if code == "US", locale.language.languageCode?.identifier == "en" { return "USA" }
            return (locale.localizedString(forRegionCode: code) ?? code).uppercased()
        }
        let parts = place.name.split(separator: ",")
        guard parts.count > 1 else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// "FRANCE · 14 APR 2026", or whichever half the place has.
    private var regionAndDate: String {
        [regionText, dateText].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            outline
            Image(design?.assetName ?? theme.stampAssetName)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(ink)
                .frame(width: 240 * fit.scale * k, height: 240 * fit.scale * k)
                .position(x: (fit.x + 120 * fit.scale) * k, y: (fit.y + 120 * fit.scale) * k)
            lettering
        }
        .frame(width: size, height: size)
    }

    // MARK: Outlines

    @ViewBuilder
    private var outline: some View {
        switch fit.shape {
        case .round:
            stroke(ellipse(110, 110), 5)
            stroke(ellipse(72, 72), 1.5)
            ForEach([29.0, 211.0], id: \.self) { x in
                Circle().fill(ink).frame(width: 7 * k, height: 7 * k).position(x: x * k, y: 120 * k)
            }
        case .entry:
            stroke(roundedRect(x: 10, y: 38, width: 220, height: 164, radius: 14), 5)
            stroke(roundedRect(x: 19, y: 47, width: 202, height: 146, radius: 8), 1.5)
            stroke(rule(from: 127, to: 213, y: 124), 1.5)
        case .hexagon:
            stroke(polygon([(65, 24.7), (175, 24.7), (230, 120), (175, 215.3), (65, 215.3), (10, 120)]), 5)
            stroke(polygon([(70.2, 33.7), (169.8, 33.7), (219.6, 120), (169.8, 206.3), (70.2, 206.3),
                            (20.4, 120)]), 1.5)
        case .oval:
            stroke(ellipse(110, 86), 5)
            stroke(ellipse(101, 77), 1.5, dash: [2, 5])
        case .octagon:
            stroke(polygon([(38, 17), (202, 17), (223, 38), (223, 202), (202, 223), (38, 223), (17, 202),
                            (17, 38)]), 5)
            stroke(polygon([(41, 26), (199, 26), (214, 41), (214, 199), (199, 214), (41, 214), (26, 199),
                            (26, 41)]), 1.5)
            stroke(rule(from: 76, to: 164, y: 172), 1.5)
        case .arch:
            stroke(arch(left: 32, bottom: 224, radius: 88), 5)
            stroke(arch(left: 41, bottom: 215, radius: 79), 1.5)
            stroke(rule(from: 54, to: 186, y: 170), 1.5)
        case .ticket:
            stroke(ticket, 5)
            stroke(rule(from: 30, to: 210, y: 80), 1.5, dash: [2, 5])
            stroke(rule(from: 30, to: 210, y: 170), 1.5, dash: [2, 5])
        case .banner:
            stroke(ellipse(110, 110), 5)
            stroke(ellipse(100, 100), 3, dash: [0.1, 7])
            stroke(rule(from: 33, to: 207, y: 146), 1.5)
            stroke(rule(from: 46, to: 194, y: 174), 1.5)
        case .postage:
            // A dotted edge standing in for a postage stamp's perforations.
            stroke(roundedRect(x: 34, y: 12, width: 172, height: 216, radius: 3), 5, dash: [0.1, 9.7])
            stroke(roundedRect(x: 44, y: 22, width: 152, height: 196, radius: 0), 2.5)
            stroke(rule(from: 52, to: 188, y: 164), 1.5)
        }
    }

    /// A path given in stamp units, stroked at the stamp's real size.
    private func stroke(_ path: Path, _ width: CGFloat, dash: [CGFloat] = []) -> some View {
        path.applying(CGAffineTransform(scaleX: k, y: k))
            .stroke(ink, style: StrokeStyle(lineWidth: width * k, lineCap: .round, lineJoin: .round,
                                            dash: dash.map { $0 * k }))
    }

    private func ellipse(_ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: 120 - rx, y: 120 - ry, width: rx * 2, height: ry * 2))
    }

    private func roundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius)
    }

    private func rule(from x1: CGFloat, to x2: CGFloat, y: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x1, y: y))
            path.addLine(to: CGPoint(x: x2, y: y))
        }
    }

    private func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { path in
            path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
        }
    }

    /// Straight sides under a half-round head.
    private func arch(left: CGFloat, bottom: CGFloat, radius: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: left, y: 108))
            path.addArc(center: CGPoint(x: 120, y: 108), radius: radius,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: 240 - left, y: bottom))
            path.closeSubpath()
        }
    }

    /// A rectangle with a bite out of each corner, like a punched ticket.
    private var ticket: Path {
        Path { path in
            path.move(to: CGPoint(x: 26, y: 42))
            path.addLine(to: CGPoint(x: 214, y: 42))
            path.addArc(center: CGPoint(x: 228, y: 42), radius: 14,
                        startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: 228, y: 184))
            path.addArc(center: CGPoint(x: 228, y: 198), radius: 14,
                        startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
            path.addLine(to: CGPoint(x: 26, y: 198))
            path.addArc(center: CGPoint(x: 12, y: 198), radius: 14,
                        startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
            path.addLine(to: CGPoint(x: 12, y: 56))
            path.addArc(center: CGPoint(x: 12, y: 42), radius: 14,
                        startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.closeSubpath()
        }
    }

    // MARK: Lettering

    @ViewBuilder
    private var lettering: some View {
        switch fit.shape {
        case .round:
            arc(name, size: 19, radius: 80, serif: true, maxAngle: 2.5)
            arc(regionAndDate, size: 11, radius: 97, atBottom: true, maxAngle: 2.4)
        case .entry:
            line(Text("Admitted"), font: mono(9.5), tracking: 2.5, width: 86, x: 170,
                 baseline: 82, size: 9.5)
            line(Text(verbatim: name), font: display(20 * k), tracking: 1, width: 88, x: 170, baseline: 113,
                 size: 20)
            line(Text(verbatim: dateText ?? ""), font: mono(12), tracking: 0.5, width: 88, x: 170,
                 baseline: 146, size: 12)
            line(Text(verbatim: regionText ?? ""), font: mono(9.5), tracking: 1.5, width: 88, x: 170,
                 baseline: 165, size: 9.5)
        case .hexagon:
            line(Text(verbatim: name), font: display(16 * k), tracking: 2, width: 114, baseline: 63, size: 16)
            line(Text(verbatim: regionText ?? ""), font: mono(10), tracking: 1.5, width: 120, baseline: 179,
                 size: 10)
            line(Text(verbatim: dateText ?? ""), font: mono(11), tracking: 1, width: 100, baseline: 196,
                 size: 11)
        case .oval:
            // An ellipse's head and foot are near enough to circles of its own curvature
            // (rx² / ry) that circular arc text follows them within a unit or two.
            arc(name, size: 15, radius: 121.7, center: 183.7, serif: true, maxAngle: 1.05)
            arc(regionAndDate, size: 10, radius: 127.1, center: 63.9, atBottom: true, maxAngle: 1.3)
        case .octagon:
            line(Text(verbatim: name), font: display(18 * k), tracking: 2.5, width: 150, baseline: 54, size: 18)
            line(Text(verbatim: dateText ?? ""), font: mono(12), tracking: 1, width: 130, baseline: 188,
                 size: 12)
            line(Text(verbatim: regionText ?? ""), font: mono(10), tracking: 2, width: 150, baseline: 205,
                 size: 10)
        case .arch:
            line(Text(verbatim: name), font: display(16 * k), tracking: 2, width: 140, baseline: 186, size: 16)
            line(Text(verbatim: regionText ?? ""), font: mono(8), tracking: 1.5, width: 140, baseline: 198,
                 size: 8)
            line(Text(verbatim: dateText ?? ""), font: mono(9), tracking: 1, width: 140, baseline: 210, size: 9)
        case .ticket:
            line(Text(verbatim: name), font: display(17 * k), tracking: 2.5, width: 172, baseline: 71, size: 17)
            line(Text(verbatim: regionAndDate), font: mono(10), tracking: 1.5, width: 172, baseline: 188,
                 size: 10)
        case .banner:
            line(Text(verbatim: name), font: display(17 * k), tracking: 2.5, width: 136, baseline: 166, size: 17)
            line(Text(verbatim: dateText ?? regionText ?? ""), font: mono(10.5), tracking: 1.5, width: 104,
                 baseline: 192, size: 10.5)
        case .postage:
            line(Text(verbatim: name), font: display(17 * k), tracking: 2, width: 136, baseline: 186, size: 17)
            line(Text(verbatim: regionAndDate), font: mono(9.5), tracking: 1, width: 136, baseline: 205,
                 size: 9.5)
        }
    }

    private func mono(_ units: CGFloat) -> Font {
        .system(size: units * k, weight: .bold, design: .monospaced)
    }

    /// One straight line of lettering, centred on `x` with its baseline at `baseline`
    /// (stamp units). It shrinks before it would cross the outline at `width`.
    private func line(_ text: Text, font: Font, tracking: CGFloat, width: CGFloat, x: CGFloat = 120,
                      baseline: CGFloat, size units: CGFloat) -> some View {
        text.font(font)
            .textCase(.uppercase)
            .tracking(tracking * k)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(width: width * k)
            .position(x: x * k, y: (baseline - units * 0.36) * k)
    }

    /// Lettering on a circular arc whose baseline has `radius`, about a centre on the
    /// stamp's vertical axis at `center`. Top arcs read outward, bottom arcs inward.
    private func arc(_ text: String, size units: CGFloat, radius: CGFloat, center: CGFloat = 120,
                     serif: Bool = false, atBottom: Bool = false, maxAngle: CGFloat) -> some View {
        // `StampArcText` centres each glyph on its radius, so move from the baseline to
        // the middle of the capitals, and leave the canvas room for the rest of the glyph.
        let middle = radius + (atBottom ? -0.36 : 0.36) * units
        let side = (radius + 24) * 2
        return StampArcText(text: text, color: ink, fontSize: units * k, weight: .bold,
                            radiusRatio: middle * 2 / side, atBottom: atBottom, maxAngle: maxAngle,
                            letterSpacing: (serif ? 3 : 2) * k,
                            font: serif ? display : { .system(size: $0, weight: .bold, design: .monospaced) })
            .frame(width: side * k, height: side * k)
            .position(x: 120 * k, y: center * k)
    }
}

import SwiftUI
import CoreImage
import UIKit

/// The invitation sent with a shared profile, whether it goes out as the card picture or
/// as the `tripsplit://` link — one voice for both. (The card's printed footer and the
/// mail subject stay on the short "Add me on TripSplit"; neither has room for a sentence.)
let profileInvite: LocalizedStringKey =
    "Hey! Add me on TripSplit and we'll share many journeys together while staying on budget!"

/// The profile data a share card is drawn from, held while the preview sheet is up. The
/// picture itself is rendered in the sheet, which is where the theme is chosen; the
/// owner's card choices are read live from the profile there, so customizing re-renders.
struct ShareCardItem: Identifiable {
    let id = UUID()
    let name: String
    let imageData: Data?
    /// The avatar's Storage path, used when this device has no local copy of the photo —
    /// signing in on a new device leaves `imageData` nil while the picture still exists.
    let avatarPath: String?
    /// Every number the card can headline; the owner picks which three it prints.
    let statValues: [PassportStat: Int]
    let places: [VisitedPlace]
    /// The profile deep link the card's QR code encodes; nil until the token has loaded.
    let shareURL: URL?
}

/// The theme a share card is printed in. Each takes its cues from a real travel document
/// — Japan's passport, the US passport, the US national-parks passport book — without
/// copying one: the emblem is TripSplit's own pin and no country is named, so the card
/// can't be mistaken for a government document.
///
/// Raw values are the country covers these replaced, so a saved cover (and a friend on an
/// older build reading it) keeps resolving. The other retired covers fall back to
/// `federal` wherever a raw value is read.
///
/// Fixed hex values, not `Color(light:dark:)`: the card is a printed object and renders
/// the same whatever appearance the app is in.
enum ShareCardCover: String, CaseIterable, Identifiable {
    case kiku = "japan", federal = "unitedStates", trailhead = "mexico"

    var id: Self { self }

    /// Theme names are proper nouns, shown as written.
    var label: LocalizedStringKey {
        switch self {
        case .kiku: "Kiku"
        case .federal: "Federal"
        case .trailhead: "Trailhead"
        }
    }

    /// Printed at the head of the page, opposite its title.
    var edition: LocalizedStringKey {
        switch self {
        case .kiku: "Kiku edition"
        case .federal: "Federal edition"
        case .trailhead: "Trailhead edition"
        }
    }

    /// The cover stock, lit from the top-left the way a leather cover catches light.
    ///
    /// Three stops rather than two: the card is bound in the cover on all four sides, and a
    /// two-stop gradient stretched over that much board bands visibly across its middle.
    var colors: [Color] {
        switch self {
        case .kiku: [Color(hex: 0xB63039), Color(hex: 0x7B1A21), Color(hex: 0x420C11)]
        case .federal: [Color(hex: 0x2A4677), Color(hex: 0x152A4B), Color(hex: 0x08111F)]
        case .trailhead: [Color(hex: 0x2F6A50), Color(hex: 0x1F4D3A), Color(hex: 0x0C241A)]
        }
    }

    /// The embossing: gold foil, or cream on the green board.
    var foil: Color {
        switch self {
        case .trailhead: Color(hex: 0xF1E3BF)
        default: Color(hex: 0xE3C486)
        }
    }

    /// The cover's deepest tone, for type printed on the page and for the band the page's
    /// header is reversed out of.
    var ink: Color { colors.last ?? .black }

    /// The page stock: washi, bond and kraft, each mixed toward its cover's hue.
    var paper: Color {
        switch self {
        case .kiku: Color(hex: 0xFCF2EB)
        case .federal: Color(hex: 0xEEF1F7)
        case .trailhead: Color(hex: 0xF3EAD7)
        }
    }

    /// The second ink Federal's security printing runs in, set against the cover so the
    /// two families of line work interfere instead of merging.
    var lineInk: Color { Color(hex: 0xB3543A) }

    /// The inks places are stamped in, cycled across the stamps. The first is also the
    /// personal seal's.
    var stampInks: [Color] {
        switch self {
        case .kiku: [Color(hex: 0xC8322B)]
        case .federal: [Color(hex: 0x1F3F7A), Color(hex: 0xA8322E)]
        case .trailhead: [Color(hex: 0x1F4D3A), Color(hex: 0x8A3B1E), Color(hex: 0x2F5F7A)]
        }
    }
}

/// The profile rendered as a picture: a passport page someone can post anywhere, unlike
/// the `tripsplit://` link, which only does anything for people who already have the app.
///
/// One layout in three themes. What makes a card its owner's is on the page rather than
/// in the theme: the places they chose to stamp, the three numbers they chose to headline,
/// their own line at the foot, and a personal seal no other name produces.
///
/// The page is *mounted* in the cover, which frames it on all four sides, prints its own
/// stock in the cover's tone, and reverses the page header out of a band of the cover's
/// ink — shown as a spine down one edge, the theme changed a thirteenth of the picture.
///
/// Deliberately built from gradients, shapes and `Canvas` — `ImageRenderer` cannot
/// rasterize glass, materials or blurs, which come out empty. Nothing is shrunk with
/// `scaleEffect` either: a scaled view keeps its *unscaled* layout footprint, which is
/// what made an older card's stamps overlap the stats strip.
struct ProfileShareCard: View {
    let name: String
    /// Already resolved by the sheet — a photo the card had to load itself would still be
    /// downloading when `ImageRenderer` rasterizes it, and print as the monogram.
    let photo: UIImage?
    /// Every visited place; the owner's featured ones are stamped, else the first few.
    let places: [VisitedPlace]
    /// The theme: its board, its paper, its type and its stamps.
    var cover: ShareCardCover = .federal
    /// Encoded as the QR code in the page's corner, so a posted card actually connects.
    var shareURL: URL?
    /// The owner's home base, travel styles and favorite place, and their card choices.
    var showcase = ProfileShowcase()
    var statValues: [PassportStat: Int] = [:]

    /// 4:5. Deliberately not the old 0.61: that was too tall for a feed, which cropped it,
    /// and too short for a story, which letterboxed it. `ImageRenderer` rasterizes at 3x,
    /// so the shared picture is 1080x1350.
    private let width: CGFloat = 360
    private let height: CGFloat = 450
    /// How much cover shows around the mounted page — the border of the passport's own
    /// board, and the first thing the card is read by.
    private let margin: CGFloat = 14
    /// The deeper band of cover above the page, carrying the foil a cover is embossed with.
    private let coverBand: CGFloat = 42

    private var style: PassportCardStyle { showcase.card }
    private var ink: Color { cover.ink }
    private var page: Color { cover.paper }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    /// The owner's featured places in the order they picked them, else the first few.
    /// Three at most — as many as the band holds at a size where a stamp is still read.
    private var stamped: [VisitedPlace] {
        let picked = style.featuredPlaces.compactMap { name in
            places.first { $0.id == name.lowercased() }
        }
        return Array((picked.isEmpty ? places : picked).prefix(PassportCardStyle.stampLimit))
    }

    /// A document number, in the spirit of a passport. Derived from the name (djb2, the
    /// same stable hash the stamps use) so re-sharing produces the same card.
    private var serial: String {
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars { hash = hash &* 33 &+ UInt64(scalar.value) }
        return String(format: "%04d", hash % 10000)
    }

    /// A passport has an issue date, and the earliest dated trip is the only true one
    /// available. Falls back to today for a profile whose trips carry no dates.
    private var issued: Date { places.compactMap(\.date).min() ?? .now }

    private var homeBase: String { showcase.homeBase.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            coverWordmark
            pageView
                .background { pageStock }
                .clipShape(pageShape)
                // The recess the page is mounted in, and the foil rule around it. A real
                // drop shadow would be a blur, and `ImageRenderer` rasterizes blurs empty —
                // a dark edge a hair wider than the page does the same work here.
                .background { pageShape.fill(.black.opacity(0.3)).padding(-1.5) }
                .overlay { pageShape.strokeBorder(cover.foil.opacity(0.45), lineWidth: 0.8) }
                .padding(.horizontal, margin)
                .padding(.bottom, margin)
        }
        .frame(width: width, height: height)
        .background { coverStock }
        .clipped()
    }

    /// Barely rounded: the leaf of a bound document, not a card.
    private var pageShape: RoundedRectangle { .rect(cornerRadius: 5, style: .continuous) }

    /// The cover the card is bound in: the stock, its grain, and the light a leather board
    /// catches across the corner it is lit from.
    private var coverStock: some View {
        ZStack {
            LinearGradient(colors: cover.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.16, y: 0.04),
                           startRadius: 0, endRadius: width * 0.95)
            leatherGrain
        }
    }

    /// What the cover carries, foiled into the board: TripSplit's pin where a state
    /// passport has its emblem, the wordmark, and the document number.
    private var coverWordmark: some View {
        HStack(spacing: 9) {
            PassportPinEmblem(foil: cover.foil.opacity(0.92), board: cover.colors[1])
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "TRIPSPLIT")
                    .font(display(13))
                    .tracking(3)
                Text("Travel passport")
                    .font(.system(size: 6.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(2.4)
            }
            .fixedSize()
            Spacer(minLength: 0)
            Text(verbatim: "No. TS \(serial)").font(document(8, .medium))
        }
        .foregroundStyle(cover.foil.opacity(0.92))
        .padding(.horizontal, margin + 2)
        .frame(height: coverBand)
    }

    /// The paper the page is printed on: the theme's stock under its own ground pattern —
    /// wave crests, engine-turned line work, or contour lines.
    private var pageStock: some View {
        ZStack {
            page
            switch cover {
            case .kiku: waveCrests
            case .federal: guilloche
            case .trailhead: contours
            }
        }
    }

    private var pageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if cover == .trailhead { regionBand }
            VStack(alignment: .leading, spacing: 0) {
                identity
                counts
                    .padding(.top, 10)
                    .overlay(alignment: .top) { rule }
                    .padding(.top, 12)
                visaBand
                footer
                if cover == .federal { machineReadableZone.padding(.top, 8) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }

    private var rule: some View {
        Rectangle().fill(ink.opacity(0.3)).frame(height: 1)
    }

    /// The page's title line, reversed out of a band of the cover's ink across the head of
    /// the page: the band is what carries the theme *into* the page rather than leaving it
    /// as a border around one.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Traveler record")
            Spacer()
            Text(cover.edition).opacity(0.72)
        }
        .font(.system(size: 8.5, weight: .bold))
        .textCase(.uppercase)
        .tracking(1.5)
        .foregroundStyle(page)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(ink)
        .overlay(alignment: .bottom) { Rectangle().fill(cover.foil.opacity(0.4)).frame(height: 0.8) }
    }

    /// The parks passport book colour-codes its regions down the page edge; Trailhead
    /// carries the same five-colour band under its header.
    private var regionBand: some View {
        HStack(spacing: 0) {
            ForEach([0xB4532A, 0xD9A441, 0x3F7D5C, 0x2F6E8E, 0x6B4E7D] as [UInt32], id: \.self) { hex in
                Rectangle().fill(Color(hex: hex))
            }
        }
        .frame(height: 5)
    }

    /// Portrait, the name block beside it, and the personal seal.
    ///
    /// One `Name` field rather than a passport's own `Surname` / `Given names` pair: which
    /// half of a display name is the family name is not knowable — "Trần Văn Khôi" puts it
    /// first and "Jennie Tran" puts it last — and guessing wrong prints someone's name
    /// backwards on the thing they are about to post.
    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            portrait
            VStack(alignment: .leading, spacing: 9) {
                field("Name") {
                    Text(verbatim: name)
                        .font(display(19))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.55)
                }
                HStack(alignment: .top, spacing: 10) {
                    if style.showsHomeBase, !homeBase.isEmpty {
                        field("Home base") { documentValue(Text(verbatim: homeBase)) }
                    } else {
                        field("Passport no.") { documentValue(Text(verbatim: "TS\(serial)")) }
                    }
                    field("Traveling since") { documentValue(Text(verbatim: monthYear(issued))) }
                }
            }
            .padding(.top, 2)
            if style.showsSeal {
                let seal = style.seal(for: name)
                PassportSeal(outline: seal.frame, motif: seal.motif, initials: initials,
                             color: cover.stampInks[0])
                    .frame(width: 46, height: 46)
                    .opacity(0.85)
            }
        }
    }

    /// A data-page value in one of the paired columns: allowed to shrink rather than wrap,
    /// because a long home base would otherwise take a second line the row has no room for.
    private func documentValue(_ value: Text) -> some View {
        value
            .font(document(11))
            .textCase(.uppercase)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private func monthYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// Rectangular, because a passport photo is — a circular portrait is the single
    /// element that most makes a card read as a social profile rather than a document.
    private var portrait: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Rectangle().fill(ink.opacity(0.08)).overlay {
                    Text(verbatim: initials)
                        .font(display(22))
                        .foregroundStyle(ink.opacity(0.8))
                }
            }
        }
        .frame(width: 60, height: 78)
        .clipped()
        .overlay(Rectangle().strokeBorder(ink.opacity(0.32), lineWidth: 0.75))
    }

    /// The three numbers the owner chose to headline.
    private var counts: some View {
        HStack(spacing: 0) {
            ForEach(Array(style.headlineStats.enumerated()), id: \.element) { index, stat in
                if index > 0 { Rectangle().fill(ink.opacity(0.2)).frame(width: 1, height: 30) }
                VStack(spacing: 2) {
                    Text(verbatim: "\(statValues[stat] ?? 0)")
                        .font(display(24))
                        .foregroundStyle(ink)
                    Text(stat.label)
                        .font(.system(size: 7, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.9)
                        .foregroundStyle(ink.opacity(0.55))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// The open middle of the page, and the only part of it that stretches: whatever the
    /// blocks above and below don't use is visa space, which is what a passport page does
    /// with its middle too. Tilts and offsets alternate because stamps go onto a page one
    /// at a time, by hand, and a level row of them reads as a chart.
    private var visaBand: some View {
        GeometryReader { band in
            // As large as a third of the band allows, and short enough that a tilted
            // stamp stays clear of the rules above and below it.
            let size = max(0, min((band.size.width - 12) / 3, band.size.height - 12, 100))
            HStack(spacing: 6) {
                ForEach(Array(stamped.enumerated()), id: \.offset) { index, place in
                    PassportCardStamp(place: place, ink: cover.stampInks[index % cover.stampInks.count],
                                      dateText: place.date.map(stampDate), size: size, display: display)
                        .opacity(0.86)
                        .rotationEffect(.degrees([-6, 4, -3][index % 3]))
                        .offset(y: [-2, 3, -1][index % 3])
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: band.size.width, height: band.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The date in the theme's stamp convention: year-first, day-first, or month-first.
    private func stampDate(_ date: Date) -> String {
        switch cover {
        case .kiku:
            let parts = Calendar.current.dateComponents([.year, .month], from: date)
            return String(format: "%04d.%02d", parts.year ?? 0, parts.month ?? 0)
        case .federal:
            return date.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year()).uppercased()
        case .trailhead:
            return date.formatted(.dateTime.month(.abbreviated).day(.twoDigits).year()).uppercased()
        }
    }

    /// The owner's own line on the left, the profile's QR code on the right. The QR is
    /// what makes a posted card connect: scanning it opens this profile in the app.
    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            field(style.personalLine.label) {
                personalLine
                    .font(display(11))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if style.showsQR, let qr = qrImage {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .padding(3)
                    .background(.white)
                    .overlay(Rectangle().strokeBorder(ink.opacity(0.32), lineWidth: 0.75))
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { rule }
    }

    /// Travel styles, the motto, or the favorite place — a dash when the chosen one is
    /// still empty, so the field never prints blank.
    private var personalLine: Text {
        switch style.personalLine {
        case .travelStyle:
            let styles = Array(showcase.knownStyles.prefix(2))
            if styles.count == 2 { return Text("\(Text(styles[0].label)) · \(Text(styles[1].label))") }
            return styles.first.map { Text($0.label) } ?? Text(verbatim: "—")
        case .motto:
            let motto = style.motto.trimmingCharacters(in: .whitespaces)
            return Text(verbatim: motto.isEmpty ? "—" : motto)
        case .favoritePlace:
            return Text(verbatim: showcase.favoritePlace ?? "—")
        }
    }

    /// The theme's display face, for the name, the numbers and the stamps: a Mincho, a
    /// Baskerville, or a typewriter slab. `fixedSize`, because the card rasterizes at a
    /// fixed size and type that grew with Dynamic Type would overflow it.
    private func display(_ size: CGFloat) -> Font {
        switch cover {
        case .kiku: .custom("HiraMinProN-W6", fixedSize: size)
        case .federal: .custom("Baskerville-Bold", fixedSize: size)
        case .trailhead: .custom("AmericanTypewriter-Bold", fixedSize: size)
        }
    }

    /// Kiku's ground: rows of overlapping wave crests, the pattern Japanese papers and
    /// passports both use, held near the threshold of visibility.
    private var waveCrests: some View {
        Canvas { context, size in
            let radius: CGFloat = 9
            var path = Path()
            var row = 0
            for y in stride(from: CGFloat(0), through: size.height + radius, by: radius * 0.5) {
                let shift = row.isMultiple(of: 2) ? 0 : radius
                row += 1
                for x in stride(from: -radius, through: size.width + radius, by: radius * 2) {
                    for r in [radius, radius * 0.6] {
                        path.move(to: CGPoint(x: x + shift - r, y: y))
                        path.addArc(center: CGPoint(x: x + shift, y: y), radius: r,
                                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                    }
                }
            }
            context.stroke(path, with: .color(cover.colors[1].opacity(0.07)), lineWidth: 0.5)
        }
    }

    /// Trailhead's ground: contour lines ringing a summit off the page's corner.
    private var contours: some View {
        Canvas { context, size in
            let summit = CGPoint(x: size.width * 0.82, y: size.height * 0.18)
            var path = Path()
            for radius in stride(from: CGFloat(13), through: max(size.width, size.height) * 1.2, by: 13) {
                path.addEllipse(in: CGRect(x: summit.x - radius, y: summit.y - radius * 0.86,
                                           width: radius * 2, height: radius * 1.72))
            }
            context.stroke(path, with: .color(cover.colors[1].opacity(0.09)), lineWidth: 0.6)
        }
    }

    /// The share link as a QR code, printed in the page's ink. CoreImage's generator
    /// draws at one point per module; the image is scaled up without interpolation.
    private var qrImage: UIImage? {
        guard let shareURL, let data = shareURL.absoluteString.data(using: .utf8),
              let generator = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        generator.setValue(data, forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = generator.outputImage,
              let tint = CIFilter(name: "CIFalseColor") else { return nil }
        tint.setValue(code, forKey: kCIInputImageKey)
        tint.setValue(CIColor(color: UIColor(ink)), forKey: "inputColor0")
        tint.setValue(CIColor(color: .white), forKey: "inputColor1")
        guard let output = tint.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// The two lines of chevrons every passport ends with — the most recognizable mark the
    /// document has, and what the old card's dashed "perforation" was standing in for. That
    /// perforation was a ticket-stub metaphor, not a passport one. The invite rides at the
    /// end of the second line, so the call to action is part of the costume rather than a
    /// caption sitting beside it.
    private var machineReadableZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            rule.padding(.bottom, 5)
            Text(verbatim: mrz.first)
            Text(verbatim: mrz.second)
        }
        .font(document(8.5, .medium))
        .foregroundStyle(ink.opacity(0.7))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    /// The two 44-character machine-readable lines. ASCII letters and digits survive;
    /// everything else becomes the filler `<`, which is what the real format does with
    /// anything it cannot encode.
    private var mrz: (first: String, second: String) {
        func encode(_ text: String) -> String {
            let folded = text.folding(options: .diacriticInsensitive,
                                      locale: Locale(identifier: "en_US_POSIX")).uppercased()
            return String(folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "<" })
        }
        func pad(_ text: String, to count: Int) -> String {
            String((text + String(repeating: "<", count: count)).prefix(count))
        }
        let invite = "ADDMEONTRIPSPLIT"
        let parts = Calendar.current.dateComponents([.year, .month], from: issued)
        let stamp = String(format: "%04d%02d", parts.year ?? 0, parts.month ?? 0)
        return (pad("P<TRIPSPLIT<" + encode(name), to: 44),
                pad("TS\(serial)<\(stamp)", to: 44 - invite.count) + invite)
    }

    /// A labelled field, the way a data page sets one: a tiny tracked-caps label over
    /// its value.
    private func field<Value: View>(
        _ label: LocalizedStringKey,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.system(size: 7.5, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(ink.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            value()
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    /// Data-page type is monospaced: the app's own typeface belongs to the app, and this is
    /// a printed document. `.system(size:)` rather than `Font.app`, which scales with
    /// Dynamic Type — this card rasterizes at a fixed 380x470, so type that grew with the
    /// reader's text size would overflow it rather than reflow.
    private func document(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Security-print line work: two families of fine waves, the second laid across the
    /// first at an angle, which is how engine-turned guilloche is generated — the lines
    /// beat against each other and the interference is the pattern. Held near the threshold
    /// of visibility, because this is a ground rather than a pattern, and drawn in `Canvas`
    /// for the same reason the grain is.
    ///
    /// Concentric rose curves came first and were wrong for the job. At the radii a whole
    /// page needs they are a handful of enormous arcs, so most of the page sees one stray
    /// line wandering across it and reads as a hair on the paper rather than as printing.
    /// Crossed wave families cover every part of the page at the same density, which is
    /// what makes it read as stock however the card is cropped.
    private var guilloche: some View {
        Canvas { context, size in
            // Drawn across a square larger than the card so the turned family still reaches
            // the corners once it has been rotated into place.
            let span = max(size.width, size.height) * 1.6
            func family(_ layer: GraphicsContext, spacing: CGFloat, amplitude: CGFloat,
                        wavelength: CGFloat, skew: CGFloat, phase: CGFloat, tone: Color) {
                var origin = -amplitude * 2
                while origin < span + amplitude * 2 {
                    var path = Path()
                    var x: CGFloat = 0
                    while x <= span {
                        // `skew` walks the phase line by line, so the family shears
                        // gradually instead of repeating the same wave down the page.
                        let y = origin + amplitude * sin(x / wavelength + origin * skew + phase)
                        let point = CGPoint(x: x, y: y)
                        if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        x += 4
                    }
                    layer.stroke(path, with: .color(tone), lineWidth: 0.5)
                    origin += spacing
                }
            }
            context.drawLayer { layer in
                layer.translateBy(x: -(span - size.width) / 2, y: -(span - size.height) / 2)
                family(layer, spacing: 6.5, amplitude: 5.5, wavelength: 27, skew: 0.055,
                       phase: 0, tone: ink.opacity(0.075))
            }
            // The cover's second ink, laid across the first at an angle.
            context.drawLayer { layer in
                layer.translateBy(x: size.width / 2, y: size.height / 2)
                layer.rotate(by: .degrees(-26))
                layer.translateBy(x: -span / 2, y: -span / 2)
                family(layer, spacing: 6.5, amplitude: 4.2, wavelength: 17.5, skew: -0.08,
                       phase: 1.9, tone: cover.lineInk.opacity(0.07))
            }
        }
    }

    /// Pebble grain on the cover: a jittered lattice of cells, each a lit crown sitting over
    /// a shadow dropped down and right, so the hide reads as raised bumps divided by creases.
    ///
    /// Every pebble is *filled*, never stroked. Stroking the ellipse outlines draws a closed
    /// ring around each cell, and rings overlapping at this density read as bubble wrap
    /// rather than as leather — the reason this was rebuilt.
    ///
    /// Crowns and shadows are each accumulated into a single `Path` and filled once.
    /// Overlapping subpaths union under nonzero winding instead of stacking their opacity,
    /// which is what keeps the tone even rather than mottled where cells pile up.
    ///
    /// Cells are ~5pt, which against a 380pt card standing in for a 125mm passport is
    /// roughly the 1.5mm grain real pebbled stock has — fine enough that the texture stays a
    /// surface rather than a pattern competing with the type. Not finer: the grain covers
    /// the whole card now rather than a 30pt spine, and a 4pt cell over that area is 23,000
    /// ellipses to accumulate on the main actor every time the cover changes.
    ///
    /// Seeded from a fixed constant so re-sharing prints the same hide, and drawn in
    /// `Canvas` because a blur or material would rasterize empty.
    private var leatherGrain: some View {
        Canvas { context, size in
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            func jitter() -> CGFloat {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                return CGFloat(state % 1000) / 1000
            }
            let step: CGFloat = 5
            var shadows = Path()
            var crowns = Path()
            var rowIndex = 0
            // Started a step outside the card so the pebbles run off every edge instead
            // of stopping in a straight line short of it.
            for row in stride(from: -step, through: size.height + step, by: step) {
                // Alternate rows shift half a cell so the pebbles pack instead of lining
                // up in columns; the positional jitter below dissolves the rest of the
                // grid, which otherwise shows through as a honeycomb.
                let stagger = rowIndex.isMultiple(of: 2) ? 0 : step / 2
                rowIndex += 1
                for column in stride(from: -step, through: size.width + step, by: step) {
                    // Held under a full step so neighbours stay parted by a crease rather
                    // than fusing into blobs.
                    let width = step * 0.8 * (0.75 + jitter() * 0.5)
                    let height = width * (0.78 + jitter() * 0.34)
                    let cell = CGRect(x: column + stagger + (jitter() - 0.5) * step * 0.45 - width / 2,
                                      y: row + (jitter() - 0.5) * step * 0.45 - height / 2,
                                      width: width, height: height)
                    shadows.addEllipse(in: cell.offsetBy(dx: 0.39, dy: 0.7))
                    crowns.addEllipse(in: cell)
                }
            }
            context.fill(shadows, with: .color(.black.opacity(0.07)))
            context.fill(crowns, with: .color(.white.opacity(0.03)))
        }
    }
}

/// TripSplit's pin, foiled into the cover where a state passport carries its emblem.
private struct PassportPinEmblem: View {
    let foil: Color
    let board: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.scaleBy(x: scale, y: scale)
            let head = CGPoint(x: 12, y: 9.5)
            // The head's arc is sampled rather than drawn with `addArc`, whose `clockwise`
            // reads backwards in a flipped coordinate space.
            var pin = Path()
            pin.move(to: CGPoint(x: 12, y: 22))
            for degrees in stride(from: 143.0, through: 397.0, by: 6) {
                let angle = degrees * .pi / 180
                pin.addLine(to: CGPoint(x: head.x + 7.1 * cos(angle), y: head.y + 7.1 * sin(angle)))
            }
            pin.closeSubpath()
            context.fill(pin, with: .color(foil))
            // The three shares the pin's head is split into.
            var cuts = Path()
            for end in [CGPoint(x: 12, y: 4.3), CGPoint(x: 16.4, y: 12.05), CGPoint(x: 7.6, y: 12.05)] {
                cuts.move(to: head)
                cuts.addLine(to: end)
            }
            context.stroke(cuts, with: .color(board), lineWidth: 1.2)
            context.fill(Path(ellipseIn: CGRect(x: 10.4, y: 7.9, width: 3.2, height: 3.2)), with: .color(board))
        }
    }
}

/// The personal seal: an outline and a motif, drawn in one ink. Six of each, chosen by the
/// owner or derived from their name (`PassportCardStyle.seal(for:)`), so two travelers
/// rarely carry the same one — and never the same one with the same monogram.
///
/// Drawn in a 44-unit square and scaled to the view, in `Canvas` so `ImageRenderer`
/// rasterizes it.
struct PassportSeal: View {
    let outline: PassportSealFrame
    let motif: PassportSealMotif
    let initials: String
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 44
            context.scaleBy(x: scale, y: scale)
            let ink = GraphicsContext.Shading.color(color)
            let line = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

            func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
                path.closeSubpath()
                return path
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
            /// A ripple running right from `x`: `count` half-waves, alternating up and down.
            func ripple(x: CGFloat, y: CGFloat, count: Int, step: CGFloat, height: CGFloat) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                for index in 0..<count {
                    let start = x + CGFloat(index) * step
                    path.addQuadCurve(to: CGPoint(x: start + step, y: y),
                                      control: CGPoint(x: start + step / 2,
                                                       y: y + (index.isMultiple(of: 2) ? -height : height)))
                }
                return path
            }

            switch outline {
            case .octagon:
                context.stroke(polygon([(40.5, 29.65), (29.65, 40.5), (14.35, 40.5), (3.5, 29.65),
                                        (3.5, 14.35), (14.35, 3.5), (29.65, 3.5), (40.5, 14.35)]),
                               with: ink, style: line)
            case .ring:
                context.stroke(circle(22, 22, 20), with: ink, style: line)
                context.stroke(circle(22, 22, 16.5), with: ink,
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 3.356]))
            case .hexagon:
                context.stroke(polygon([(22, 2), (39.3, 12), (39.3, 32), (22, 42), (4.7, 32), (4.7, 12)]),
                               with: ink, style: line)
            case .diamond:
                context.stroke(polygon([(22, 2), (42, 22), (22, 42), (2, 22)]), with: ink, style: line)
            case .beaded:
                context.stroke(circle(22, 22, 19.5), with: ink,
                               style: StrokeStyle(lineWidth: 2.6, lineCap: .round, dash: [0.1, 5.005]))
                context.stroke(circle(22, 22, 15.5), with: ink, style: line)
            case .shield:
                var shield = Path()
                shield.move(to: CGPoint(x: 22, y: 3))
                shield.addLine(to: CGPoint(x: 38, y: 8))
                shield.addLine(to: CGPoint(x: 38, y: 22))
                shield.addCurve(to: CGPoint(x: 22, y: 41), control1: CGPoint(x: 38, y: 31),
                                control2: CGPoint(x: 31, y: 38))
                shield.addCurve(to: CGPoint(x: 6, y: 22), control1: CGPoint(x: 13, y: 38),
                                control2: CGPoint(x: 6, y: 31))
                shield.addLine(to: CGPoint(x: 6, y: 8))
                shield.closeSubpath()
                context.stroke(shield, with: ink, style: line)
            }

            // Every motif stays within 11 units of the centre, so it clears all six outlines.
            switch motif {
            case .monogram:
                context.stroke(circle(22, 22, 11), with: ink,
                               style: StrokeStyle(lineWidth: 2.6, dash: [1.2, 4.56]))
                context.draw(Text(verbatim: initials)
                    .font(.system(size: 7.5, weight: .bold, design: .serif))
                    .foregroundStyle(color), at: CGPoint(x: 22, y: 22))
            case .compass:
                context.fill(polygon([(22, 11), (24.2, 19.8), (33, 22), (24.2, 24.2),
                                      (22, 33), (19.8, 24.2), (11, 22), (19.8, 19.8)]), with: ink)
            case .peak:
                context.stroke(polygon([(12, 27), (17.5, 17.5), (21.5, 22.5), (26, 14.5), (32, 27)]),
                               with: ink, style: line)
                context.fill(circle(15.5, 14, 1.9), with: ink)
                context.stroke(ripple(x: 14, y: 30.5, count: 4, step: 4, height: 1.6), with: ink, style: line)
            case .wave:
                for y in [17.5, 22.5, 27.5] as [CGFloat] {
                    context.stroke(ripple(x: 12, y: y, count: 4, step: 5, height: 2.4), with: ink, style: line)
                }
            case .plane:
                var plane = polygon([(12.5, 22), (31.5, 13.5), (26, 30.5), (22, 24)])
                plane.move(to: CGPoint(x: 22, y: 24))
                plane.addLine(to: CGPoint(x: 31.5, y: 13.5))
                context.stroke(plane, with: ink, style: line)
            case .night:
                context.fill(circle(21, 22.5, 8).subtracting(circle(25, 19.5, 7)), with: ink)
                for star in [(32, 25), (30.5, 14.5), (14, 13.5)] as [(CGFloat, CGFloat)] {
                    context.fill(circle(star.0, star.1, 1.1), with: ink)
                }
            }
        }
    }
}

/// Renders the card, previews it, and hands it to the system share sheet. Rendering
/// lives here rather than at the call site because this is where the cover is chosen —
/// picking one re-renders the picture in place.
struct ProfileShareSheet: View {
    let card: ShareCardItem
    @AppStorage("shareCardCover") private var cover: ShareCardCover = .federal
    /// Rasterized on appear and again whenever the theme or the owner's choices change.
    @State private var image: Image?
    /// The same picture as `UIImage`, for saving to Photos.
    @State private var rendered: UIImage?
    @State private var didSave = false
    /// The portrait, resolved once — from this device's copy, or downloaded from Storage.
    @State private var photo: UIImage?
    @State private var didResolvePhoto = false
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let image {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        // Holds the card's shape for the frame or two before the renderer
                        // returns, in that cover's colours.
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(LinearGradient(colors: cover.colors,
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .aspectRatio(0.8, contentMode: .fit)
                    }
                }
                .clipShape(.rect(cornerRadius: 22))
                .shadow(color: Theme.elevatedShadow, radius: 16, y: 10)
                // As large as the screen allows: the full width, unless the height left
                // over by the controls below is the tighter limit on a short phone.
                .layoutPriority(1)
                .padding(.top, 8)

                // Every theme in one row under the card, so a tap restyles it in place.
                // Customize shares the row, which is what leaves a short screen the height
                // for a full-width card.
                HStack(spacing: 10) {
                    ForEach(ShareCardCover.allCases) { option in
                        Button { cover = option } label: { coverSwatch(option) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.label)
                            .accessibilityAddTraits(cover == option ? [.isButton, .isSelected] : .isButton)
                    }

                    Spacer(minLength: 0)

                    NavigationLink {
                        PassportCustomizeView(name: card.name, places: card.places,
                                              statValues: statValues, cover: cover)
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(Theme.surface, in: .capsule)
                            .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if let image {
                        ShareLink(item: image,
                                  subject: Text("Add me on TripSplit"),
                                  message: Text(profileInvite),
                                  preview: SharePreview(Text(profileInvite), image: image)) {
                            Label("Share passport", systemImage: "square.and.arrow.up")
                                .font(.app(.subheadline, .bold))
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 50)
                        }
                        .buttonStyle(.plain)
                        .background(Theme.accentPastel, in: .capsule)
                        .shadow(color: Theme.elevatedShadow, radius: 8, y: 4)
                    }
                    Button {
                        guard let rendered else { return }
                        UIImageWriteToSavedPhotosAlbum(rendered, nil, nil, nil)
                        didSave = true
                    } label: {
                        Image(systemName: didSave ? "checkmark" : "square.and.arrow.down")
                            .font(.app(.subheadline, .bold))
                            .foregroundStyle(didSave ? Theme.positive : .primary)
                            .frame(width: 50, height: 50)
                            .background(Theme.surface, in: .circle)
                            .overlay(Circle().stroke(Theme.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(rendered == nil)
                    .accessibilityLabel(didSave ? "Saved to Photos" : "Save to Photos")
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
            .background { AppBackground() }
            .navigationTitle("Travel passport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Rendered with whatever portrait is in hand so the sheet fills immediately,
            // then again if a cloud-only avatar had to be downloaded first.
            .task(id: RenderKey(cover: cover, showcase: store.userProfile.showcase)) {
                didSave = false
                render()
                guard !didResolvePhoto else { return }
                photo = await resolvePhoto()
                didResolvePhoto = true
                if photo != nil { render() }
            }
        }
    }

    /// What the picture is drawn from beyond the card's own data: a change to either
    /// re-renders it, which is how a pick on the customize screen shows up on return.
    private struct RenderKey: Equatable {
        let cover: ShareCardCover
        let showcase: ProfileShowcase
    }

    /// The card's numbers, with the bucket list counted live so it follows the profile.
    private var statValues: [PassportStat: Int] {
        var values = card.statValues
        values[.bucketList] = store.userProfile.showcase.bucketList.count
        return values
    }

    /// A cover in miniature: board, foil emblem, and the page with its inked header.
    private func coverSwatch(_ option: ShareCardCover) -> some View {
        let isSelected = cover == option
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(option.colors[1])
            .frame(width: 44, height: 56)
            .overlay {
                VStack(spacing: 3) {
                    Circle().strokeBorder(option.foil, lineWidth: 1).frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(option.paper)
                        .overlay(alignment: .top) { Rectangle().fill(option.ink).frame(height: 5) }
                        .clipShape(.rect(cornerRadius: 3, style: .continuous))
                }
                .padding(.horizontal, 6)
                .padding(.top, 7)
                .padding(.bottom, 6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? Theme.accent : .clear, lineWidth: 2.5)
                    .padding(-3)
            }
            .shadow(color: Theme.elevatedShadow, radius: 4, y: 2)
    }

    /// Rasterizes the card at 3x so it stays sharp in a photo library or a message
    /// thread. Pinned to light: the card is a printed object — cream stamps on a passport
    /// cover — and the renderer would otherwise resolve the stamps' adaptive colors
    /// against whatever appearance the app happens to be in.
    @MainActor
    private func render() {
        let content = ProfileShareCard(
            name: card.name,
            photo: photo,
            places: card.places,
            cover: cover,
            shareURL: card.shareURL,
            showcase: store.userProfile.showcase,
            statValues: statValues
        )
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .light))
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else { return }
        rendered = uiImage
        image = Image(uiImage: uiImage)
    }

    /// The portrait, the same way `AvatarView` finds one: this device's copy first, then
    /// the cached Storage object, then the network. Resolved up front because
    /// `ImageRenderer` rasterizes in one pass and never waits on a view's own loading.
    private func resolvePhoto() async -> UIImage? {
        if let data = card.imageData, let local = UIImage(data: data) { return local }
        guard let stored = card.avatarPath, !stored.isEmpty else { return nil }
        let path = ReceiptStorage.storagePath(from: stored)
        guard !path.isEmpty else { return nil }
        if let cached = await ImageCache.shared.image(for: path) { return cached }
        guard let url = await store.signedImageURL(for: path) else { return nil }
        return await ImageCache.shared.download(from: url, for: path)
    }
}

/// Picks the passport cover the share card is printed on. Presented at a short detent so
/// the card being restyled stays on screen behind it.
struct ShareCardCoverPicker: View {
    @Binding var cover: ShareCardCover
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ShareCardCover.allCases) { option in
                        Button { cover = option } label: { swatch(option) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Card cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The card in miniature rather than a plain swatch of the cover: its foil emblem, the
    /// page mounted on the board in that cover's own paper, and the inked header band —
    /// the three things the choice actually changes. A ring marks the one in use.
    private func swatch(_ option: ShareCardCover) -> some View {
        let isSelected = cover == option
        return VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(option.colors[1])
                .frame(height: 64)
                .overlay {
                    VStack(spacing: 0) {
                        Image(systemName: "globe")
                            .font(.app(size: 10, weight: .light))
                            .foregroundStyle(option.foil.opacity(0.9))
                            .frame(height: 15)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(option.paper)
                            .overlay(alignment: .top) {
                                Rectangle().fill(option.ink).frame(height: 6)
                            }
                            .clipShape(.rect(cornerRadius: 3, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(option.foil.opacity(0.5), lineWidth: 0.7)
                            }
                    }
                    .padding(.horizontal, 7)
                    .padding(.bottom, 7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 3)
                }
                .shadow(color: Theme.elevatedShadow, radius: 4, y: 2)

            Text(option.label)
                .font(.app(.caption, isSelected ? .semibold : nil))
                .foregroundStyle(isSelected ? Color.primary : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

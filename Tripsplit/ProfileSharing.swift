import SwiftUI
import CoreImage
import UIKit

/// The invitation sent with a shared profile, whether it goes out as the card picture or
/// as the `tripsplit://` link — one voice for both. (The card's printed footer and the
/// mail subject stay on the short "Add me on TripSplit"; neither has room for a sentence.)
let profileInvite: LocalizedStringKey =
    "Hey! Add me on TripSplit and we'll share many journeys together while staying on budget!"

/// The profile data a share card is drawn from, held while the preview sheet is up. The
/// picture itself is rendered in the sheet, which is where the cover is chosen.
struct ShareCardItem: Identifiable {
    let id = UUID()
    let name: String
    let imageData: Data?
    /// The avatar's Storage path, used when this device has no local copy of the photo —
    /// signing in on a new device leaves `imageData` nil while the picture still exists.
    let avatarPath: String?
    let stats: ProfileStats
    let places: [VisitedPlace]
    /// The profile deep link the card's QR code encodes; nil until the token has loaded.
    let shareURL: URL?
}

/// The cover a share card is printed on, taken from real passport covers — the object
/// the card imitates. US navy is the default; the rest are picked for distinct hues
/// rather than exhaustiveness, so the swatches never read as two shades of the same red.
///
/// Fixed hex values, not `Color(light:dark:)`: the card is a printed object and renders
/// the same whatever appearance the app is in.
enum ShareCardCover: String, CaseIterable, Identifiable {
    case unitedStates, europeanUnion, japan, mexico, vietnam, newZealand

    var id: Self { self }

    /// Country names are localized like the rest of the UI, not shown verbatim.
    var label: LocalizedStringKey {
        switch self {
        case .unitedStates: "United States"
        case .europeanUnion: "European Union"
        case .japan: "Japan"
        case .mexico: "Mexico"
        case .vietnam: "Vietnam"
        case .newZealand: "New Zealand"
        }
    }

    /// The cover stock, lit from the top-left the way a leather cover catches light.
    ///
    /// Three stops rather than two: the card is bound in the cover on all four sides, and a
    /// two-stop gradient stretched over that much board bands visibly across its middle.
    var colors: [Color] {
        switch self {
        case .unitedStates: [Color(hex: 0x2A4677), Color(hex: 0x152A4B), Color(hex: 0x08111F)]
        case .europeanUnion: [Color(hex: 0x7E2742), Color(hex: 0x4C1727), Color(hex: 0x230A12)]
        case .japan: [Color(hex: 0xB63039), Color(hex: 0x7B1A21), Color(hex: 0x420C11)]
        case .mexico: [Color(hex: 0x24734B), Color(hex: 0x134A30), Color(hex: 0x062218)]
        case .vietnam: [Color(hex: 0x494284), Color(hex: 0x2A2557), Color(hex: 0x121029)]
        case .newZealand: [Color(hex: 0x3A3A41), Color(hex: 0x1D1D22), Color(hex: 0x08080A)]
        }
    }

    /// The three-letter issuing-state code the data page prints in its header and again
    /// at the head of the machine-readable zone. The country's own ICAO code, so picking a
    /// cover changes what the document says it was issued by and not just its colour.
    var code: String {
        switch self {
        case .unitedStates: "USA"
        case .europeanUnion: "EUR"
        case .japan: "JPN"
        case .mexico: "MEX"
        case .vietnam: "VNM"
        case .newZealand: "NZL"
        }
    }

    /// The embossing: gold foil on most covers, silver on the black one.
    var foil: Color {
        switch self {
        case .newZealand: Color(hex: 0xD9DEE4)
        default: Color(hex: 0xE3C486)
        }
    }

    /// The cover's deepest tone, for type printed on the page and for the band the page's
    /// header is reversed out of.
    var ink: Color { colors.last ?? .black }

    /// The page stock. Printed paper is never white — and here it is never the same cream
    /// twice either: every cover's page is mixed toward that cover's own hue, so choosing a
    /// country repaints the card's whole ground instead of one strip down its edge.
    var paper: Color {
        switch self {
        case .unitedStates: Color(hex: 0xEEF1F7)
        case .europeanUnion: Color(hex: 0xFAF0F0)
        case .japan: Color(hex: 0xFCF2EB)
        case .mexico: Color(hex: 0xEDF5EE)
        case .vietnam: Color(hex: 0xF1EFF9)
        case .newZealand: Color(hex: 0xF5F3EE)
        }
    }

    /// The second ink the page's security printing runs in. Data pages are printed in two
    /// or three colours precisely so their line work interferes, and the pairing is picked
    /// to sit *against* the cover rather than with it — blue line work under a red Japanese
    /// page, gold under the indigo ones — because a second ink in the cover's own hue
    /// disappears into the first and the guilloche flattens to a plain hatch.
    var lineInk: Color {
        switch self {
        case .unitedStates: Color(hex: 0xB3543A)
        case .europeanUnion: Color(hex: 0xC08A3E)
        case .japan: Color(hex: 0x2F5FA8)
        case .mexico: Color(hex: 0xB05236)
        case .vietnam: Color(hex: 0xC08A3E)
        case .newZealand: Color(hex: 0x8A6A4A)
        }
    }
}

/// The profile rendered as a picture: a passport biodata page someone can post anywhere,
/// unlike the `tripsplit://` link, which only does anything for people who already have
/// the app.
///
/// The page rather than the cover, which is what this used to imitate: a real cover
/// carries an emblem, a country and the word PASSPORT and nothing else, so a cover loaded
/// with a portrait, four counts and three captioned stamps was working against itself.
/// Everything here is what a biodata page genuinely holds, set the way a page sets it —
/// left-aligned, ruled and field-labelled rather than centred.
///
/// The cover is the card's ground, not a stripe on it. Shown as a 30pt spine down one
/// edge, the country picker changed a thirteenth of the picture and every cover produced
/// the same cream card; the page is now *mounted* in the cover, which frames it on all
/// four sides, prints its own stock in the cover's tone, and reverses the page header out
/// of a band of the cover's ink.
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
    let stats: ProfileStats
    /// Every visited place: the first few are stamped, the rest still count toward the
    /// flag row and the "+n more" line.
    let places: [VisitedPlace]
    /// The passport cover the page is bound in: its board, its paper and its foil.
    var cover: ShareCardCover = .unitedStates
    /// Encoded as the QR code in the page's corner, so a posted card actually connects.
    var shareURL: URL?

    /// 4:5. Deliberately not the old 0.61: that was too tall for a feed, which cropped it,
    /// and too short for a story, which letterboxed it. `ImageRenderer` rasterizes at 3x,
    /// so the shared picture is 1140x1410.
    private let width: CGFloat = 360
    private let height: CGFloat = 450
    /// How much cover shows around the mounted page — the border of the passport's own
    /// board, and the first thing the card is read by.
    private let margin: CGFloat = 14
    /// The deeper band of cover above the page, carrying the foil a cover is embossed with.
    private let coverBand: CGFloat = 42

    /// The page is printed in the cover's deepest tone on the cover's own stock, so a Japan
    /// cover prints a red-inked page on warm paper and a Mexico cover a green-inked one on
    /// cool.
    private var ink: Color { cover.ink }
    private var page: Color { cover.paper }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    /// Up to three stamps — as many as the visa band holds at a diameter where the wording
    /// around the rim is still readable. The rest still count toward the flag row and the
    /// "+n more" line.
    private var stamped: [VisitedPlace] { Array(places.prefix(3)) }

    /// Where each stamp lands in the visa band: its centre as a fraction of the band's
    /// width, its offset from the band's middle as a fraction of the band's height, its
    /// diameter, and the angle it was pressed at.
    ///
    /// A table per count rather than one formula. Two stamps spread across a band scaled
    /// for three read as a row with a hole in it, so a pair is printed larger and pulled
    /// in; a lone stamp is printed larger still and centred. The vertical offsets
    /// alternate because stamps go onto a page one at a time, by hand, and a level row of
    /// them reads as a chart rather than as a travel record.
    private var stampLayout: [(x: CGFloat, y: CGFloat, size: CGFloat, tilt: Double)] {
        switch stamped.count {
        case 1: [(0.50, 0.00, 100, -7)]
        case 2: [(0.28, -0.05, 94, -10), (0.72, 0.07, 88, 7)]
        default: [(0.19, -0.06, 92, -9), (0.50, 0.09, 84, 5), (0.81, -0.07, 90, -4)]
        }
    }

    /// Flags for the countries behind the places, in the order they were visited — a
    /// passport page reads as one at a glance, before any of the numbers are.
    private var flags: [String] {
        var codes: [String] = []
        for place in places {
            guard let code = PlaceRegion.isoCode(forRegionIn: place.name),
                  !codes.contains(code) else { continue }
            codes.append(code)
        }
        return codes.prefix(6).map { code in
            String(String.UnicodeScalarView(code.unicodeScalars.compactMap {
                Unicode.Scalar(127_397 + $0.value)
            }))
        }
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

    /// Ten years on — the validity a passport is issued for.
    private var expires: Date {
        Calendar.current.date(byAdding: .year, value: 10, to: issued) ?? issued
    }

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

    /// What a cover actually carries: an emblem and a wordmark, foiled into the board and
    /// nothing else. The rules either side centre it the way embossing is centred.
    ///
    /// One key rather than a verbatim wordmark concatenated onto a localized phrase:
    /// `Text + Text` is deprecated, and translators leave a brand name alone inside a
    /// string anyway.
    private var coverWordmark: some View {
        HStack(spacing: 10) {
            foilRule
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(cover.foil.opacity(0.92))
            Text("Passport")
                .font(.system(size: 11, weight: .heavy))
                .textCase(.uppercase)
                .tracking(4)
                .foregroundStyle(cover.foil.opacity(0.92))
                .fixedSize()
            foilRule
        }
        .padding(.horizontal, margin + 2)
        .frame(height: coverBand)
    }

    private var foilRule: some View {
        Rectangle().fill(cover.foil.opacity(0.3)).frame(height: 0.8)
    }

    /// The paper the page is printed on: the cover's own stock tone under its security
    /// line work.
    private var pageStock: some View {
        ZStack { page; guilloche }
    }

    private var pageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 0) {
                identity
                counts
                    .padding(.top, 12)
                    .overlay(alignment: .top) { rule }
                    .padding(.top, 16)
                visaBand
                endorsements
                    .padding(.bottom, 10)
                machineReadableZone
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
    }

    /// The open middle of the page, and the only part of it that stretches: whatever the
    /// blocks above and below don't use is visa space, which is what a passport page does
    /// with its middle too.
    ///
    /// The stamps are placed inside this band rather than offset from the card's own
    /// corner, which is what they used to be. Card coordinates left them wherever the
    /// numbers above happened to end — clustered to one side with the rest of the band
    /// unaccounted for, and the first of them cut in half by the card's edge.
    private var visaBand: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(stamped.enumerated()), id: \.offset) { index, place in
                    let spec = stampLayout[index]
                    PlaceStampBadge(place: place, size: spec.size, page: page, entryDate: place.date)
                        // Just off full strength: a stamp is ink pressed into paper, and
                        // at 100% it sits on top of the page as artwork rather than in it.
                        .opacity(0.94)
                        .rotationEffect(.degrees(spec.tilt))
                        .position(x: geometry.size.width * spec.x,
                                  y: geometry.size.height * (0.5 + spec.y))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rule: some View {
        Rectangle().fill(ink.opacity(0.3)).frame(height: 1)
    }

    /// The page's title line, reversed out of a band of the cover's ink across the head of
    /// the page. A real data page prints its title in the same colour as everything else;
    /// this one doesn't, because the band is what carries the chosen country *into* the
    /// page rather than leaving it as a border around one.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            chipSymbol.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text("Passport / Passeport")
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(page)
            Spacer()
            Text(verbatim: cover.code).font(document(8.5, .medium)).foregroundStyle(page.opacity(0.72))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [ink.opacity(0.9), ink], startPoint: .leading, endPoint: .trailing)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(cover.foil.opacity(0.4)).frame(height: 0.8) }
    }

    /// The biometric-passport symbol a data page carries beside its title: a chip in a
    /// rectangle, radiating. Drawn from shapes because there is no SF Symbol for it, and
    /// it is the one mark that says *passport* before a word of the page has been read.
    ///
    /// Drawn in the page stock, not the ink: it sits inside the reversed header band.
    private var chipSymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                .strokeBorder(page.opacity(0.85), lineWidth: 0.9)
            Circle().fill(page.opacity(0.85)).frame(width: 2.4, height: 2.4).offset(x: -2.6)
            chipWave(diameter: 4.4, x: -1.2)
            chipWave(diameter: 7.6, x: -0.4)
        }
        .frame(width: 12, height: 9)
    }

    /// One of the symbol's two radiating arcs — a right-facing quarter circle.
    private func chipWave(diameter: CGFloat, x: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(page.opacity(0.85), lineWidth: 0.8)
            .rotationEffect(.degrees(-45))
            .frame(width: diameter, height: diameter)
            .offset(x: x)
    }

    /// Portrait and the name block beside it.
    ///
    /// One `Name` field rather than a passport's own `Surname` / `Given names` pair: which
    /// half of a display name is the family name is not knowable — "Trần Văn Khôi" puts it
    /// first and "Jennie Tran" puts it last — and guessing wrong prints someone's name
    /// backwards on the thing they are about to post.
    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            portrait
            VStack(alignment: .leading, spacing: 12) {
                field("Name / Nom") {
                    Text(verbatim: name.uppercased())
                        .font(document(20, .bold))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.55)
                }
                HStack(alignment: .top, spacing: 12) {
                    field("Passport no.") { documentValue(Text(verbatim: "TS\(serial)")) }
                    field("Issued / Délivré") { documentValue(Text(verbatim: monthYear(issued))) }
                }
                signature
            }
            .padding(.top, 2)
        }
    }

    /// The bearer's signature: the name in a script face over a short rule.
    private var signature: some View {
        Text(verbatim: name)
            .font(.custom("SnellRoundhand-Bold", size: 15))
            .foregroundStyle(ink.opacity(0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.bottom, 1)
            .frame(width: 110, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.35)).frame(height: 0.8) }
    }

    /// A data-page value in one of the paired columns: allowed to shrink rather than wrap,
    /// because a long country name would otherwise take a second line the row has no room
    /// for. Takes a `Text` so a localized country name arrives still localized.
    private func documentValue(_ value: Text) -> some View {
        value
            .font(document(12))
            .textCase(.uppercase)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private func monthYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// Rectangular, because a biodata photo is. The circular portrait it replaces was the
    /// single element that most made the card read as a social profile rather than a
    /// document, whatever was printed around it.
    private var portrait: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Rectangle().fill(ink.opacity(0.08)).overlay {
                    Text(verbatim: initials)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(ink.opacity(0.8))
                }
            }
        }
        // Slightly shorter than it was: the cover band and margins take height off the
        // page, and the visa band is where that would otherwise have come from.
        .frame(width: 72, height: 94)
        .clipped()
        .overlay(Rectangle().strokeBorder(ink.opacity(0.32), lineWidth: 0.75))
        // Straddling the portrait's corner, the way a laminate seal is applied over the
        // photo's edge so the picture can't be swapped without breaking it.
        .overlay(alignment: .bottomTrailing) { laminateSeal.offset(x: 11, y: 10) }
    }

    /// The optically variable patch a laminated data page carries over its portrait: an
    /// angular sweep through the prismatic sequence a hologram runs, etched with the fine
    /// concentric rings the diffraction sits in.
    ///
    /// The one thing on the page that is neither the cover's ink nor the paper — a printed
    /// document is monochrome by nature, and without this the card had no colour of its own
    /// beyond whatever the stamps happened to bring.
    private var laminateSeal: some View {
        let diameter: CGFloat = 32
        return ZStack {
            Circle().fill(
                AngularGradient(
                    colors: [Color(hex: 0xE9B8C8), Color(hex: 0xF2DDA8), Color(hex: 0xB8E0D2),
                             Color(hex: 0xB9C8EE), Color(hex: 0xE0BCE8), Color(hex: 0xE9B8C8)],
                    center: .center
                )
            )
            ForEach(1..<5) { ring in
                Circle()
                    .inset(by: CGFloat(ring) * diameter * 0.09)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 0.5)
            }
            Image(systemName: "globe")
                .font(.system(size: diameter * 0.34, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
            Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.8)
        }
        .frame(width: diameter, height: diameter)
        .opacity(0.72)
    }

    /// Three counts, not the old four: `places` and `countries` answer nearly the same
    /// question, and the fourth column cost every number the size that makes it legible
    /// once the card is a thumbnail in a feed.
    private var counts: some View {
        HStack(spacing: 0) {
            count(stats.countries, "Countries")
            countDivider
            count(stats.trips, "Trips")
            countDivider
            count(stats.days, "Days")
        }
    }

    private func count(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            number(value)
            Text(label)
                .font(.system(size: 7, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private var countDivider: some View {
        Rectangle().fill(ink.opacity(0.2)).frame(width: 1, height: 30)
    }

    private func number(_ value: Int) -> some View {
        Text(verbatim: "\(value)")
            .font(document(26, .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// Flags on the left, the profile's QR code on the right. The QR is what makes a
    /// posted card connect: scanning it opens this profile in the app.
    private var endorsements: some View {
        HStack(alignment: .bottom) {
            field("Visas") {
                HStack(spacing: 4) {
                    ForEach(flags, id: \.self) { flag in
                        Text(verbatim: flag).font(.system(size: 17))
                    }
                }
            }
            if let qr = qrImage {
                HStack(spacing: 8) {
                    Text("Scan to\nadd me")
                        .font(.system(size: 7, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(ink.opacity(0.6))
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 38, height: 38)
                        .padding(3)
                        .background(.white)
                        .overlay(Rectangle().strokeBorder(ink.opacity(0.32), lineWidth: 0.75))
                }
            }
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
        return (pad("P<" + cover.code + encode(name), to: 44),
                pad("TS\(serial)<\(stamp)", to: 44 - invite.count) + invite)
    }

    /// A labelled field, the way a data page sets one: a tiny tracked-caps label over a
    /// monospaced value.
    ///
    /// The label is bilingual because every real passport's is, and that doubled line does
    /// much of the work of making the page read as a document. Both halves live in one
    /// `LocalizedStringKey` so the pairing is the translator's to make — "Countries / Pays"
    /// should become "Países / Pays" in Spanish, not keep an English first half.
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

/// Renders the card, previews it, and hands it to the system share sheet. Rendering
/// lives here rather than at the call site because this is where the cover is chosen —
/// picking one re-renders the picture in place.
struct ProfileShareSheet: View {
    let card: ShareCardItem
    @AppStorage("shareCardCover") private var cover: ShareCardCover = .unitedStates
    /// Rasterized on appear and again whenever the cover changes.
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
            VStack(spacing: 28) {
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
                .frame(maxWidth: 306)
                .padding(.top, 8)

                // Every cover in one row under the card, so a tap restyles it in place.
                HStack(spacing: 10) {
                    ForEach(ShareCardCover.allCases) { option in
                        Button { cover = option } label: { coverSwatch(option) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.label)
                            .accessibilityAddTraits(cover == option ? [.isButton, .isSelected] : .isButton)
                    }
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
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 50)
                        }
                        .buttonStyle(.plain)
                        .background(
                            LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .capsule
                        )
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
            .padding(.horizontal, 24)
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
            .task(id: cover) {
                didSave = false
                render()
                guard !didResolvePhoto else { return }
                photo = await resolvePhoto()
                didResolvePhoto = true
                if photo != nil { render() }
            }
        }
    }

    /// A cover in miniature: board, foil emblem, and the page with its inked header.
    private func coverSwatch(_ option: ShareCardCover) -> some View {
        let isSelected = cover == option
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: option.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
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
            stats: card.stats,
            places: card.places,
            cover: cover,
            shareURL: card.shareURL
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
                .fill(LinearGradient(colors: option.colors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
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

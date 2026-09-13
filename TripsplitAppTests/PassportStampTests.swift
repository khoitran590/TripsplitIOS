import XCTest
import SwiftUI
import UIKit
@testable import Tripsplit

@MainActor
final class PassportStampTests: XCTestCase {
    private let places = ["Yosemite, California", "Kyoto, Japan", "Tokyo, Japan", "Lake Tahoe, Nevada",
                          "San Francisco, CA", "Nara, Japan", "New York, NY", "Chicago, Illinois",
                          "Miami Beach, Florida", "Seattle, Washington", "Honolulu, Hawaii", "Paris, France",
                          "London, UK", "Rome, Italy", "Osaka, Japan", "Seoul, South Korea",
                          "Singapore", "Sydney, Australia"]

    func testEveryApprovedLocationResolvesToItsArtwork() {
        let designs = places.compactMap(PassportStampDesign.matching)
        XCTAssertEqual(designs.count, 18)
        XCTAssertEqual(Set(designs), Set(PassportStampDesign.allCases))
        XCTAssertEqual(PassportStampDesign.matching("  京都, 日本  "), .kyoto)
        XCTAssertEqual(PassportStampDesign.matching("大阪市, 大阪府, 日本"), .osaka)
        XCTAssertEqual(PassportStampDesign.matching("서울, 대한민국"), .seoul)
        XCTAssertEqual(PassportStampDesign.matching("Roma, Italia"), .rome)
        XCTAssertEqual(PassportStampDesign.matching("Sydney, NSW 2000, Australia"), .sydney)
        XCTAssertEqual(PassportStampDesign.matching("NYC"), .newYork)
    }

    func testAmbiguousAndUnknownNamesUseGenericFallback() {
        for name in ["Paris, Texas", "London, Ontario, Canada", "Miami, Oklahoma, USA",
                     "Miamisburg, Ohio", "Sydney, Nova Scotia", "New York Mills, Minnesota",
                     "Portland, Oregon", "", "Not a known city"] {
            XCTAssertNil(PassportStampDesign.matching(name), name)
        }
    }

    func testAllDestinationAndFallbackAssetsAreBundled() {
        let themes: [PlaceTheme] = [.city, .mountain, .lake, .coast, .island, .desert, .forest, .snow, .historic]
        let names = PassportStampDesign.allCases.map(\.assetName) + themes.map(\.stampAssetName)
        for name in names {
            let asset = UIImage(named: name)
            XCTAssertNotNil(asset, "Missing stamp illustration: \(name)")
            XCTAssertGreaterThan(asset?.size.width ?? 0, 0)
        }
    }

    func testRenderStampCollectionInLightDarkAndSharedPage() throws {
        // These attachments verify real compiled SVG assets in the native renderer,
        // including undated/unknown places and the caller's transparent share-card page.
        let dated = Date(timeIntervalSince1970: 1_772_323_200)
        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(spacing: 20) {
                ForEach(0..<3) { row in
                    HStack(spacing: 22) {
                        ForEach(0..<6) { column in
                            let name = self.places[row * 6 + column]
                            VStack(spacing: 4) {
                                PlaceStampBadge(place: VisitedPlace(name: name, date: dated), size: 128, compact: true)
                                Text(name.components(separatedBy: ",")[0]).font(.system(size: 12))
                            }
                            .frame(width: 140)
                        }
                    }
                }
            }
            .padding(24)
            .background(scheme == .light ? Color.white : Color.black)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = scheme == .light ? "Stamps-light" : "Stamps-dark"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let page = HStack(spacing: 12) {
            PlaceStampBadge(place: VisitedPlace(name: "Paris, France", date: nil), size: 200,
                            page: Color(red: 0.96, green: 0.91, blue: 0.80), entryDate: dated)
            PlaceStampBadge(place: VisitedPlace(name: "Kyoto, Japan", date: nil), size: 200,
                            page: Color(red: 0.96, green: 0.91, blue: 0.80))
            PlaceStampBadge(place: VisitedPlace(name: "Lake Arrowhead, California", date: nil), size: 200,
                            page: Color(red: 0.96, green: 0.91, blue: 0.80))
        }
        .padding(30)
        .background(Color(red: 0.96, green: 0.91, blue: 0.80))
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "en_US"))
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        attachment.name = "Stamps-shared-page-and-undated-fallback"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

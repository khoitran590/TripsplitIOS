import Foundation
import ImageIO
import UIKit

// MARK: - Currency helper

/// Maps a currency code to its display symbol, defaulting to `$`.
func currencySymbol(_ code: String) -> String {
    switch code {
    case "EUR": "€"
    case "GBP": "£"
    case "JPY", "CNY": "¥"
    case "KRW": "₩"
    case "THB": "฿"
    case "VND": "₫"
    case "INR": "₹"
    default: "$"
    }
}

let supportedCurrencies = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CNY", "KRW", "THB", "SGD", "VND", "INR"]

/// Colors assigned to newly added trip members, in rotation.
/// Muted, harmonized hues for member avatars — distinguishable but calm, since a
/// trip screen can show a dozen avatars at once (rendered as soft tints by
/// `InitialsAvatar`, which is what keeps existing saturated stored colors calm too).
let memberPalette: [UInt32] = [0x5B8DBE, 0x5FA98C, 0xC0895E, 0x9282C0, 0xC07B85, 0x5FA3B0, 0x8FA05E, 0xB08FC0]

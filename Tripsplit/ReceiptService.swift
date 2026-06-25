import Foundation
import UIKit
import Vision

// MARK: - Receipt scanning (on-device, Apple Vision)

/// Reads line items off a receipt photo using Apple's on-device text recognition — no
/// network, no API key, fully private. Item extraction is heuristic (Vision returns
/// text lines; we pair names with trailing prices), so the results are presented as an
/// editable list the user can correct before saving.
enum ReceiptScanner {

    /// Words that mark a line as a total/tax/payment row rather than a purchasable item.
    private static let nonItemKeywords = [
        "subtotal", "total", "tax", "vat", "gst", "cash", "change", "balance",
        "visa", "mastercard", "amex", "card", "credit", "debit", "tip", "gratuity",
        "amount", "due", "payment", "tendered", "auth", "approval",
    ]

    /// Recognizes text and parses it into line items. Returns an empty array if nothing
    /// usable is found.
    static func scan(_ image: UIImage) async -> [ReceiptItem] {
        guard let cgImage = image.cgImage else { return [] }

        let lines: [String] = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // Sort top-to-bottom (Vision's origin is bottom-left, so larger y is higher).
                let ordered = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                let strings = ordered.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: strings)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }

        return parseItems(from: lines)
    }

    /// Pairs each text line with a trailing price (e.g. "Burger  12.99"), skipping
    /// total/tax/payment rows.
    static func parseItems(from lines: [String]) -> [ReceiptItem] {
        let priceRegex = try? NSRegularExpression(pattern: #"(\d{1,5}[.,]\d{2})\s*$"#)
        guard let priceRegex else { return [] }

        var items: [ReceiptItem] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let lower = line.lowercased()
            if nonItemKeywords.contains(where: { lower.contains($0) }) { continue }

            let range = NSRange(line.startIndex..., in: line)
            guard let match = priceRegex.firstMatch(in: line, range: range),
                  let priceRange = Range(match.range(at: 1), in: line) else { continue }

            let priceText = line[priceRange].replacingOccurrences(of: ",", with: ".")
            guard let price = Double(priceText), price > 0 else { continue }

            var name = String(line[line.startIndex..<priceRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-*x×@"))
            if name.isEmpty { name = "Item" }

            items.append(ReceiptItem(name: name, price: SplitEngine.roundToTwo(price)))
        }
        return items
    }
}

// MARK: - Receipt storage (Supabase Storage)

/// Uploads receipt images to a Supabase Storage bucket and returns their public URL.
/// Run the storage section of `supabase_schema.sql` once to create the `receipts`
/// bucket and its access policies.
actor ReceiptStorage {
    static let shared = ReceiptStorage()

    private let session = URLSession.shared
    private let bucket = "receipts"

    /// Uploads JPEG data at `path` (e.g. "<userID>/<expenseID>.jpg") and returns the
    /// public URL. The signed-in user's token authorizes the write via storage RLS.
    func upload(_ jpeg: Data, path: String, accessToken: String) async throws -> String {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.url)/storage/v1/object/\(bucket)/\(path)") else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        let (_, response) = try await session.upload(for: request, from: jpeg)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError(message: "Receipt upload failed.")
        }
        return "\(SupabaseConfig.url)/storage/v1/object/public/\(bucket)/\(path)"
    }
}

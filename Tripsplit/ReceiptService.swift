import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit

// MARK: - Receipt AI parsing config

/// Configuration for the LLM step of receipt scanning (Google Gemini's free tier).
///
/// SECURITY: this key ships inside the app bundle, which is fine for a prototype but not
/// for a released build — anyone can extract it from the IPA and run up your quota. For
/// production, proxy this call through a Supabase Edge Function (you already have the
/// backend) and keep the key server-side, then point `endpoint` at that function instead.
enum ReceiptAIConfig {
    /// Loaded from `Secrets.swift`, which is gitignored so the key never lands in version
    /// control. Recreate that file after a fresh clone (see `Secrets.swift` for the shape).
    /// Empty when unset — `isConfigured` then drives scanning to the on-device fallback.
    nonisolated static let apiKey = Secrets.geminiAPIKey
    nonisolated static let model = "gemini-2.5-flash"

    nonisolated static var endpoint: String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    }

    /// True when a real key is present, so scanning can decide whether to attempt the LLM
    /// step or go straight to the on-device heuristic parser.
    nonisolated static var isConfigured: Bool {
        !apiKey.isEmpty && !apiKey.hasPrefix("YOUR_")
    }
}

enum ReceiptScanError: Error {
    case notConfigured
    case invalidResponse
    case apiError(String)
}

/// The receipt shape the LLM returns. Kept separate from the app's `ReceiptItem` (which
/// carries split configuration); `ReceiptScanner.mapToScanResult` bridges the two. Every
/// number is decoded defensively because models occasionally emit them as strings.
struct ParsedReceipt: Decodable {
    struct ParsedItem: Decodable {
        let name: String
        let price: Double
        let quantity: Int

        enum CodingKeys: String, CodingKey { case name, price, quantity }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = ((try? c.decode(String.self, forKey: .name)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            price = ParsedReceipt.flexibleDouble(c, .price)
            if let q = try? c.decode(Int.self, forKey: .quantity) {
                quantity = q
            } else {
                quantity = Int(ParsedReceipt.flexibleDouble(c, .quantity))
            }
        }
    }

    let merchant: String
    let date: String?
    let items: [ParsedItem]
    let tax: Double
    let tip: Double
    let total: Double

    enum CodingKeys: String, CodingKey { case merchant, date, items, tax, tip, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        merchant = (try? c.decode(String.self, forKey: .merchant)) ?? ""
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        items = (try? c.decode([ParsedItem].self, forKey: .items)) ?? []
        tax = ParsedReceipt.flexibleDouble(c, .tax)
        tip = ParsedReceipt.flexibleDouble(c, .tip)
        total = ParsedReceipt.flexibleDouble(c, .total)
    }

    /// Decodes a numeric field that may arrive as a JSON number or a string like "$12.99".
    fileprivate static func flexibleDouble<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let text = try? container.decode(String.self, forKey: key) {
            let digits = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(digits) ?? 0
        }
        return 0
    }
}

// MARK: - Receipt LLM parser (Gemini free tier)

/// Turns the OCR'd receipt text into a structured `ParsedReceipt` via Gemini. Network I/O
/// only — no observable state — so it's a plain namespace with a static async call.
enum ReceiptParser {
    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]
    }

    static func parse(rawText: String) async throws -> ParsedReceipt {
        guard ReceiptAIConfig.isConfigured,
              let url = URL(string: "\(ReceiptAIConfig.endpoint)?key=\(ReceiptAIConfig.apiKey)") else {
            throw ReceiptScanError.notConfigured
        }

        let prompt = """
        Extract structured data from this receipt text. Respond with ONLY valid JSON, no markdown fences, no commentary, matching exactly this schema:

        {
          "merchant": string,
          "date": string or null,
          "items": [{"name": string, "price": number, "quantity": integer}],
          "tax": number,
          "tip": number,
          "total": number
        }

        Rules:
        - If a field is missing on the receipt, use 0 for numbers or null for date.
        - Merge duplicate line items by summing quantity.
        - "price" is the per-item price, not the line total.
        - Exclude subtotal, total, tax, tip, and payment lines from "items".

        Receipt text:
        \(rawText)
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await BackendSecurity.secureSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReceiptScanError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw ReceiptScanError.apiError(detail ?? "HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let jsonText = decoded.candidates.first?.content.parts.first?.text,
              let jsonData = stripFences(jsonText).data(using: .utf8) else {
            throw ReceiptScanError.invalidResponse
        }
        return try JSONDecoder().decode(ParsedReceipt.self, from: jsonData)
    }

    /// Strips a ```json … ``` markdown fence if the model wrapped its JSON in one despite
    /// being asked not to, so decoding doesn't fail on the backticks.
    private static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if let fenceRange = trimmed.range(of: "```", options: .backwards) {
            trimmed = String(trimmed[..<fenceRange.lowerBound])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Receipt scanning (hybrid: on-device OCR + LLM parsing)

/// The outcome of scanning a receipt: the purchasable line items plus any tax/tip rows
/// detected separately so they can be allocated across the items.
struct ReceiptScanResult {
    var items: [ReceiptItem] = []
    var tax: Double? = nil
    var tip: Double? = nil
}

/// Reads line items off a receipt photo with a hybrid pipeline: Apple's on-device Vision
/// OCR extracts the raw text (free, private, offline), then Gemini's free tier parses that
/// text into structured items + tax/tip. When the LLM step is unavailable — no key, no
/// network, or an API error — it falls back to the on-device heuristic parser so scanning
/// still works. Either way the results are an editable list the user can correct.
enum ReceiptScanner {

    /// Words that mark a line as a total/tax/payment row rather than a purchasable item.
    private static let nonItemKeywords = [
        "subtotal", "total", "tax", "vat", "gst", "cash", "change", "balance",
        "visa", "mastercard", "amex", "card", "credit", "debit", "tip", "gratuity",
        "amount", "due", "payment", "tendered", "auth", "approval",
    ]

    /// Keywords identifying a tax row, kept apart so the amount can be allocated.
    private static let taxKeywords = ["tax", "vat", "gst", "hst", "pst"]
    /// Keywords identifying a tip / gratuity row.
    private static let tipKeywords = ["tip", "gratuity", "service charge", "service chg"]

    /// Recognizes text and parses it into line items plus tax/tip. Prefers the LLM's
    /// structured parse of the OCR text and falls back to the on-device heuristic parser
    /// when it's unavailable. Returns an empty result if nothing usable is found.
    static func scan(_ image: UIImage) async -> ReceiptScanResult {
        guard let cgImage = image.cgImage else { return ReceiptScanResult() }

        let lines = await recognizeRows(cgImage)
        guard !lines.isEmpty else { return ReceiptScanResult() }

        // Hybrid step: send the OCR text to the LLM for a structured parse. Only replace
        // the heuristic result when the LLM actually returns items — otherwise fall through.
        if ReceiptAIConfig.isConfigured {
            do {
                let parsed = try await ReceiptParser.parse(rawText: lines.joined(separator: "\n"))
                let result = mapToScanResult(parsed)
                if !result.items.isEmpty { return result }
            } catch {
                BackendSecurity.log("Receipt LLM parse failed; using on-device fallback", error: error)
            }
        }

        return parseItems(from: lines)
    }

    /// Runs Vision text recognition and returns the receipt's rows (name and price merged
    /// onto one line via `groupIntoRows`). Empty on failure.
    private static func recognizeRows(_ cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: groupIntoRows(observations))
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
    }

    /// Bridges the LLM's `ParsedReceipt` into the app's `ReceiptScanResult`. A line item
    /// with quantity N is expanded into N unit rows (each at the per-item price) so each
    /// unit can be assigned to a different person when splitting; quantity is clamped to a
    /// sane range to guard against a bad model response.
    static func mapToScanResult(_ parsed: ParsedReceipt) -> ReceiptScanResult {
        var result = ReceiptScanResult()
        for item in parsed.items {
            let name = item.name.isEmpty ? "Item" : item.name
            let price = SplitEngine.roundToTwo(item.price)
            guard price > 0 else { continue }
            let quantity = min(max(item.quantity, 1), 50)
            for _ in 0..<quantity {
                result.items.append(ReceiptItem(name: name, price: price))
            }
        }
        if parsed.tax > 0 { result.tax = SplitEngine.roundToTwo(parsed.tax) }
        if parsed.tip > 0 { result.tip = SplitEngine.roundToTwo(parsed.tip) }
        return result
    }

    /// Receipts print item names and prices in separate columns, which Vision returns as
    /// distinct text observations. This regroups observations that sit on the same
    /// horizontal line (similar `midY`) into one left-to-right string, so a name and its
    /// price end up on the same logical line for `parseItems` to pair.
    static func groupIntoRows(_ observations: [VNRecognizedTextObservation]) -> [String] {
        let entries = observations.compactMap { obs -> (text: String, midY: CGFloat, minX: CGFloat)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (text, obs.boundingBox.midY, obs.boundingBox.minX)
        }
        // Top-to-bottom (Vision's origin is bottom-left, so larger y is higher).
        let sorted = entries.sorted { $0.midY > $1.midY }

        // Fraction of image height within which observations count as the same row.
        let rowTolerance: CGFloat = 0.012
        var rows: [[(text: String, midY: CGFloat, minX: CGFloat)]] = []
        for entry in sorted {
            if let reference = rows.last?.first, abs(reference.midY - entry.midY) < rowTolerance {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }

        return rows.map { row in
            row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ")
        }
    }

    /// Pairs each text line with a trailing price (e.g. "Burger  12.99"). Item rows
    /// become `ReceiptItem`s; tax and tip rows are pulled out so they can be allocated
    /// proportionally across the items rather than treated as purchasable lines.
    static func parseItems(from lines: [String]) -> ReceiptScanResult {
        let priceRegex = try? NSRegularExpression(pattern: #"(\d{1,5}[.,]\d{2})\s*$"#)
        guard let priceRegex else { return ReceiptScanResult() }

        var result = ReceiptScanResult()
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let lower = line.lowercased()

            let range = NSRange(line.startIndex..., in: line)
            guard let match = priceRegex.firstMatch(in: line, range: range),
                  let priceRange = Range(match.range(at: 1), in: line) else { continue }

            let priceText = line[priceRange].replacingOccurrences(of: ",", with: ".")
            guard let price = Double(priceText), price > 0 else { continue }
            let rounded = SplitEngine.roundToTwo(price)

            // Capture tax / tip rows for allocation, taking the largest match of each
            // (receipts often print a "tax" subtotal line plus a final total).
            if taxKeywords.contains(where: { lower.contains($0) }) {
                result.tax = max(result.tax ?? 0, rounded)
                continue
            }
            if tipKeywords.contains(where: { lower.contains($0) }) {
                result.tip = max(result.tip ?? 0, rounded)
                continue
            }
            if nonItemKeywords.contains(where: { lower.contains($0) }) { continue }

            var name = String(line[line.startIndex..<priceRange.lowerBound])
            // Drop a leading quantity count (e.g. "1  Grande Latte" → "Grande Latte").
            if let qtyRange = name.range(of: #"^\s*\d{1,3}\s+"#, options: .regularExpression) {
                name.removeSubrange(qtyRange)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-*x×@$€£¥"))
            if name.isEmpty { name = "Item" }

            result.items.append(ReceiptItem(name: name, price: rounded))
        }
        return result
    }
}

// MARK: - Live camera capture (VisionKit document scanner)

/// Presents Apple's edge-detecting document camera so the user can photograph a receipt
/// directly instead of picking one from their library. Returns the first scanned page as
/// a `UIImage`, or `nil` if the user cancels or scanning fails.
struct DocumentCameraView: UIViewControllerRepresentable {
    var onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: (UIImage?) -> Void
        init(onComplete: @escaping (UIImage?) -> Void) { self.onComplete = onComplete }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let image = scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil
            onComplete(image)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onComplete(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onComplete(nil)
        }
    }
}

// MARK: - Receipt storage (Supabase Storage)

/// Uploads images (receipts, trip covers, avatars) to a private Supabase Storage bucket
/// and mints short-lived signed URLs to read them back. The bucket is private, so nothing
/// is world-readable: uploads return the object *path* (which is what callers persist),
/// and `signedURL` produces a time-limited URL on demand for display. Run the storage
/// section of `supabase_schema.sql` once to create the `receipts` bucket and its policies.
actor ReceiptStorage {
    static let shared = ReceiptStorage()

    static let bucketName = "receipts"

    private let session = BackendSecurity.secureSession
    private let bucket = ReceiptStorage.bucketName

    /// Pulls a human-readable reason out of a Supabase error body, which is JSON like
    /// `{"statusCode":"400","error":"...","message":"..."}`.
    nonisolated static func messageField(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["message", "error", "msg"] {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Uploads JPEG data at `path` (e.g. "<userID>/<expenseID>.jpg") and returns that
    /// storage `path` (not a URL — the bucket is private). Callers persist the path and
    /// later resolve a signed URL via `signedURL`. The user's token authorizes the write.
    @discardableResult
    func upload(_ jpeg: Data, path: String, accessToken: String) async throws -> String {
        guard jpeg.count <= 5_000_000 else {
            throw AuthError(message: "Receipt photos must be smaller than 5 MB.")
        }
        guard BackendSecurity.isSafeStoragePath(path) else {
            BackendSecurity.log("Blocked unsafe storage path")
            throw AuthError(message: "Receipt upload path is invalid.")
        }
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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: jpeg)
        } catch {
            BackendSecurity.log("Receipt upload network failure", error: error)
            throw AuthError(message: "Receipt upload failed. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            BackendSecurity.log("Receipt upload returned no HTTP response")
            throw AuthError(message: "Receipt upload failed.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Receipt upload rejected", statusCode: http.statusCode)
            // Surface the most common, actionable cause: the bucket hasn't been created.
            // Supabase returns 404 with `{"error":"Bucket not found"}` in that case.
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 404 || body.localizedCaseInsensitiveContains("bucket not found") {
                throw AuthError(message: "Receipt storage isn't set up — run the storage section of supabase_schema.sql to create the \"receipts\" bucket.")
            }
            // Include the server's explanation (e.g. an RLS / policy message) so the
            // failure is diagnosable instead of an opaque status code.
            let detail = ReceiptStorage.messageField(from: body)
            throw AuthError(message: detail.map { "Receipt upload failed: \($0)" }
                ?? "Receipt upload failed (HTTP \(http.statusCode)).",
                statusCode: http.statusCode)
        }
        return path
    }

    /// Creates a signed, time-limited URL for reading a private object at `path`. The
    /// user's token must satisfy the bucket's SELECT policy (any authenticated user). The
    /// URL expires after `expiresIn` seconds, so callers should cache it briefly and
    /// re-sign rather than persist it.
    func signedURL(path: String, expiresIn: Int = 3600, accessToken: String) async throws -> URL {
        guard BackendSecurity.isSafeStoragePath(path) else {
            throw AuthError(message: "Invalid storage path.")
        }
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.url)/storage/v1/object/sign/\(bucket)/\(path)") else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": expiresIn])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            BackendSecurity.log("Signed URL request rejected", statusCode: status)
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError(message: ReceiptStorage.messageField(from: body) ?? "Couldn't load the image.",
                            statusCode: status ?? -1)
        }

        struct SignResponse: Decodable { let signedURL: String }
        let decoded = try JSONDecoder().decode(SignResponse.self, from: data)
        // The API returns a path relative to `/storage/v1`, e.g. "/object/sign/receipts/…?token=…".
        let relative = decoded.signedURL.hasPrefix("/") ? decoded.signedURL : "/\(decoded.signedURL)"
        guard let signed = URL(string: "\(SupabaseConfig.url)/storage/v1\(relative)") else {
            throw AuthError(message: "Couldn't build the image URL.")
        }
        return signed
    }

    /// Normalizes a stored image reference to a bare storage path. Accepts a bare path, a
    /// legacy public URL (`…/object/public/receipts/<path>`), or a signed URL
    /// (`…/object/sign/receipts/<path>?token=…`), so old rows keep resolving after the
    /// switch to a private bucket.
    nonisolated static func storagePath(from stored: String) -> String {
        var value = stored
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        for marker in ["/object/public/\(bucketName)/",
                       "/object/sign/\(bucketName)/",
                       "/object/authenticated/\(bucketName)/",
                       "/object/\(bucketName)/",
                       "/\(bucketName)/"] {
            if let range = value.range(of: marker) {
                return String(value[range.upperBound...])
            }
        }
        return value
    }
}

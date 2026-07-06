import CoreImage
import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit

// MARK: - Receipt AI parsing config

/// Configuration for the LLM step of receipt scanning.
///
/// The Gemini API key lives SERVER-SIDE only, inside the `parse-receipt` Supabase Edge
/// Function (`supabase/functions/parse-receipt`). The app never holds the key: it sends the
/// receipt image to the function authenticated with the signed-in user's Supabase JWT, and
/// the function calls Gemini with the key stored as a Supabase secret. This keeps the key
/// out of the app binary and gates usage behind authentication + per-user rate limiting.
enum ReceiptAIConfig {
    /// The Edge Function endpoint that proxies the LLM call.
    nonisolated static var endpoint: String {
        "\(SupabaseConfig.url)/functions/v1/parse-receipt"
    }

    /// The Edge Function endpoint that proxies Google Cloud Vision OCR (the key lives
    /// server-side as the Supabase secret `GOOGLE_VISION_API_KEY`).
    nonisolated static var ocrEndpoint: String {
        "\(SupabaseConfig.url)/functions/v1/ocr-receipt"
    }

    /// True when the backend is configured; scanning still requires a signed-in user's
    /// token (passed to `ReceiptScanner.scan`) before it will attempt the LLM step.
    nonisolated static var isConfigured: Bool { SupabaseConfig.isConfigured }
}

enum ReceiptScanError: Error {
    case notConfigured
    case unauthorized
    case rateLimited
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

// MARK: - Receipt LLM parser (Gemini via Edge Function)

/// Turns a receipt image into a structured `ParsedReceipt` via Gemini. Network I/O only —
/// no observable state — so it's a plain namespace with static async calls.
///
/// Called by `ReceiptScanner.scan` in `.onlineBest` mode: the app sends the photo plus the
/// on-device Vision OCR text so Gemini can cross-check both instead of starting from
/// scratch. The Gemini key never leaves the `parse-receipt` Edge Function.
enum ReceiptParser {
    private static let maxImageBytes = 4_000_000
    private static let maxImageDimension: CGFloat = 2_200

    /// Sends the receipt image to the `parse-receipt` Edge Function (authenticated as the
    /// signed-in user) and decodes the structured receipt it returns. The Gemini key and
    /// prompt live in the function, not here. `accessToken` is the user's Supabase JWT.
    static func parse(image: UIImage, ocrText: String? = nil, accessToken: String) async throws -> ParsedReceipt {
        guard let jpeg = jpegData(for: image) else {
            throw ReceiptScanError.invalidResponse
        }
        var payload = [
            "imageBase64": jpeg.base64EncodedString(),
            "mimeType": "image/jpeg",
        ]
        // Ship the on-device OCR text alongside the photo: the Edge Function passes both
        // to Gemini so it can cross-check faint/skewed rows instead of skipping them.
        if let ocrText, !ocrText.isEmpty {
            payload["text"] = String(ocrText.prefix(16_000))
        }
        return try await parse(payload: payload, accessToken: accessToken)
    }

    /// Legacy text parser kept for compatibility with older callers and deployments.
    static func parse(rawText: String, accessToken: String) async throws -> ParsedReceipt {
        try await parse(payload: ["text": rawText], accessToken: accessToken)
    }

    private static func parse(payload: [String: String], accessToken: String) async throws -> ParsedReceipt {
        guard ReceiptAIConfig.isConfigured, let url = URL(string: ReceiptAIConfig.endpoint) else {
            throw ReceiptScanError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await BackendSecurity.secureSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReceiptScanError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(ParsedReceipt.self, from: data)
        case 401, 403:
            throw ReceiptScanError.unauthorized
        case 429:
            throw ReceiptScanError.rateLimited
        default:
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw ReceiptScanError.apiError(detail ?? "HTTP \(http.statusCode)")
        }
    }

    /// Compresses the picked receipt enough for a JSON request while preserving enough
    /// detail for the OCR/LLM services to read item rows. Shared with `CloudOCR`.
    static func jpegData(for image: UIImage) -> Data? {
        let candidates = [image, resizedImageIfNeeded(image)].compactMap { $0 }
        for candidate in candidates {
            for quality in stride(from: 0.82, through: 0.42, by: -0.10) {
                if let data = candidate.jpegData(compressionQuality: CGFloat(quality)), data.count <= maxImageBytes {
                    return data
                }
            }
        }
        for candidate in candidates {
            if let data = candidate.jpegData(compressionQuality: 0.35), data.count <= maxImageBytes {
                return data
            }
        }
        return nil
    }

    private static func resizedImageIfNeeded(_ image: UIImage) -> UIImage? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxImageDimension else { return nil }

        let scale = maxImageDimension / longestSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // scale = 1 so `size` IS the pixel size — the default (screen scale, 3x on
        // device) would triple every dimension and defeat the downsizing.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Cloud OCR (Google Cloud Vision via Edge Function)

/// Calls the `ocr-receipt` Edge Function, which runs the receipt image through Google
/// Cloud Vision OCR with the API key held server-side (hard rule: no keys in the app
/// bundle). Returns the recognized text already grouped into receipt rows (name and
/// price merged onto one line), ready for `ReceiptScanner.parseItems`.
enum CloudOCR {
    /// Runs server-side OCR on the receipt and returns its text rows, top to bottom.
    /// `accessToken` is the signed-in user's Supabase JWT.
    static func recognizeRows(_ image: UIImage, accessToken: String) async throws -> [String] {
        guard ReceiptAIConfig.isConfigured, let url = URL(string: ReceiptAIConfig.ocrEndpoint) else {
            throw ReceiptScanError.notConfigured
        }
        guard let jpeg = ReceiptParser.jpegData(for: image) else {
            throw ReceiptScanError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "imageBase64": jpeg.base64EncodedString(),
            "mimeType": "image/jpeg",
        ])

        let (data, response) = try await BackendSecurity.secureSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReceiptScanError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            struct OCRResponse: Decodable {
                let text: String?
                let lines: [String]?
            }
            let decoded = try JSONDecoder().decode(OCRResponse.self, from: data)
            if let lines = decoded.lines, !lines.isEmpty { return lines }
            // Older deployments may return only the raw text blob; split it into rows.
            return (decoded.text ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case 401, 403:
            throw ReceiptScanError.unauthorized
        case 429:
            throw ReceiptScanError.rateLimited
        default:
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw ReceiptScanError.apiError(detail ?? "HTTP \(http.statusCode)")
        }
    }
}

// MARK: - Receipt scanning (hybrid: cloud OCR + Gemini primary, on-device Vision fallback)

/// How `ReceiptScanner.scan` balances quality against privacy/latency.
enum ReceiptScanMode {
    /// On-device Apple Vision OCR only — no network, no sign-in, fastest and fully private.
    case offlineFast
    /// Best understanding: Google Cloud Vision OCR runs first (server-side key, via the
    /// `ocr-receipt` Edge Function), then the image and that OCR text go to Gemini via
    /// the `parse-receipt` Edge Function. On-device Apple Vision is the fallback whenever
    /// the network steps fail or return nothing usable.
    case onlineBest
}

/// The outcome of scanning a receipt: the purchasable line items plus any tax/tip rows
/// detected separately so they can be allocated across the items.
struct ReceiptScanResult {
    var items: [ReceiptItem] = []
    var tax: Double? = nil
    var tip: Double? = nil
    /// The subtotal as printed on the receipt (items only), when a labeled row was read.
    var printedSubtotal: Double? = nil
    /// The grand total as printed on the receipt, when known. Ground truth for
    /// `reconcileAgainstPrintedTotals` — the parsed items must add up to it.
    var printedTotal: Double? = nil

    /// Whether the scan produced anything worth showing. Used by the scan orchestrator to
    /// decide if a Gemini result should be preferred over the local Vision parse.
    var isUsable: Bool { !items.isEmpty }
}

/// Reads line items off a receipt photo. In `.onlineBest` mode the OCR is Google Cloud
/// Vision (`CloudOCR`, key server-side) and the structured understanding is Gemini
/// (`ReceiptParser`, key server-side), with the on-device Apple Vision pipeline (deskew,
/// enhancement, text rows, heuristic name/price parser) as the offline/failure fallback
/// and the sole engine in `.offlineFast`. The results are an editable list the user can
/// correct.
enum ReceiptScanner {

    /// Words that mark a line as a total/tax/payment row rather than a purchasable item.
    private static let nonItemKeywords = [
        "subtotal", "total", "tax", "vat", "gst", "cash", "change", "balance",
        "visa", "mastercard", "amex", "card", "credit", "debit", "tip", "gratuity",
        "amount", "due", "payment", "tendered", "auth", "approval",
    ]

    /// Lines that are per-item metadata, not purchases — they end in a number, so without
    /// this filter they parse as bogus items (e.g. H Mart prints "Regular Price 12.99 ,
    /// You saved 5.00" under every discounted item, and a member-number row under the
    /// membership line).
    private static let metaLineKeywords = [
        "you saved", "regular price", "member", "cashier", "price/lb", "reg price",
    ]

    /// Keywords identifying a tax row, kept apart so the amount can be allocated.
    private static let taxKeywords = ["tax", "vat", "gst", "hst", "pst"]
    /// Keywords identifying a tip / gratuity row.
    private static let tipKeywords = ["tip", "gratuity", "service charge", "service chg"]

    /// Scans a receipt image into line items plus tax/tip.
    ///
    /// `.onlineBest` (the default, requires a signed-in user's token) tries, in order:
    ///
    /// 1. **Google Cloud Vision OCR** via the `ocr-receipt` Edge Function (key server-side)
    ///    — the best raw text extraction, returned already grouped into receipt rows.
    /// 2. **Gemini** via the `parse-receipt` Edge Function, given the image *plus* the OCR
    ///    text (from step 1, or on-device Apple Vision if step 1 failed) so it can
    ///    cross-check both. Its structured receipt wins when usable.
    /// 3. The **heuristic parse of the Cloud Vision rows** when Gemini fails.
    /// 4. **On-device Apple Vision** as the final fallback — also the sole engine in
    ///    `.offlineFast` mode or when no token is available.
    ///
    /// `accessToken` is the signed-in user's Supabase JWT; the Google Cloud Vision and
    /// Gemini keys never leave their Edge Functions.
    static func scan(_ image: UIImage,
                     mode: ReceiptScanMode = .onlineBest,
                     accessToken: String? = nil) async -> ReceiptScanResult {
        // Bake any EXIF rotation into the pixels first: `cgImage` ignores
        // `imageOrientation`, and Cloud Vision ignores EXIF too — so a library photo
        // taken in another orientation would otherwise be OCR'd sideways everywhere.
        let image = normalizedUpright(image)

        if mode == .onlineBest, let accessToken, ReceiptAIConfig.isConfigured {
            // 1. Server-side Google Cloud Vision OCR.
            let cloudRows = (try? await CloudOCR.recognizeRows(image, accessToken: accessToken)) ?? []

            // Only run the on-device pass here if the cloud OCR came back empty — its rows
            // then stand in as the OCR text for Gemini, and its parse as a ready fallback.
            var localScan: (result: ReceiptScanResult, rows: [String])?
            var ocrRows = cloudRows
            if ocrRows.isEmpty {
                localScan = await visionScanWithRows(image)
                ocrRows = localScan?.rows ?? []
            }

            // 2. Gemini structured parse, cross-checking the photo against the OCR text.
            let ocrText = ocrRows.joined(separator: "\n")
            if let parsed = try? await ReceiptParser.parse(
                image: image,
                ocrText: ocrText.isEmpty ? nil : ocrText,
                accessToken: accessToken
            ) {
                let mapped = mapToScanResult(parsed)
                if mapped.isUsable { return mapped }
            }

            // 3. Heuristic parse of the Cloud Vision rows.
            let cloudParse = parseItems(from: cloudRows)
            if cloudParse.isUsable { return cloudParse }

            // 4. On-device result if it already ran; otherwise fall through to run it.
            if let localScan { return localScan.result }
        }
        return await visionScan(image)
    }

    /// The on-device Apple Vision OCR pipeline. Extracts text rows with Vision, then pairs
    /// names to prices with the heuristic parser, retrying on an enhanced copy when the
    /// first pass is thin.
    static func visionScan(_ image: UIImage) async -> ReceiptScanResult {
        await visionScanWithRows(image).result
    }

    /// Like `visionScan`, but also returns the raw OCR rows of the winning pass so the
    /// caller can ship them to Gemini alongside the image (`.onlineBest` mode).
    static func visionScanWithRows(_ image: UIImage) async -> (result: ReceiptScanResult, rows: [String]) {
        guard let cgImage = normalizedUpright(image).cgImage else { return (ReceiptScanResult(), []) }
        // Photos picked from the library arrive un-cropped and skewed (the document
        // camera deskews on capture, the library doesn't). Find the receipt in the frame
        // and perspective-correct it first — OCR accuracy on picked photos improves a lot.
        let prepared = await deskewedDocument(in: cgImage) ?? cgImage

        // First pass reads the receipt as-photographed.
        let firstRows = await recognizeRows(prepared)
        var best = parseItems(from: firstRows)
        var bestRows = firstRows

        // Faint thermal ink, wrinkles, glare, or something scrawled across the receipt leave
        // the first pass thin. Retry on a grayscale, contrast-boosted, sharpened copy — which
        // recovers characters the raw photo's OCR drops — and keep whichever pass read the
        // receipt better, so we do the best we can under poor conditions instead of giving up.
        if best.items.count < 3, let enhanced = enhancedForOCR(prepared) {
            let altRows = await recognizeRows(enhanced)
            let alt = parseItems(from: altRows)
            let altIsBetter = alt.items.count > best.items.count
                || (alt.items.count == best.items.count && altRows.count > firstRows.count)
            if altIsBetter {
                best = alt
                bestRows = altRows
            }
        }

        // A receipt lying SIDEWAYS in the frame (a common way to photograph a long
        // receipt) reads as gibberish upright — Vision doesn't auto-rotate. When the
        // upright passes found no items, retry telling Vision the image is rotated and
        // keep whichever orientation actually reads like a receipt.
        if best.items.isEmpty {
            for orientation in [CGImagePropertyOrientation.right, .left] {
                let rows = await recognizeRows(prepared, orientation: orientation)
                let parsed = parseItems(from: rows)
                if parsed.items.count > best.items.count
                    || (best.items.isEmpty && rows.count > bestRows.count) {
                    best = parsed
                    bestRows = rows
                }
            }
        }
        return (best, bestRows)
    }

    /// Redraws the image so `imageOrientation` is baked into the pixels — a no-op for
    /// already-upright images.
    private static func normalizedUpright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        // Render at the image's own scale: the renderer's default is the SCREEN scale
        // (3x on device), which would blow a 12 MP photo up to a ~9x larger bitmap and
        // get the app killed for memory.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Reused across the OCR preprocessing passes — constructing a `CIContext` per call is
    /// expensive, and it's safe to render from concurrently.
    private static let sharedCIContext = CIContext()

    /// Produces a grayscale, contrast-boosted, sharpened copy of the receipt for a second OCR
    /// pass under poor conditions. Thermal receipts fade, wrinkle, and pick up glare or
    /// handwriting; flattening color, stretching contrast, and firming up edges recovers
    /// characters the raw photo loses. Returns `nil` if the filter chain can't be rendered,
    /// in which case the caller keeps the first pass.
    private static func enhancedForOCR(_ cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        // Desaturate and stretch contrast so faint ink separates from the paper; a small
        // brightness lift keeps thin strokes from being crushed to the page color.
        let toned = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.3,
            kCIInputBrightnessKey: 0.05,
        ])
        // Sharpen luminance edges to firm up characters softened by wrinkles or a slightly
        // out-of-focus photo.
        let sharpened = toned.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.5,
        ])
        return sharedCIContext.createCGImage(sharpened, from: sharpened.extent)
    }

    /// Detects the dominant document (the receipt) in the image and returns it cropped and
    /// perspective-corrected, or `nil` when detection isn't confident — callers then OCR
    /// the original frame. Runs off the main thread; Vision + CoreImage only, on-device.
    private static func deskewedDocument(in cgImage: CGImage) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectDocumentSegmentationRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
                guard (try? handler.perform([request])) != nil,
                      let document = request.results?.first,
                      document.confidence > 0.8 else {
                    continuation.resume(returning: nil)
                    return
                }

                let ciImage = CIImage(cgImage: cgImage)
                let size = ciImage.extent.size
                func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
                let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
                    "inputTopLeft": CIVector(cgPoint: scaled(document.topLeft)),
                    "inputTopRight": CIVector(cgPoint: scaled(document.topRight)),
                    "inputBottomLeft": CIVector(cgPoint: scaled(document.bottomLeft)),
                    "inputBottomRight": CIVector(cgPoint: scaled(document.bottomRight)),
                ])

                // Reject implausibly small detections (e.g. it latched onto a logo):
                // better to OCR the full frame than a fragment of it.
                let area = corrected.extent.width * corrected.extent.height
                guard area > size.width * size.height * 0.15,
                      let output = CIContext().createCGImage(corrected, from: corrected.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// Runs Vision text recognition and returns the receipt's rows (name and price merged
    /// onto one line via `groupIntoRows`). Empty on failure.
    private static func recognizeRows(_ cgImage: CGImage,
                                      orientation: CGImagePropertyOrientation = .up) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: groupIntoRows(observations))
            }
            request.recognitionLevel = .accurate
            // Language correction "fixes" digit strings into words (5.00 → S.OO, item
            // codes → dictionary words), which corrupts exactly the columns we need.
            request.usesLanguageCorrection = false
            // Consider smaller glyphs than the default (~1/32 of image height) so item rows
            // and prices on densely printed or far-away receipts aren't skipped as too small.
            request.minimumTextHeight = 0.01
            if #available(iOS 16.0, *) {
                // Latest recognizer + language auto-detection reads faint / non-English
                // receipts more reliably; correction stays off so digits survive.
                request.revision = VNRecognizeTextRequestRevision3
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
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
        if parsed.total > 0 { result.printedTotal = SplitEngine.roundToTwo(parsed.total) }
        // The model occasionally lists the (unlabeled) total as one more item; the same
        // arithmetic check used for the OCR path removes it here too.
        dropUnlabeledTotalRow(&result)
        reconcileAgainstPrintedTotals(&result)
        return result
    }

    /// Receipts print item names and prices in separate columns, which Vision returns as
    /// distinct text observations. This regroups observations that sit on the same
    /// horizontal line (similar `midY`) into one left-to-right string, so a name and its
    /// price end up on the same logical line for `parseItems` to pair.
    static func groupIntoRows(_ observations: [VNRecognizedTextObservation]) -> [String] {
        let entries = observations.compactMap { obs -> (text: String, midY: CGFloat, minX: CGFloat, height: CGFloat)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (text, obs.boundingBox.midY, obs.boundingBox.minX, obs.boundingBox.height)
        }
        guard !entries.isEmpty else { return [] }
        // Top-to-bottom (Vision's origin is bottom-left, so larger y is higher).
        let sorted = entries.sorted { $0.midY > $1.midY }

        // Same-row tolerance derived from the receipt's actual text size: a fixed fraction
        // of image height splits the name from its price on close-up photos (rows look
        // "tall") and merges adjacent lines on far-away ones. Half the median glyph height
        // tracks the print size whatever the framing.
        let heights = entries.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let rowTolerance = max(0.008, medianHeight * 0.5)

        var rows: [[(text: String, midY: CGFloat, minX: CGFloat, height: CGFloat)]] = []
        for entry in sorted {
            // Compare against the running average of the row, not its first member, so a
            // slightly tilted receipt doesn't fragment one printed line into several rows.
            if let row = rows.last {
                let rowMidY = row.reduce(0) { $0 + $1.midY } / CGFloat(row.count)
                if abs(rowMidY - entry.midY) < rowTolerance {
                    rows[rows.count - 1].append(entry)
                    continue
                }
            }
            rows.append([entry])
        }

        return rows.map { row in
            row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ")
        }
    }

    /// Pairs each text line with a trailing price (e.g. "Burger  12.99"). Item rows
    /// become `ReceiptItem`s; tax and tip rows are pulled out so they can be allocated
    /// proportionally across the items rather than treated as purchasable lines.
    static func parseItems(from lines: [String]) -> ReceiptScanResult {
        // A trailing price, tolerating a currency symbol before it ("$12.99"), thousands
        // separators ("1,234.56"), and the tax-flag letters many registers print after the
        // amount ("12.99 T", "4.50 A*") — all of which the previous stricter pattern missed.
        let priceRegex = try? NSRegularExpression(
            pattern: #"[$€£¥]?\s*(\d{1,3}(?:[.,]\d{3})*[.,]\d{2})\s*[A-Za-z*]{0,2}\s*$"#
        )
        guard let priceRegex else { return ReceiptScanResult() }

        var result = ReceiptScanResult()
        // Once a subtotal/total row appears, the item section is over — anything priced
        // below it is the payment block (cash, change, card auth), not a purchase.
        var itemSectionEnded = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let lower = line.lowercased()

            // Discount/meta lines under an item are not purchases, but they end in a
            // number and would otherwise be parsed as one.
            if metaLineKeywords.contains(where: { lower.contains($0) }) { continue }

            let range = NSRange(line.startIndex..., in: line)
            guard let match = priceRegex.firstMatch(in: line, range: range),
                  let priceRange = Range(match.range(at: 1), in: line) else { continue }

            guard let price = decimalValue(String(line[priceRange])), price > 0 else { continue }
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
            if nonItemKeywords.contains(where: { lower.contains($0) }) {
                // Record the printed subtotal/total rows — they're the receipt's own
                // ground truth, used below to check the items actually add up.
                if lower.contains("subtotal") || lower.contains("sub total") || lower.contains("sub-total") {
                    result.printedSubtotal = max(result.printedSubtotal ?? 0, rounded)
                } else if lower.contains("total") || lower.contains("amount due") || lower.contains("balance") {
                    result.printedTotal = max(result.printedTotal ?? 0, rounded)
                }
                if lower.contains("total") || lower.contains("amount") || lower.contains("balance") {
                    itemSectionEnded = true
                }
                continue
            }
            guard !itemSectionEnded else { continue }

            var name = String(line[line.startIndex..<priceRange.lowerBound])

            // An explicit multiplier ("2 x Beer 12.00") prices the LINE; expand it into
            // per-unit rows so each unit can be assigned to a different person.
            var unitCount = 1
            if let qtyMatch = name.range(of: #"^\s*(\d{1,2})\s*[xX×@]\s+"#, options: .regularExpression) {
                let digits = name[qtyMatch].filter(\.isNumber)
                if let qty = Int(digits), (2...20).contains(qty), rounded >= Double(qty) * 0.01 {
                    unitCount = qty
                }
                name.removeSubrange(qtyMatch)
            }
            // Drop a bare leading count or register item code, optionally preceded by a
            // single tax-flag letter (e.g. "1  Grande Latte" → "Grande Latte", Costco's
            // "E 1830455 KS BAGUETTE" → "KS BAGUETTE").
            else if let qtyRange = name.range(of: #"^\s*(?:[A-Za-z]\s+)?\d{4,}\s+|^\s*\d{1,3}\s+"#,
                                              options: .regularExpression) {
                name.removeSubrange(qtyRange)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-*x×@$€£¥"))
            if name.isEmpty { name = "Item" }

            // Split the line total into unit prices that sum back EXACTLY to the line
            // ("10.00 / 3" as 3.34 + 3.33 + 3.33, not 3 × 3.33 = 9.99) so expanding a
            // multiplier row never drifts the receipt total.
            let unitPrices = SplitEngine.equalShares(total: rounded, count: unitCount)
            for unitPrice in unitPrices {
                result.items.append(ReceiptItem(name: name, price: unitPrice))
            }
        }

        dropUnlabeledTotalRow(&result)
        reconcileAgainstPrintedTotals(&result)
        return result
    }

    /// Checks the parsed items against the receipt's own printed subtotal/total and
    /// repairs the two failure modes that make the final amount wrong:
    ///
    /// - **Items sum short of the printed amount** (OCR/model missed or misread lines):
    ///   append a single "Other items" row carrying the shortfall, so the expense total
    ///   matches what was actually charged and the user can rename/edit the remainder.
    /// - **Items sum over the printed amount** (a stray non-item row was parsed as a
    ///   purchase): drop the single item whose price exactly equals the overage.
    ///
    /// The items target is the printed subtotal when one was read, otherwise the printed
    /// grand total minus detected tax/tip. No-op when neither is known.
    private static func reconcileAgainstPrintedTotals(_ result: inout ReceiptScanResult) {
        guard !result.items.isEmpty else { return }
        let target: Double
        if let subtotal = result.printedSubtotal {
            target = subtotal
        } else if let total = result.printedTotal {
            target = SplitEngine.roundToTwo(total - (result.tax ?? 0) - (result.tip ?? 0))
        } else {
            return
        }
        guard target > 0 else { return }

        let itemsSum = SplitEngine.roundToTwo(result.items.reduce(0) { $0 + $1.price })
        let shortfall = SplitEngine.roundToTwo(target - itemsSum)

        if shortfall >= 0.02 {
            result.items.append(ReceiptItem(name: "Other items", price: shortfall))
        } else if shortfall <= -0.02,
                  let overIndex = result.items.firstIndex(where: { abs($0.price + shortfall) <= 0.02 }) {
            result.items.remove(at: overIndex)
        }
    }

    /// Receipts sometimes print the total with no recognizable label (or OCR garbles it),
    /// so it lands in `items` and doubles the bill. If the single largest "item" equals
    /// the sum of everything else (optionally plus tax/tip), it's that total row — drop it.
    private static func dropUnlabeledTotalRow(_ result: inout ReceiptScanResult) {
        guard result.items.count >= 2,
              let maxIndex = result.items.indices.max(by: { result.items[$0].price < result.items[$1].price })
        else { return }
        let largest = result.items[maxIndex].price
        let restSum = result.items.enumerated()
            .filter { $0.offset != maxIndex }
            .reduce(0.0) { $0 + $1.element.price }
        let withTaxTip = restSum + (result.tax ?? 0) + (result.tip ?? 0)
        if abs(largest - restSum) <= 0.02 || abs(largest - withTaxTip) <= 0.02 {
            result.items.remove(at: maxIndex)
        }
    }

    /// Parses a printed amount that may use either separator convention: the LAST "." or
    /// "," is the decimal point, anything before it is a thousands separator (so both
    /// "1,234.56" and "1.234,56" resolve to 1234.56).
    private static func decimalValue(_ text: String) -> Double? {
        guard let decimalIndex = text.lastIndex(where: { $0 == "." || $0 == "," }) else {
            return Double(text.filter(\.isNumber))
        }
        let whole = text[..<decimalIndex].filter(\.isNumber)
        let fraction = text[text.index(after: decimalIndex)...].filter(\.isNumber)
        return Double("\(whole).\(fraction)")
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

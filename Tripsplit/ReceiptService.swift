import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit

// MARK: - Receipt scanning (on-device, Apple Vision)

/// Reads line items off a receipt photo using Apple's on-device text recognition — no
/// network, no API key, fully private. Item extraction is heuristic (Vision returns
/// text lines; we pair names with trailing prices), so the results are presented as an
/// editable list the user can correct before saving.
/// The outcome of scanning a receipt: the purchasable line items plus any tax/tip rows
/// detected separately so they can be allocated across the items.
struct ReceiptScanResult {
    var items: [ReceiptItem] = []
    var tax: Double? = nil
    var tip: Double? = nil
}

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

    /// Recognizes text and parses it into line items plus tax/tip. Returns an empty
    /// result if nothing usable is found.
    static func scan(_ image: UIImage) async -> ReceiptScanResult {
        guard let cgImage = image.cgImage else { return ReceiptScanResult() }

        let lines: [String] = await withCheckedContinuation { continuation in
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

        return parseItems(from: lines)
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

/// Uploads receipt images to a Supabase Storage bucket and returns their public URL.
/// Run the storage section of `supabase_schema.sql` once to create the `receipts`
/// bucket and its access policies.
actor ReceiptStorage {
    static let shared = ReceiptStorage()

    private let session = BackendSecurity.secureSession
    private let bucket = "receipts"

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

    /// Uploads JPEG data at `path` (e.g. "<userID>/<expenseID>.jpg") and returns the
    /// public URL. The signed-in user's token authorizes the write via storage RLS.
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
        return "\(SupabaseConfig.url)/storage/v1/object/public/\(bucket)/\(path)"
    }
}

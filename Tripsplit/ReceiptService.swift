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
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-*x×@"))
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

import SwiftUI
import UIKit

/// A snapshot of the selected export. PDFs are ready on disk before presentation.
struct TripShareContent: Identifiable {
    let id = UUID()
    private let text: String?
    private let file: URL?

    init(text: String) {
        self.text = text
        file = nil
    }

    init(file: URL) {
        text = nil
        self.file = file
    }

    var activityItems: [Any] {
        if let file { return [file] }
        if let text { return [text] }
        return []
    }
}

struct TripActivitySheet: UIViewControllerRepresentable {
    let content: TripShareContent

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: content.activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

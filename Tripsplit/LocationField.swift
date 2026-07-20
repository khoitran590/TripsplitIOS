import SwiftUI
import MapKit
import Combine

// MARK: - Location autocomplete

/// Wraps `MKLocalSearchCompleter` — Apple's built-in places autocomplete, which needs no
/// API key and no location permission — to publish place suggestions as the user types a
/// trip destination.
@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Bias toward places (cities, regions, landmarks) rather than precise street
        // addresses, which suit a trip destination.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() { suggestions = [] }
}

extension PlaceSearchCompleter: MKLocalSearchCompleterDelegate {
    // Completer callbacks are delivered on the main thread, so it's safe to read results
    // and update published state directly via `assumeIsolated`.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}

/// A trip-location text field that shows Apple Maps autocomplete suggestions as the user
/// types, filling the field with the chosen place. Used in Add/Edit Trip.
struct LocationField: View {
    @Binding var text: String
    var placeholder = "Location (e.g. Vietnam)"

    @StateObject private var completer = PlaceSearchCompleter()
    @FocusState private var focused: Bool
    /// True while filling the field from a tapped suggestion, so `onChange` doesn't
    /// immediately re-query and reopen the list.
    @State private var isSelecting = false

    private var visibleSuggestions: [MKLocalSearchCompletion] {
        Array(completer.suggestions.prefix(5))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                if !text.isEmpty {
                    Button {
                        text = ""
                        completer.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            if focused && !visibleSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button { select(suggestion) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(.app(.subheadline)).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.app(.caption)).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if index < visibleSuggestions.count - 1 { Divider() }
                    }
                }
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
            }
        }
        .onChange(of: text) { _, newValue in
            if isSelecting { isSelecting = false; return }
            completer.update(query: newValue)
        }
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        isSelecting = true
        text = suggestion.title
        completer.clear()
        focused = false
    }
}

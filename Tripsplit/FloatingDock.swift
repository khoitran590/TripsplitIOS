import SwiftUI
import UIKit

// MARK: - Dock

/// Compact bordered capsule inspired by the supplied expanding-label navigation:
/// inactive tabs stay icon-only and the active tab springs open to reveal its name.
struct FloatingDock: View {
    @Binding var selectedTab: DockTab
    @AppStorage("navbarTransparency") private var navbarTransparency = 0.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Keep the stored preference defensive in case an older/newer build writes a
    /// value outside the range exposed by Settings.
    private var backgroundVisibility: Double {
        if reduceTransparency || colorSchemeContrast == .increased { return 1 }
        return 1 - min(max(navbarTransparency, 0), 0.55)
    }

    private var highContrastInk: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    dockButtons
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            } else {
                dockButtons
            }
        }
        .padding(6)
        .background {
            Capsule()
                .fill(Theme.surface.opacity(backgroundVisibility))
        }
        .background {
            Capsule()
                .fill(.regularMaterial)
                .opacity(backgroundVisibility)
        }
        .overlay {
            Capsule()
                .strokeBorder(Theme.separator.opacity(0.95 * backgroundVisibility), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14 * backgroundVisibility), radius: 14, y: 6)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82), value: selectedTab)
        .animation(.snappy, value: navbarTransparency)
        // Make the whole bottom strip swipeable, not just the capsule itself, so a
        // thumb swipe anywhere along the dock changes tabs — while staying confined
        // to the dock area (a screen-wide gesture would steal map pans and Explore's
        // horizontal destination rails).
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let projected = value.predictedEndTranslation.width
                    // Accept either a deliberate drag or a quick flick (short travel
                    // but high velocity), as long as it's predominantly horizontal.
                    guard abs(horizontal) > abs(value.translation.height) * 1.4,
                          abs(horizontal) >= 38 || abs(projected) >= 90
                    else { return }
                    moveSelection(for: horizontal)
                }
        )
        .accessibilityHint("Swipe left or right on the dock to change tabs")
    }

    private var dockButtons: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases, id: \.self) { tab in
                let isActive = tab == selectedTab

                Button { select(tab) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.app(.body, .semibold))
                        Text(LocalizedStringKey(tab.rawValue))
                            .font(.app(.caption2, isActive ? .bold : .medium))
                            .multilineTextAlignment(.center)
                            // Clamp to one line in the fixed pill layout so a longer
                            // localized label ('Explorar', 'Viajes') can't wrap and grow
                            // the dock. The accessibility branch scrolls horizontally, so
                            // there labels keep their natural width instead.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                    }
                    // The selected capsule and accessibility trait already carry
                    // state. Keeping every label/icon on the primary foreground
                    // avoids accent-on-accent contrast at caption sizes.
                    .foregroundStyle(highContrastInk)
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 4 : 8)
                    .background {
                        // Scale the button backing with the same visibility the outer
                        // capsule uses, so the navbar-transparency slider still reaches
                        // the button area. `backgroundVisibility` pins to 1 under Reduce
                        // Transparency / Increased Contrast, keeping the ink's backing
                        // fully opaque in the modes that need the contrast.
                        Capsule()
                            .fill(Theme.surface.opacity(backgroundVisibility))
                            .overlay {
                                if isActive {
                                    Capsule().fill(Theme.accent.opacity(0.13))
                                }
                            }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(tab.rawValue)))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
    }

    private func moveSelection(for horizontalTranslation: CGFloat) {
        let tabs = DockTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab) else { return }
        let nextIndex = horizontalTranslation < 0 ? index + 1 : index - 1
        guard tabs.indices.contains(nextIndex) else {
            // Already at the end of the row — acknowledge the swipe with a soft bump
            // instead of silently ignoring it.
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
            return
        }
        select(tabs[nextIndex])
    }

    private func select(_ tab: DockTab) {
        guard tab != selectedTab else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)) {
            selectedTab = tab
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

#Preview {
    ContentView()
}

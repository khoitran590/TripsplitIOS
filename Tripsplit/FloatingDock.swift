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

    /// Wabi-Sabi lifts the dock out of the ground and presses the active tab into it.
    private var softElevation: Bool { ThemeManager.shared.selection.usesSoftElevation }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    tabRow
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            } else {
                tabRow
            }
        }
        .padding(6)
        .background {
            if softElevation {
                // Composited first so the transparency slider fades the shadows with the fill.
                // Shallower than a card, with a faint highlight: the dock floats over
                // photos and maps, where a full-strength highlight glows.
                SoftSurface(shape: Capsule(), depth: 6, highlightStrength: 0.3)
                    .compositingGroup()
                    .opacity(backgroundVisibility)
            } else {
                Capsule()
                    .fill(Theme.surface.opacity(backgroundVisibility))
            }
        }
        .background {
            Capsule()
                .fill(.regularMaterial)
                .opacity(backgroundVisibility)
        }
        .overlay {
            Capsule()
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(shadowOpacity * backgroundVisibility), radius: softElevation ? 14 : 20, y: 6)
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

    /// Light mode floats on shadow alone; dark mode needs a faint rim to separate the
    /// dock from dark map tiles. Increased contrast always gets the full separator.
    private var borderColor: Color {
        if colorSchemeContrast == .increased { return Theme.separator.opacity(0.95 * backgroundVisibility) }
        if softElevation { return .clear }
        return colorScheme == .dark ? .white.opacity(0.08 * backgroundVisibility) : .clear
    }

    private var shadowOpacity: Double {
        if softElevation { return 0 }
        return colorScheme == .dark ? 0.35 : 0.08
    }

    /// Wabi-Sabi keeps its labelled, pressed-well dock; every other theme uses the
    /// minimal icon row.
    @ViewBuilder
    private var tabRow: some View {
        if softElevation {
            dockButtons
        } else {
            minimalDockButtons
        }
    }

    /// Line icons with only the active tab filled and labelled, so the dock reads as
    /// one quiet object rather than four buttons.
    private var minimalDockButtons: some View {
        HStack(spacing: 2) {
            ForEach(DockTab.allCases, id: \.self) { tab in
                let isActive = tab == selectedTab

                Button { select(tab) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.outlineSystemImage)
                            .symbolVariant(isActive ? .fill : .none)
                            .font(.app(.body, isActive ? .semibold : .regular))
                        if isActive {
                            Text(LocalizedStringKey(tab.rawValue))
                                .font(.app(.caption2, .semibold))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                        }
                    }
                    .foregroundStyle(colorSchemeContrast == .increased ? highContrastInk : (isActive ? Theme.ink : Theme.textSecondary))
                    .frame(minWidth: 56, minHeight: 44)
                    .padding(.horizontal, 4)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(tab.rawValue)))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
    }

    private var dockButtons: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases, id: \.self) { tab in
                let isActive = tab == selectedTab

                Button { select(tab) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.app(.body, .semibold))
                            // The pressed well isn't accent-filled, so a sage glyph keeps its contrast.
                            .foregroundStyle(softElevation && isActive && colorSchemeContrast != .increased
                                             ? Theme.accent : highContrastInk)
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
                        // Light mode keeps the tabs visually unified inside the
                        // single outer dock instead of giving every icon its own
                        // filled capsule. Preserve the existing backing in dark mode,
                        // where it provides the contrast needed over darker surfaces.
                        if colorScheme == .dark {
                            Capsule()
                                .fill(Theme.surface.opacity(backgroundVisibility))
                                .overlay {
                                    if isActive {
                                        if softElevation {
                                            SoftSurface(shape: Capsule(), fill: Theme.background, depth: 3, pressed: true)
                                                .opacity(backgroundVisibility)
                                        } else {
                                            Capsule().fill(Theme.accent.opacity(0.13))
                                        }
                                    }
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

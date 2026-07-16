import SwiftUI
import UIKit

// MARK: - Dock

/// Compact bordered capsule inspired by the supplied expanding-label navigation:
/// inactive tabs stay icon-only and the active tab springs open to reveal its name.
struct FloatingDock: View {
    @Binding var selectedTab: DockTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases, id: \.self) { tab in
                let isActive = tab == selectedTab

                Button { select(tab) } label: {
                    HStack(spacing: isActive ? 8 : 0) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 22)
                        if isActive {
                            Text(LocalizedStringKey(tab.rawValue))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .foregroundStyle(
                        isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary)
                    )
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, isActive ? 13 : 4)
                    .background(
                        isActive ? Theme.accent.opacity(0.13) : Color.clear,
                        in: .capsule
                    )
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(tab.rawValue)))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(6)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selectedTab)
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            selectedTab = tab
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

#Preview {
    ContentView()
}

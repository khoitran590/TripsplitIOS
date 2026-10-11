import SwiftUI

struct ProfileSyncBanner: View {
    @Environment(TripStore.self) private var store
    var body: some View {
        if store.profileSyncState != .synced {
            VStack(alignment: .leading, spacing: 6) {
                if store.profileSyncState == .syncing {
                    ProgressView("Profile saved on this device. Syncing…")
                } else {
                    Text("Profile saved on this device. Sync is pending.")
                    Button("Retry profile sync") { Task { await store.retryProfileSync() } }
                        .frame(minHeight: 44)
                }
            }
            .font(.app(.footnote))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("profile-sync-status")
        }
    }
}

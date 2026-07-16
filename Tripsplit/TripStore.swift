import SwiftUI
import Observation
import Combine
import UIKit

// MARK: - Trip Store

/// Latest-wins writer for the offline trips snapshot. Rapid UI mutations used to spawn
/// one detached full-array JSON encode/write each, allowing redundant work and an older
/// snapshot to finish after a newer one. This actor debounces writes and verifies the
/// caller's revision again after encoding before touching disk.
private actor TripsCacheWriter {
    private var latestRevision = 0
    private var pendingTask: Task<Void, Never>?

    func schedule(trips: [Trip], at url: URL, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .utility) {
                try? JSONEncoder().encode(trips)
            }.value
            guard !Task.isCancelled, revision == latestRevision, let data else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func cancel(through revision: Int) {
        // Ignore an older account-cancellation message if a newer account's scheduled
        // write reached the actor first.
        guard revision >= latestRevision else { return }
        latestRevision = revision
        pendingTask?.cancel()
        pendingTask = nil
    }
}

/// The app's in-memory source of truth for the current user and their trips.
/// All balance figures on the home screen are derived from here.
///
/// Main-actor isolated so its `@Observable` state (`trips`, `syncState`, `currentUser`, …)
/// is only ever mutated on the main thread. Network I/O still runs off-main because the
/// actual requests live in their own actors (`TripsRepository`, `ReceiptStorage`, …) and
/// the `await` points release the main thread. Mutating observable state off the main
/// thread (as the old non-isolated `persist`/`loadFromCloud` did) is undefined behavior
/// and was crashing the app right after sign-in once a trip needed re-syncing.
@Observable
@MainActor
final class TripStore {
    /// The home card always reports in USD, regardless of each trip's own currency.
    static let baseCurrency = "USD"

    var currentUser: Person
    var trips: [Trip]

    /// The signed-in user's profile photo, persisted across launches as JPEG data.
    var profileImageData: Data?

    /// The signed-in user's cloud-backed personal information (name, birthday, bio,
    /// visited places). Loaded from `public.profiles` on sign-in and saved back on edit;
    /// `displayName`/`avatarPath` are mirrored onto `currentUser`.
    var userProfile = UserProfile()

    /// Exchange rates with base USD (`usdRates["EUR"]` = EUR per 1 USD), used to
    /// convert each trip's currency into USD for the aggregated home card.
    var usdRates: [String: Double] = [:]

    /// The signed-in user's Supabase access token. Set by the app when the auth
    /// session changes; persistence to the cloud is skipped while this is nil.
    var accessToken: String?

    /// Called when Supabase rejects a request because the access token expired.
    @ObservationIgnored var refreshAccessToken: (() async throws -> String?)?

    /// Live cloud-sync status, surfaced in the UI so failed saves aren't silent.
    enum SyncState: Equatable { case idle, syncing, failed }
    var syncState: SyncState = .idle

    /// A user-facing reason for the most recent sync failure (e.g. an expired session),
    /// shown in the failure banner. Nil for generic server/HTTP failures.
    var syncErrorMessage: String?

    /// Number of in-flight cloud saves. The "Saving to cloud…" banner is only shown when a
    /// save is still running after a short grace period — flipping `syncState` synchronously
    /// on every tap inserted/removed the banner (a full home-screen relayout) twice per
    /// mutation, which is what made buttons feel laggy.
    @ObservationIgnored private var activeSaveCount = 0

    /// Persistence is latest-wins per trip. A burst of edits gets one cloud write after a
    /// short debounce; edits arriving during a request are serialized into one follow-up
    /// request, so an older response can never overwrite a newer snapshot.
    @ObservationIgnored private var pendingTripSaves: [Trip.ID: Trip] = [:]
    @ObservationIgnored private var tripSaveRevisions: [Trip.ID: Int] = [:]
    @ObservationIgnored private var tripSaveTasks: [Trip.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tripSaveWorkerIDs: [Trip.ID: UUID] = [:]

    /// The offline cache is also debounced and revisioned so rapid edits don't repeatedly
    /// encode the complete trips array or finish writes out of order.
    @ObservationIgnored private let cacheWriter = TripsCacheWriter()
    @ObservationIgnored private var cacheRevision = 0

    /// Marks a cloud save as started; shows the syncing banner only if it's still running
    /// after 400 ms so quick saves never cause layout churn.
    private func beginSyncActivity() {
        activeSaveCount += 1
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if activeSaveCount > 0 && syncState != .failed { syncState = .syncing }
        }
    }

    /// Marks a cloud save as finished, updating the visible state once nothing is in flight.
    private func endSyncActivity(failed: Bool, message: String? = nil) {
        activeSaveCount = max(0, activeSaveCount - 1)
        if failed {
            syncState = .failed
            syncErrorMessage = message
        } else if activeSaveCount == 0 {
            syncState = .idle
            syncErrorMessage = nil
        }
    }

    /// Builds the failure-banner subtitle. Client-side problems (session/network, which
    /// carry no HTTP status) already have a meaningful message. For a server rejection
    /// (401/403 — where an unauthenticated write surfaces), it probes whether the session
    /// is actually accepted, so we can tell "your session isn't reaching the server"
    /// (sign in again) from a transient/genuine-permission error.
    private func syncFailureMessage(_ error: Error) async -> String? {
        guard let authError = error as? AuthError else { return nil }
        if authError.statusCode == nil { return authError.message }
        guard authError.statusCode == 401 || authError.statusCode == 403 else { return nil }
        guard let token = try? await authorizedAccessToken(),
              await AuthService.shared.isSessionAccepted(accessToken: token) else {
            return "Your session isn't reaching the server. Please sign out and sign in again."
        }
        return nil
    }

    /// IDs of trips deleted locally whose cloud delete hasn't succeeded yet (e.g. the
    /// delete happened offline). Persisted so the deletion survives relaunch, retried on
    /// the next sync, and used to stop `loadFromCloud` from resurrecting them.
    private(set) var pendingDeletions: Set<Trip.ID> = []

    private static let pendingDeletionsKey = "tripsplit.pendingDeletions"
    private struct StoredProfile: Codable {
        var name: String
        var imageData: Data?
        var avatarURL: String?
        // Optional so profiles cached before these fields existed still decode.
        var dateOfBirth: Date?
        var bio: String?
        var visitedPlaces: [String]?
        var savedPlaceKeys: [String]?
        var savedDestinationIDs: [String]?
    }

    /// Returns a UserDefaults key scoped to the given user UUID, so different accounts
    /// on the same device never share profile data.
    private static func profileKey(for userID: UUID) -> String {
        "tripsplit.profile.\(userID.uuidString)"
    }

    init() {
        currentUser = Person(name: "", color: Color(hex: 0x6366F1))
        profileImageData = nil
        trips = []
        pendingDeletions = Self.loadPendingDeletions()
    }

    private static func loadPendingDeletions() -> Set<Trip.ID> {
        guard let raw = UserDefaults.standard.array(forKey: pendingDeletionsKey) as? [String] else { return [] }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func savePendingDeletions() {
        UserDefaults.standard.set(pendingDeletions.map(\.uuidString), forKey: Self.pendingDeletionsKey)
    }

    // MARK: Local trips cache (instant/offline launch)

    /// On-disk snapshot of the signed-in user's trips so a relaunch paints real data
    /// immediately (including offline) instead of an empty list while `loadFromCloud`
    /// round-trips. Keyed by user UUID so accounts on the same device never see each
    /// other's trips. Lives in Caches: losing it only costs the instant first paint —
    /// Supabase stays the source of truth.
    nonisolated private static func tripsCacheURL(for userID: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("trips-\(userID.uuidString.lowercased()).json")
    }

    /// Snapshots the current trips and writes them to the local cache off the main actor.
    private func cacheTripsLocally() {
        let snapshot = trips
        let userID = currentUser.id
        cacheRevision += 1
        let revision = cacheRevision
        let url = Self.tripsCacheURL(for: userID)
        Task {
            await cacheWriter.schedule(trips: snapshot, at: url, revision: revision)
        }
    }

    private func cancelPendingCacheWrite() {
        cacheRevision += 1
        let revision = cacheRevision
        Task { await cacheWriter.cancel(through: revision) }
    }

    nonisolated private static func loadCachedTrips(for userID: UUID) -> [Trip]? {
        guard let data = try? Data(contentsOf: tripsCacheURL(for: userID)) else { return nil }
        return try? JSONDecoder().decode([Trip].self, from: data)
    }

    /// Fills an empty trips list from the local cache while the cloud fetch is in flight.
    /// Only ever *fills* — if `loadFromCloud` lands first (or the user switched accounts
    /// mid-read), the cached copy is discarded so it can never clobber fresher data.
    private func restoreCachedTrips(for userID: UUID) {
        guard trips.isEmpty else { return }
        Task {
            let cached = await Task.detached(priority: .userInitiated) {
                Self.loadCachedTrips(for: userID)
            }.value
            guard let cached, !cached.isEmpty,
                  self.trips.isEmpty, self.currentUser.id == userID else { return }
            self.trips = cached.filter { !self.pendingDeletions.contains($0.id) }
        }
    }

    /// Updates the signed-in user's display name and photo, persisting both so they
    /// survive across launches. Also pushes the updated name into every trip immediately.
    func updateProfile(name: String, imageData: Data?) {
        let nameChanged = currentUser.name != name
        currentUser.name = name
        userProfile.displayName = name
        profileImageData = imageData
        persistLocalProfile()
        guard nameChanged else { return }
        for index in trips.indices {
            if let memberIndex = trips[index].members.firstIndex(where: { $0.id == currentUser.id }) {
                trips[index].members[memberIndex].name = name
                persist(trips[index])
            }
        }
    }

    /// Uploads the given JPEG to Supabase Storage as the user's avatar, stores the storage
    /// path on `currentUser.avatarURL`, and pushes the updated Person into every trip so
    /// other members see the new photo on their next sync. (The field name is historical;
    /// it now holds a path that `signedImageURL` resolves at display time.)
    func uploadAndSetAvatar(_ jpeg: Data) async {
        guard let accessToken = try? await authorizedAccessToken() else { return }
        let path = "\(currentUser.id.uuidString.lowercased())/profile.jpg"
        guard let url = try? await withFreshTokenIfNeeded(initialToken: accessToken, operation: { token in
            try await ReceiptStorage.shared.upload(jpeg, path: path, accessToken: token)
        }) else { return }
        currentUser.avatarURL = url
        userProfile.avatarPath = url
        // Persist locally so the URL survives a relaunch.
        persistLocalProfile()
        // Push the updated Person (name + avatarURL) into every trip the user belongs to
        // so other members pick up the change on their next loadFromCloud.
        for index in trips.indices {
            if let memberIndex = trips[index].members.firstIndex(where: { $0.id == currentUser.id }) {
                trips[index].members[memberIndex].name = currentUser.name
                trips[index].members[memberIndex].avatarURL = url
                persist(trips[index])
            }
        }
    }

    /// Clears the in-memory profile. Called on sign-out so the next account starts blank.
    func resetProfile() {
        currentUser.name = ""
        profileImageData = nil
        userProfile = UserProfile()
    }

    /// Writes the full profile (name, photo, avatar path, birthday, bio, places) to
    /// UserDefaults keyed by user UUID, so it survives relaunches and account switches.
    private func persistLocalProfile() {
        let stored = StoredProfile(
            name: currentUser.name,
            imageData: profileImageData,
            avatarURL: currentUser.avatarURL,
            dateOfBirth: userProfile.dateOfBirth,
            bio: userProfile.bio,
            visitedPlaces: userProfile.visitedPlaces,
            savedPlaceKeys: userProfile.savedPlaceKeys,
            savedDestinationIDs: userProfile.savedDestinationIDs
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.profileKey(for: currentUser.id))
        }
    }

    /// Saves an edited profile: applies it locally (and to every trip via the display
    /// name), uploads a new avatar when the photo changed, then upserts the row in
    /// `public.profiles` so the profile follows the account to other devices.
    ///
    /// `imageData == nil` means "no new photo picked", not "remove" — after a reinstall
    /// the local JPEG cache is empty while the cloud avatar still exists, and treating
    /// nil as removal wiped it. Removal is explicit via `removePhoto`.
    func saveProfile(_ profile: UserProfile, imageData: Data?, removePhoto: Bool = false) async {
        userProfile = profile
        userProfile.avatarPath = currentUser.avatarURL
        let previousImageData = profileImageData
        updateProfile(name: profile.displayName,
                      imageData: removePhoto ? nil : (imageData ?? profileImageData))
        if let imageData, !removePhoto, imageData != previousImageData || currentUser.avatarURL == nil {
            await uploadAndSetAvatar(imageData)
        } else if removePhoto {
            currentUser.avatarURL = nil
            userProfile.avatarPath = nil
            persistLocalProfile()
        }
        await pushProfileToCloud()
    }

    /// Updates the cloud-backed bookmark lists (map places and/or Explore destinations),
    /// persisting locally and upserting `public.profiles` so they survive reinstalls.
    func updateSavedPlaces(mapKeys: [String]? = nil, destinationIDs: [String]? = nil) {
        if let mapKeys { userProfile.savedPlaceKeys = mapKeys }
        if let destinationIDs { userProfile.savedDestinationIDs = destinationIDs }
        persistLocalProfile()
        Task { await pushProfileToCloud() }
    }

    /// Loads the account's profile row from Supabase, replacing the local cache. When
    /// the cloud row is still empty (fresh account or pre-profile install) but a local
    /// profile exists, the local one is pushed up instead.
    func loadProfileFromCloud() async {
        guard let accessToken = try? await authorizedAccessToken() else { return }
        let userID = currentUser.id
        guard let fetched = try? await withFreshTokenIfNeeded(initialToken: accessToken, operation: { token in
            try await ProfilesRepository.shared.fetch(userID: userID, accessToken: token)
        }) else { return }

        if fetched.displayName.trimmingCharacters(in: .whitespaces).isEmpty && !currentUser.name.isEmpty {
            // Cloud row never populated — seed it from this device's profile.
            await pushProfileToCloud()
            return
        }
        // Bookmarks saved on this device before the cloud fetch (e.g. while offline, or
        // made before bookmarks became cloud-backed) are merged in rather than clobbered.
        let localPlaceKeys = userProfile.savedPlaceKeys
        let localDestinationIDs = userProfile.savedDestinationIDs
        userProfile = fetched
        userProfile.savedPlaceKeys = fetched.savedPlaceKeys
            + localPlaceKeys.filter { !fetched.savedPlaceKeys.contains($0) }
        userProfile.savedDestinationIDs = fetched.savedDestinationIDs
            + localDestinationIDs.filter { !fetched.savedDestinationIDs.contains($0) }
        currentUser.name = fetched.displayName
        if let path = fetched.avatarPath, !path.isEmpty {
            currentUser.avatarURL = path
        }
        persistLocalProfile()
        if userProfile.savedPlaceKeys != fetched.savedPlaceKeys
            || userProfile.savedDestinationIDs != fetched.savedDestinationIDs {
            await pushProfileToCloud()
        }
    }

    /// Upserts the in-memory profile into `public.profiles`. Best-effort: failures are
    /// logged but not surfaced, since the local copy is already saved.
    private func pushProfileToCloud() async {
        guard let accessToken = try? await authorizedAccessToken() else { return }
        var profile = userProfile
        profile.displayName = currentUser.name
        profile.avatarPath = currentUser.avatarURL
        let userID = currentUser.id
        do {
            try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                try await ProfilesRepository.shared.update(profile, userID: userID, accessToken: token)
            }
        } catch {
            BackendSecurity.log("Profile cloud save failed", error: error)
        }
    }

    private static func loadProfile(for userID: UUID) -> StoredProfile? {
        let key = profileKey(for: userID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredProfile.self, from: data)
    }

    /// Active (non-archived) trips available on this device. Cloud loads are already
    /// filtered by Supabase RLS, so every fetched row is a trip this account can access.
    /// Trips the user archived are excluded here so they drop out of the home cards,
    /// totals, and pickers, but remain reachable via `archivedTrips`.
    var myTrips: [Trip] { trips.filter { !$0.isArchived(for: currentUser.id) } }

    /// Trips the signed-in user has archived for themselves.
    var archivedTrips: [Trip] { trips.filter { $0.isArchived(for: currentUser.id) } }

    /// Archives or restores a trip for the current user only. Archiving is view state,
    /// not deletion: the trip stays in the cloud and stays visible to other members.
    func setArchived(_ archived: Bool, for tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let me = currentUser.id
        if archived {
            guard !trips[index].archivedBy.contains(me) else { return }
            trips[index].archivedBy.append(me)
        } else {
            trips[index].archivedBy.removeAll { $0 == me }
        }
        persist(trips[index])
    }

    /// Converts an amount in `code` into USD using the cached rates.
    func toUSD(_ amount: Double, from code: String) -> Double {
        if code == Self.baseCurrency { return amount }
        guard let rate = usdRates[code], rate > 0 else { return amount }
        return amount / rate
    }

    /// Cached conversion through the USD-based rate table. Returning nil is important:
    /// relabeling an unconverted value would make the home total confidently wrong.
    func cachedConversion(_ amount: Double, from source: String, to target: String) -> Double? {
        if source == target { return amount }
        let usdAmount: Double
        if source == Self.baseCurrency {
            usdAmount = amount
        } else {
            guard let sourceRate = usdRates[source], sourceRate > 0 else { return nil }
            usdAmount = amount / sourceRate
        }
        if target == Self.baseCurrency { return usdAmount }
        guard let targetRate = usdRates[target], targetRate > 0 else { return nil }
        return usdAmount * targetRate
    }

    /// Loads USD-based rates so the home card can normalize every trip's currency.
    func refreshRates() async {
        if let rates = try? await CurrencyService.shared.rates(base: Self.baseCurrency) {
            if rates != usdRates {
                usdRates = rates
            }
        }
    }

    /// The multiplier to convert an amount from `from` into `to` (e.g. 1 USD → ~25,000 VND).
    /// Returns 1 when the currencies match, or `nil` when live rates can't be fetched so
    /// callers can avoid silently relabeling amounts without actually converting them.
    func conversionRate(from: String, to: String) async -> Double? {
        if from == to { return 1 }
        guard let rates = try? await CurrencyService.shared.rates(base: from),
              let rate = rates[to], rate > 0 else { return nil }
        return rate
    }

    /// Returns a copy of `trip` with every monetary value multiplied by `rate`: member
    /// budgets, each expense's amount / tax / tip / per-member shares / receipt-item prices
    /// and exact-amount splits, and recorded settlement payments. Used when a trip's
    /// currency changes so stored amounts reflect the real converted value instead of being
    /// relabeled (e.g. a 100 USD expense becoming the equivalent VND amount, not "100 ₫").
    func applyingCurrencyConversion(_ trip: Trip, rate: Double) -> Trip {
        func conv(_ value: Double) -> Double { SplitEngine.roundToTwo(value * rate) }
        var converted = trip
        converted.budgets = converted.budgets.mapValues(conv)
        func convertExpense(_ expense: Expense) -> Expense {
            var e = expense
            e.amount = conv(e.amount)
            e.tax = conv(e.tax)
            e.tip = conv(e.tip)
            e.shares = e.shares.mapValues(conv)
            e.items = e.items.map { item in
                var i = item
                i.price = conv(i.price)
                i.amounts = i.amounts.mapValues(conv)
                return i
            }
            return e
        }
        converted.expenses = converted.expenses.map(convertExpense)
        converted.deletedExpenses = converted.deletedExpenses.map(convertExpense)
        converted.settlementRecords = converted.settlementRecords.mapValues { records in
            records.map { record in
                var r = record
                r.amount = conv(r.amount)
                return r
            }
        }
        if var itinerary = converted.itinerary {
            itinerary.totalBudget = conv(itinerary.totalBudget)
            itinerary.days = itinerary.days.map { day in
                var d = day
                d.stops = d.stops.map { stop in
                    var s = stop
                    s.cost = conv(s.cost)
                    return s
                }
                return d
            }
            if var suggestion = itinerary.suggestion {
                suggestion.days = suggestion.days.map { day in
                    var d = day
                    d.stops = d.stops.map { stop in
                        var s = stop
                        s.cost = conv(s.cost)
                        return s
                    }
                    return d
                }
                itinerary.suggestion = suggestion
            }
            converted.itinerary = itinerary
        }
        return converted
    }

    /// All four home-card figures, aggregated in USD. Computed in a single pass over the
    /// trips so `settlements()` (the expensive part, O(members² × expenses)) runs once per
    /// trip per render instead of once per figure.
    struct HomeTotals {
        var budget = 0.0, spent = 0.0, youOwe = 0.0, owedToYou = 0.0
        var unavailableCurrencies: Set<String> = []
        var available: Double { SplitEngine.roundToTwo(budget - spent) }
    }

    var homeTotals: HomeTotals { homeTotals(in: Self.baseCurrency) }

    func homeTotals(in displayCurrency: String) -> HomeTotals {
        var totals = HomeTotals()
        let me = currentUser.id
        for trip in myTrips {
            let code = trip.currencyCode
            guard let budget = cachedConversion(trip.budget(for: me), from: code, to: displayCurrency),
                  let spent = cachedConversion(trip.spent(for: me), from: code, to: displayCurrency)
            else {
                totals.unavailableCurrencies.insert(code)
                continue
            }
            totals.budget += budget
            totals.spent += spent
            for s in trip.settlements() {
                let key = "\(s.from.id.uuidString)->\(s.to.id.uuidString)"
                let confirmed = (trip.settlementRecords[key] ?? [])
                    .filter { $0.status == .confirmed }
                    .reduce(0.0) { $0 + $1.amount }
                let remaining = max(0, SplitEngine.roundToTwo(s.amount - confirmed))
                guard let converted = cachedConversion(remaining, from: code, to: displayCurrency) else {
                    totals.unavailableCurrencies.insert(code)
                    continue
                }
                if s.from.id == me { totals.youOwe += converted }
                if s.to.id == me { totals.owedToYou += converted }
            }
        }
        totals.budget = SplitEngine.roundToTwo(totals.budget)
        totals.spent = SplitEngine.roundToTwo(totals.spent)
        totals.youOwe = SplitEngine.roundToTwo(totals.youOwe)
        totals.owedToYou = SplitEngine.roundToTwo(totals.owedToYou)
        return totals
    }

    func trip(_ id: Trip.ID) -> Trip? { trips.first { $0.id == id } }

    func isCreator(of trip: Trip) -> Bool { trip.creatorID == currentUser.id }

    func addTrip(_ trip: Trip) {
        trips.append(trip)
        persist(trip)
    }

    func addExpense(_ expense: Expense, to tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].expenses.append(expense)
        persist(trips[index])
    }

    /// Replaces an existing expense (matched by id) and syncs the change.
    func updateExpense(_ expense: Expense, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              let expenseIndex = trips[index].expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        trips[index].expenses[expenseIndex] = expense
        persist(trips[index])
    }

    /// Soft-deletes an expense: pulls it out of the active split/settle math and into
    /// the trip's "Recently Deleted" list. It still counts toward `spent(for:)`, so the
    /// budget isn't refunded, and it can be restored later. Comments are kept so a
    /// restore brings the whole thread back.
    func deleteExpense(_ expenseID: Expense.ID, from tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              let eIndex = trips[index].expenses.firstIndex(where: { $0.id == expenseID }) else { return }
        var removed = trips[index].expenses.remove(at: eIndex)
        removed.deletedAt = Date()
        trips[index].deletedExpenses.insert(removed, at: 0)
        persist(trips[index])
    }

    /// Soft-deletes multiple expenses from one trip with a single cloud write. Used by the
    /// home screen's multi-select delete so a batch action doesn't fan out into N upserts.
    func deleteExpenses(_ expenseIDs: Set<Expense.ID>, from tripID: Trip.ID) {
        guard !expenseIDs.isEmpty,
              let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        var removed: [Expense] = []
        trips[index].expenses.removeAll { expense in
            guard expenseIDs.contains(expense.id) else { return false }
            var deleted = expense
            deleted.deletedAt = Date()
            removed.append(deleted)
            return true
        }
        guard !removed.isEmpty else { return }
        trips[index].deletedExpenses.insert(contentsOf: removed, at: 0)
        persist(trips[index])
    }

    /// Restores a previously soft-deleted expense back into the active list, returning it
    /// to the split/settle math (its budget contribution was never removed).
    func restoreExpense(_ expenseID: Expense.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              let dIndex = trips[index].deletedExpenses.firstIndex(where: { $0.id == expenseID }) else { return }
        var restored = trips[index].deletedExpenses.remove(at: dIndex)
        restored.deletedAt = nil
        trips[index].expenses.append(restored)
        persist(trips[index])
    }

    /// Replaces a whole trip (name, members, budgets, …) and syncs the change.
    func updateTrip(_ trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index] = trip
        persist(trip)
    }

    func addManualMember(name: String, to tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let color = Color(hex: memberPalette[max(trips[index].members.count - 1, 0) % memberPalette.count])
        let member = Person(name: trimmed, color: color)
        trips[index].members.append(member)
        trips[index].budgets[member.id] = 0
        persist(trips[index])
    }

    func inviteMember(email: String, displayName: String?, to tripID: Trip.ID) async throws {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedEmail.isEmpty else { return }
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to invite members.")
        }

        let result = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await TripsRepository.shared.inviteMember(tripID: tripID, email: trimmedEmail, accessToken: token)
        }
        guard result.accepted, let userID = result.memberUserID else {
            throw AuthError(message: "No TripSplit account was found for \(trimmedEmail). Ask them to sign up first, then invite them again.")
        }

        if !trips[index].members.contains(where: { $0.id == userID }) {
            let resolvedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = trimmedEmail.split(separator: "@").first.map(String.init) ?? trimmedEmail
            let color = Color(hex: memberPalette[max(trips[index].members.count - 1, 0) % memberPalette.count])
            trips[index].members.append(Person(id: userID, name: resolvedName?.isEmpty == false ? resolvedName! : fallbackName, color: color))
            trips[index].budgets[userID] = trips[index].budgets[userID] ?? 0
            persist(trips[index])
        }
    }

    func createInvitationLink(for tripID: Trip.ID) async throws -> URL {
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to create an invitation link.")
        }
        let token = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await TripsRepository.shared.createInvitationLink(tripID: tripID, accessToken: token)
        }
        var components = URLComponents()
        components.scheme = "tripsplit"
        components.host = "invite"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw AuthError(message: "Couldn't create an invitation link.")
        }
        return url
    }

    func acceptInvitationLink(_ url: URL) async throws {
        guard url.scheme == "tripsplit", url.host == "invite",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return }
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to accept this invitation.")
        }
        let tripID = try await withFreshTokenIfNeeded(initialToken: accessToken) { tokenValue in
            try await TripsRepository.shared.acceptInvitation(token: token, accessToken: tokenValue)
        }
        await loadFromCloud()
        guard let index = trips.firstIndex(where: { $0.id == tripID }),
              !trips[index].members.contains(where: { $0.id == currentUser.id }) else { return }
        trips[index].members.append(currentUser)
        trips[index].budgets[currentUser.id] = trips[index].budgets[currentUser.id] ?? 0
        persist(trips[index])
    }

    /// Sets a member's budget on a trip and syncs the change.
    func setBudget(_ amount: Double, for userID: Person.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].budgets[userID] = amount
        persist(trips[index])
    }

    /// Deletes a trip locally and from the cloud. If the cloud delete fails (or there's
    /// no token yet), the id is queued so the deletion is retried later and the trip isn't
    /// resurrected by `loadFromCloud` in the meantime.
    func deleteTrip(_ tripID: Trip.ID) {
        cancelScheduledSave(for: tripID)
        trips.removeAll { $0.id == tripID }
        pendingDeletions.insert(tripID)
        savePendingDeletions()
        cacheTripsLocally()

        beginSyncActivity()
        Task {
            do {
                guard let accessToken = try await authorizedAccessToken(requireServerAccepted: true) else {
                    self.endSyncActivity(failed: false)
                    return
                }
                try await TripsRepository.shared.delete(id: tripID, accessToken: accessToken)
                self.pendingDeletions.remove(tripID)
                self.savePendingDeletions()
                self.endSyncActivity(failed: false)
            } catch {
                self.endSyncActivity(failed: true)
            }
        }
    }

    /// Retries any queued cloud deletions, removing each id from the queue once Supabase
    /// confirms it's gone. Returns whether every pending deletion succeeded.
    @discardableResult
    private func flushPendingDeletions(accessToken: String) async -> Bool {
        var allSucceeded = true
        for tripID in pendingDeletions {
            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await TripsRepository.shared.delete(id: tripID, accessToken: token)
                }
                await MainActor.run {
                    self.pendingDeletions.remove(tripID)
                    self.savePendingDeletions()
                }
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    // MARK: Supabase sync

    /// Aligns the in-memory user's identity with their authenticated account, so shared
    /// trips and every balance figure derived from `currentUser.id` resolve consistently
    /// across launches and devices. The id is the Supabase user's stable UUID, read from
    /// the access token's `sub` claim.
    func bindIdentity(accessToken: String?) {
        guard let accessToken, let uuid = Self.userID(fromJWT: accessToken) else {
            // Signed out — clear in-memory profile and trips so nothing from the
            // previous account stays on screen. The per-user disk cache is kept, so
            // signing back in repaints instantly via `restoreCachedTrips`.
            cancelScheduledTripSaves()
            cancelPendingCacheWrite()
            resetProfile()
            feedPostsByTrip = [:]
            resetSignedImageURLs()
            trips = []
            return
        }
        // Identity changed: drop cached feeds so a different account never sees the
        // previous user's loaded posts.
        if currentUser.id != uuid {
            cancelScheduledTripSaves()
            cancelPendingCacheWrite()
            feedPostsByTrip = [:]
            resetSignedImageURLs()
        }
        currentUser.id = uuid
        // Load this specific user's saved profile (name, photo, avatarURL) keyed to their UUID.
        let stored = Self.loadProfile(for: uuid)
        currentUser.name = stored?.name ?? ""
        profileImageData = stored?.imageData
        currentUser.avatarURL = stored?.avatarURL
        userProfile = UserProfile()
        userProfile.displayName = stored?.name ?? ""
        userProfile.avatarPath = stored?.avatarURL
        userProfile.dateOfBirth = stored?.dateOfBirth
        userProfile.bio = stored?.bio ?? ""
        userProfile.visitedPlaces = stored?.visitedPlaces ?? []
        userProfile.savedPlaceKeys = stored?.savedPlaceKeys ?? Self.legacySavedList("mapSavedPlaceKeys")
        userProfile.savedDestinationIDs = stored?.savedDestinationIDs ?? Self.legacySavedList("exploreSavedDestinationIDs")
        // Paint this user's locally cached trips right away; loadFromCloud replaces them
        // with the authoritative copy as soon as the network round-trip finishes.
        restoreCachedTrips(for: uuid)
    }

    /// Reads a bookmark list saved by pre-cloud versions as a "|"-joined @AppStorage
    /// string, so existing bookmarks are carried into the cloud-backed profile.
    private static func legacySavedList(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: "|").map(String.init)
    }

    /// Decodes a JWT's payload (its middle segment) into a claims dictionary.
    nonisolated fileprivate static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Extracts the `sub` (subject = user id) claim from a JWT access token.
    nonisolated static func userID(fromJWT token: String) -> UUID? {
        guard let sub = jwtPayload(token)?["sub"] as? String else { return nil }
        return UUID(uuidString: sub)
    }

    /// The token's expiry (`exp`), if present.
    nonisolated fileprivate static func expiration(fromJWT token: String) -> Date? {
        guard let exp = jwtPayload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether `token` is a well-formed Supabase *user* JWT (carries a `sub`) that isn't
    /// already expired or about to expire. A write sent with a token that fails this check
    /// would reach Postgres as the anonymous role (`auth.uid()` null → RLS 403), so callers
    /// refresh instead of sending it.
    nonisolated fileprivate static func isUsableUserToken(_ token: String, now: Date = Date()) -> Bool {
        guard userID(fromJWT: token) != nil else { return false }
        guard jwtPayload(token)?["role"] as? String == "authenticated" else { return false }
        guard let exp = expiration(fromJWT: token) else { return true }
        return exp.timeIntervalSince(now) > 30
    }

    /// Loads the signed-in user's trips from Supabase, replacing the in-memory list.
    /// No-op when signed out (the app stays usable with local-only trips).
    ///
    /// Each creator-owned row is re-anchored to the signed-in user's stable id so trips
    /// created under a previous random local identity still show up and settle correctly.
    /// Shared trips created by other accounts are left with their original creator id.
    func loadFromCloud() async {
        guard let accessToken = try? await authorizedAccessToken() else { return }

        // Retry any queued deletions first so a trip pending deletion can't come back.
        await flushPendingDeletions(accessToken: accessToken)

        // Keep whatever we have if the server is unreachable; only replace on success.
        let loaded: [Trip]
        do {
            loaded = try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                try await TripsRepository.shared.fetch(accessToken: token)
            }
        }
        catch { return }
        var healed: [Trip] = []
        var toPersist: Set<Trip.ID> = []
        for trip in loaded {
            // Skip trips still queued for deletion (their cloud delete hasn't landed yet).
            if pendingDeletions.contains(trip.id) { continue }
            var anchored = trip.creatorID == currentUser.id || trip.members.contains { $0.id == currentUser.id }
                ? trip
                : trip.reanchoringCreator(to: currentUser.id)
            if anchored.creatorID != trip.creatorID { toPersist.insert(anchored.id) }
            // Keep the current user's name and avatar up-to-date so other members see
            // the latest profile without requiring an explicit trip edit.
            if let idx = anchored.members.firstIndex(where: { $0.id == currentUser.id }) {
                let stored = anchored.members[idx]
                if stored.name != currentUser.name || stored.avatarURL != currentUser.avatarURL {
                    anchored.members[idx].name = currentUser.name
                    anchored.members[idx].avatarURL = currentUser.avatarURL
                    toPersist.insert(anchored.id)
                }
            }
            healed.append(anchored)
        }
        // Never let the reload clobber local state the cloud hasn't seen yet:
        // - a trip with a save still in flight keeps its local (newer) copy rather
        //   than briefly rolling back to the stale cloud version;
        // - a trip missing from the cloud entirely (its first save failed, e.g.
        //   while the session was broken) is kept and re-uploaded instead of
        //   silently dropped — dropping it here destroyed the only copy.
        let cloudIDs = Set(healed.map(\.id))
        var merged = healed.map { pendingTripSaves[$0.id] ?? $0 }
        let localOnly = trips.filter { !cloudIDs.contains($0.id) && !pendingDeletions.contains($0.id) }
        merged.append(contentsOf: localOnly)
        await MainActor.run { self.trips = merged }
        cacheTripsLocally()
        for trip in merged where toPersist.contains(trip.id) { persist(trip) }
        for trip in localOnly { persist(trip) }
    }

    /// Pushes a single shared trip (members, budgets, and expenses) to Supabase, updating
    /// `syncState` so the UI can show progress and surface failures.
    private func persist(_ trip: Trip) {
        // Every local mutation funnels through here, so this keeps the offline snapshot
        // current even when the cloud save below fails or the user is offline.
        cacheTripsLocally()
        pendingTripSaves[trip.id] = trip
        tripSaveRevisions[trip.id, default: 0] += 1
        startSaveWorkerIfNeeded(for: trip.id)
    }

    private func startSaveWorkerIfNeeded(for tripID: Trip.ID) {
        guard tripSaveTasks[tripID] == nil else { return }
        let workerID = UUID()
        tripSaveWorkerIDs[tripID] = workerID
        tripSaveTasks[tripID] = Task { [weak self] in
            await self?.drainScheduledSaves(for: tripID, workerID: workerID)
        }
    }

    /// Debounces before each request and then drains at most one request at a time for a
    /// trip. JWT validity is checked locally on the happy path; the existing 401/403 retry
    /// pipeline refreshes rejected tokens, avoiding an extra `/auth/v1/user` round-trip on
    /// every tap-triggered save.
    private func drainScheduledSaves(for tripID: Trip.ID, workerID: UUID) async {
        defer { finishSaveWorker(for: tripID, workerID: workerID) }

        while !Task.isCancelled {
            guard let revision = tripSaveRevisions[tripID],
                  let trip = pendingTripSaves[tripID] else { return }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            // More edits arrived during the debounce; restart the quiet-time window with
            // the newest snapshot instead of sending this intermediate version.
            guard tripSaveRevisions[tripID] == revision else { continue }

            beginSyncActivity()
            let accessToken: String
            do {
                guard let token = try await authorizedAccessToken() else {
                    endSyncActivity(failed: false)
                    pendingTripSaves[tripID] = nil
                    tripSaveRevisions[tripID] = nil
                    return
                }
                accessToken = token
            } catch {
                if Task.isCancelled {
                    endSyncActivity(failed: false)
                } else {
                    let message = await syncFailureMessage(error)
                    endSyncActivity(failed: true, message: message)
                }
                pendingTripSaves[tripID] = nil
                tripSaveRevisions[tripID] = nil
                return
            }

            do {
                try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    let cloudTrip = self.tripForCloudSave(trip, accessToken: token)
                    try await TripsRepository.shared.upsert(cloudTrip, accessToken: token)
                }
                endSyncActivity(failed: false)
            } catch {
                if Task.isCancelled {
                    endSyncActivity(failed: false)
                } else {
                    let message = await syncFailureMessage(error)
                    endSyncActivity(failed: true, message: message)
                }
                pendingTripSaves[tripID] = nil
                tripSaveRevisions[tripID] = nil
                return
            }

            guard tripSaveRevisions[tripID] == revision else { continue }
            pendingTripSaves[tripID] = nil
            tripSaveRevisions[tripID] = nil
            return
        }
    }

    private func finishSaveWorker(for tripID: Trip.ID, workerID: UUID) {
        guard tripSaveWorkerIDs[tripID] == workerID else { return }
        tripSaveTasks[tripID] = nil
        tripSaveWorkerIDs[tripID] = nil
    }

    private func cancelScheduledSave(for tripID: Trip.ID) {
        tripSaveWorkerIDs[tripID] = nil
        tripSaveTasks[tripID]?.cancel()
        tripSaveTasks[tripID] = nil
        pendingTripSaves[tripID] = nil
        tripSaveRevisions[tripID] = nil
    }

    private func cancelScheduledTripSaves() {
        tripSaveTasks.values.forEach { $0.cancel() }
        tripSaveTasks = [:]
        tripSaveWorkerIDs = [:]
        pendingTripSaves = [:]
        tripSaveRevisions = [:]
    }

    /// Re-pushes every trip to Supabase. Used by the "Retry" action after a failed save.
    func retrySync() {
        cancelScheduledTripSaves()
        // Explicit retry: show progress immediately (the user asked for it), and clear the
        // failed state so the delayed-banner logic doesn't suppress the spinner.
        syncState = .syncing
        activeSaveCount += 1
        Task {
            do {
                guard let accessToken = try await authorizedAccessToken(requireServerAccepted: true) else {
                    self.endSyncActivity(failed: false)
                    return
                }
                let deletionsCleared = await flushPendingDeletions(accessToken: accessToken)
                for trip in trips {
                    try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
                        let cloudTrip = self.tripForCloudSave(trip, accessToken: token)
                        try await TripsRepository.shared.upsert(cloudTrip, accessToken: token)
                    }
                }
                self.endSyncActivity(failed: !deletionsCleared)
            } catch {
                let message = await self.syncFailureMessage(error)
                self.endSyncActivity(failed: true, message: message)
            }
        }
    }

    func uploadReceipt(_ jpeg: Data, path: String) async throws -> String {
        guard let accessToken = try await authorizedAccessToken() else {
            throw AuthError(message: "Sign in to upload the receipt photo.")
        }
        return try await withFreshTokenIfNeeded(initialToken: accessToken) { token in
            try await ReceiptStorage.shared.upload(jpeg, path: path, accessToken: token)
        }
    }

    /// Uploads a trip cover photo to the shared private `receipts` bucket and returns its
    /// storage path. The path is namespaced under the uploader's lowercased user id so
    /// storage RLS (which compares the leading folder to `auth.uid()`) accepts the write.
    func uploadTripCover(_ jpeg: Data, tripID: Trip.ID) async throws -> String {
        let path = "\(currentUser.id.uuidString.lowercased())/cover-\(tripID.uuidString.lowercased()).jpg"
        return try await uploadReceipt(jpeg, path: path)
    }

    /// Signed image URLs keyed by storage path, with the time they should be refreshed
    /// (kept under the server-side expiry so a cached URL never hands back an expired link).
    @ObservationIgnored private var signedURLCache: [String: (url: URL, refreshAfter: Date)] = [:]
    @ObservationIgnored private var signedURLTasks: [String: Task<URL?, Never>] = [:]

    /// Resolves a stored image reference (a storage path, or a legacy public/signed URL)
    /// into a currently-valid signed URL for display. Cached in-memory so repeated views of
    /// the same avatar/cover don't re-sign every render. Returns `nil` if signing fails
    /// (offline, signed out) so callers fall back to a placeholder.
    func signedImageURL(for stored: String) async -> URL? {
        let path = ReceiptStorage.storagePath(from: stored)
        guard !path.isEmpty else { return nil }
        if let cached = signedURLCache[path], cached.refreshAfter > Date() {
            return cached.url
        }
        if let task = signedURLTasks[path] {
            return await task.value
        }
        let task = Task<URL?, Never> {
            guard let accessToken = try? await self.authorizedAccessToken() else { return nil }
            do {
                let url = try await self.withFreshTokenIfNeeded(initialToken: accessToken) { token in
                    try await ReceiptStorage.shared.signedURL(path: path, expiresIn: 3600, accessToken: token)
                }
                await MainActor.run {
                    // Refresh a little before the 1-hour expiry so an in-flight load never 400s.
                    self.signedURLCache[path] = (url, Date().addingTimeInterval(50 * 60))
                }
                return url
            } catch {
                return nil
            }
        }
        signedURLTasks[path] = task
        let url = await task.value
        signedURLTasks[path] = nil
        return url
    }

    /// Returns a cover as a UIKit image for editing. Reuses the stable-path cache
    /// first, then refreshes from a signed URL when the image is not on this device.
    func editableTripCover(from stored: String) async -> UIImage? {
        let path = ReceiptStorage.storagePath(from: stored)
        guard !path.isEmpty else { return nil }
        if let cached = await ImageCache.shared.image(for: path) { return cached }
        guard let url = await signedImageURL(for: path) else { return nil }
        return await ImageCache.shared.download(from: url, for: path)
    }

    /// Clears expired signed URL entries and completed coalescing tasks when the account
    /// changes, so a new user never waits on or reuses another account's image signing.
    private func resetSignedImageURLs() {
        signedURLCache = [:]
        signedURLTasks.values.forEach { $0.cancel() }
        signedURLTasks = [:]
    }

    // Internal (not private): the trip-feed extension in FeedFeature.swift runs its
    // repository calls through the same token validation/refresh pipeline.
    func authorizedAccessToken(requireServerAccepted: Bool = false) async throws -> String? {
        // Reuse the stored token only while it's a real, non-expired user JWT. Sending an
        // expired/malformed one lets the request reach Postgres as the anonymous role,
        // where RLS rejects the write with a 403 (auth.uid() is null) — the failure mode
        // that produced silent "couldn't save to cloud" errors on device.
        if let accessToken, Self.isUsableUserToken(accessToken) {
            if !requireServerAccepted {
                return accessToken
            }
            if await AuthService.shared.isSessionAccepted(accessToken: accessToken) {
                return accessToken
            }
        }
        // No usable token: try to mint a fresh one from the refresh token.
        let hadToken = accessToken != nil
        let refreshed: String?
        do {
            refreshed = try await refreshAccessToken?()
        } catch {
            // Couldn't refresh. With no prior token this is just a signed-out, local-only
            // session (stay silent); with one, the session is genuinely broken (surface it).
            if hadToken {
                throw AuthError(message: "Your session expired. Please sign in again to sync.")
            }
            return nil
        }
        // Nil means there's no session to authenticate with — callers treat that as local-only.
        guard let refreshed else { return nil }
        await MainActor.run {
            self.accessToken = refreshed
            self.bindIdentity(accessToken: refreshed)
        }
        // A refresh that still doesn't yield a usable user token means the session is broken.
        guard Self.isUsableUserToken(refreshed) else {
            throw AuthError(message: "Your session expired. Please sign in again to sync.")
        }
        if requireServerAccepted {
            guard await AuthService.shared.isSessionAccepted(accessToken: refreshed) else {
                throw AuthError(message: "Your session isn't reaching the server. Please sign out and sign in again.")
            }
        }
        return refreshed
    }

    func withFreshTokenIfNeeded<T>(
        initialToken: String,
        operation: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(initialToken)
        } catch let error as AuthError where error.statusCode == 401 || error.statusCode == 403 {
            // 401 = the token was expired/rejected. A 403 with our RLS setup can mean the
            // write reached Postgres unauthenticated (auth.uid() null). Both are worth one
            // retry with a freshly minted token — but only when the refresh actually yields
            // a different one, so a genuine permission 403 (e.g. editing a trip you're not a
            // member of) isn't retried in vain.
            guard let refreshed = try await refreshAccessToken?(), refreshed != initialToken else { throw error }
            await MainActor.run {
                self.accessToken = refreshed
                self.bindIdentity(accessToken: refreshed)
            }
            return try await operation(refreshed)
        }
    }

    /// Ensures a local-only trip created under a pre-auth random UUID can be inserted under
    /// the signed-in account. Existing shared trips that already include the authenticated
    /// user keep their original creator/owner id.
    private func tripForCloudSave(_ trip: Trip, accessToken: String) -> Trip {
        guard let userID = Self.userID(fromJWT: accessToken),
              trip.creatorID != userID,
              !trip.members.contains(where: { $0.id == userID }) else {
            return trip
        }
        let reanchored = trip.reanchoringCreator(to: userID)
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = reanchored
        }
        return reanchored
    }

    // MARK: Settlements

    func settleKey(_ settlement: Settlement) -> String {
        "\(settlement.from.id.uuidString)->\(settlement.to.id.uuidString)"
    }

    func history(tripID: Trip.ID, for settlement: Settlement) -> [SettlementRecord] {
        trip(tripID)?.settlementRecords[settleKey(settlement)] ?? []
    }

    func setHistory(_ records: [SettlementRecord], tripID: Trip.ID, for settlement: Settlement) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].settlementRecords[settleKey(settlement)] = records
        persist(trips[index])
    }

    /// Remaining on a transfer = original amount minus confirmed settlement payments.
    func remaining(tripID: Trip.ID, for settlement: Settlement) -> Double {
        let confirmed = history(tripID: tripID, for: settlement)
            .filter { $0.status == .confirmed }
            .reduce(0) { $0 + $1.amount }
        return max(0, SplitEngine.roundToTwo(settlement.amount - confirmed))
    }

    func isFullySettled(tripID: Trip.ID, _ settlement: Settlement) -> Bool {
        remaining(tripID: tripID, for: settlement) <= 0.005
    }

    /// The creditor's one-tap "they paid me back": records the full remaining balance
    /// of a transfer as an already-confirmed payment, so the debt drops out of the
    /// Settle Up card and shows under the trip's History.
    func confirmSettled(tripID: Trip.ID, settlement: Settlement) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let rem = remaining(tripID: tripID, for: settlement)
        guard rem > 0.005 else { return }
        trips[index].settlementRecords[settleKey(settlement), default: []].insert(
            SettlementRecord(
                amount: rem, method: .cash,
                note: String(localized: "Marked as paid"),
                status: .confirmed, date: Date()
            ),
            at: 0
        )
        persist(trips[index])
    }

    // MARK: Comments

    func comments(for expenseID: Expense.ID, in tripID: Trip.ID) -> [ExpenseComment] {
        trip(tripID)?.comments[expenseID.uuidString] ?? []
    }

    func addComment(_ text: String, to expenseID: Expense.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        let comment = ExpenseComment(
            authorID: currentUser.id,
            authorName: currentUser.name,
            text: text
        )
        trips[index].comments[expenseID.uuidString, default: []].append(comment)
        persist(trips[index])
    }

    func deleteComment(_ commentID: ExpenseComment.ID, from expenseID: Expense.ID, in tripID: Trip.ID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].comments[expenseID.uuidString]?.removeAll { $0.id == commentID }
        persist(trips[index])
    }

    // MARK: Feed state

    /// Feed posts per trip, newest first. Posts live in their own `trip_feed_posts`
    /// table (see `FeedFeature.swift`), loaded on demand when the Feed tab opens and
    /// mutated optimistically by the feed methods in that file. State lives here (not
    /// in the extension) because extensions can't add storage to an @Observable class.
    var feedPostsByTrip: [Trip.ID: [FeedPost]] = [:]
}

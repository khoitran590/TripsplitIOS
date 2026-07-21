import SwiftUI
import PhotosUI
import UIKit

// MARK: - Profile model

/// The signed-in user's personal information, persisted in the `public.profiles`
/// table so it follows the account across devices and reinstalls. The display name
/// and avatar path are mirrored onto `TripStore.currentUser` (the `Person` that
/// lives inside every trip blob); this struct is the cloud-backed source of truth.
struct UserProfile: Codable, Equatable {
    var displayName: String = ""
    var dateOfBirth: Date?
    var bio: String = ""
    /// Storage *path* of the avatar in the private `receipts` bucket (same value as
    /// `Person.avatarURL`); resolve via `TripStore.signedImageURL(for:)` to display.
    var avatarPath: String?
    /// Places the user has been, shown as chips on their profile page.
    var visitedPlaces: [String] = []
    /// `MapPlace.saveKey`s bookmarked on the map screen.
    var savedPlaceKeys: [String] = []
    /// `Destination.id`s saved on the Explore screen.
    var savedDestinationIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case bio
        case avatarPath = "avatar_path"
        case visitedPlaces = "visited_places"
        case savedPlaceKeys = "saved_place_keys"
        case savedDestinationIDs = "saved_destination_ids"
    }

    /// Postgres `date` columns round-trip as plain "yyyy-MM-dd" strings.
    nonisolated static let dobFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .dateOfBirth) {
            dateOfBirth = Self.dobFormatter.date(from: raw)
        }
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        visitedPlaces = try c.decodeIfPresent([String].self, forKey: .visitedPlaces) ?? []
        savedPlaceKeys = try c.decodeIfPresent([String].self, forKey: .savedPlaceKeys) ?? []
        savedDestinationIDs = try c.decodeIfPresent([String].self, forKey: .savedDestinationIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(dateOfBirth.map(Self.dobFormatter.string(from:)), forKey: .dateOfBirth)
        try c.encode(bio, forKey: .bio)
        try c.encode(avatarPath, forKey: .avatarPath)
        try c.encode(visitedPlaces, forKey: .visitedPlaces)
        try c.encode(savedPlaceKeys, forKey: .savedPlaceKeys)
        try c.encode(savedDestinationIDs, forKey: .savedDestinationIDs)
    }
}

// MARK: - Profiles repository (Supabase REST)

/// Reads/writes the signed-in user's row in `public.profiles`. The row is created
/// server-side by the `auth_users_create_profile` trigger, so the client only ever
/// SELECTs and PATCHes it (RLS restricts both to the user's own row).
actor ProfilesRepository {
    static let shared = ProfilesRepository()
    private let session = BackendSecurity.secureSession

    private static let columns = "display_name,date_of_birth,bio,avatar_path,visited_places,saved_place_keys,saved_destination_ids"

    func fetch(userID: UUID, accessToken: String) async throws -> UserProfile? {
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())&select=\(Self.columns)"
        let data = try await send("GET", path, accessToken: accessToken)
        return try JSONDecoder().decode([UserProfile].self, from: data).first
    }

    func update(_ profile: UserProfile, userID: UUID, accessToken: String) async throws {
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())"
        let body = try JSONEncoder().encode(profile)
        _ = try await send("PATCH", path, accessToken: accessToken, body: body,
                           extraHeaders: ["Prefer": "return=minimal"])
    }

    /// The user's own profile share token, used to build their shareable profile link.
    /// `share_token` is intentionally kept out of `UserProfile` so the client never
    /// PATCHes it; it's read on its own here.
    func fetchShareToken(userID: UUID, accessToken: String) async throws -> String? {
        struct Row: Decodable { let share_token: String? }
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())&select=share_token"
        let data = try await send("GET", path, accessToken: accessToken)
        return try JSONDecoder().decode([Row].self, from: data).first?.share_token
    }

    private func send(
        _ method: String,
        _ path: String,
        accessToken: String,
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard SupabaseConfig.isConfigured, let url = URL(string: SupabaseConfig.url + path) else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BackendSecurity.log("Profile sync network failure", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Profile request rejected", statusCode: http.statusCode)
            throw AuthError(message: "Profile request failed (HTTP \(http.statusCode)).", statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - Profile tab

/// Root of the Profile dock tab: hosts the profile page in its own navigation
/// stack, or a sign-in prompt while signed out (mirroring the Explore tab lock).
struct ProfileScreen: View {
    @Environment(AuthStore.self) private var auth
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            if auth.isAuthenticated {
                ProfileDetailView()
            } else {
                ZStack {
                    AppBackground()
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.app(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Your profile lives here")
                            .font(.app(.title3, .semibold))
                        Text("Sign in to set up your photo, bio, and the places you've been.")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            showSignIn = true
                        } label: {
                            Text("Sign In")
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                    }
                    .padding(.horizontal, 32)
                }
                .sheet(isPresented: $showSignIn) {
                    SettingsScreen()
                }
            }
        }
    }
}

/// A place the user has been, with an optional date drawn from a matching trip.
/// Used to render the "Where I've been" passport-style cards.
struct VisitedPlace: Identifiable {
    let name: String
    let date: Date?
    var id: String { name.lowercased() }
}

// MARK: - Profile page ("Show profile")

/// The user's public-facing profile card: photo, name, bio, birthday, and the
/// places they've been (their own list merged with locations from their trips).
struct ProfileDetailView: View {
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(FriendsStore.self) private var friends

    @State private var showEditor = false
    @State private var selectedTrip: Trip?
    /// A friend's profile opened from the Friends rail.
    @State private var viewingProfile: SharedProfileLink?

    /// The user's own list first, then any trip locations not already in it.
    /// A trip's start (or end) date is attached so the cards can show when they went.
    private var visitedPlaces: [VisitedPlace] {
        var places = store.userProfile.visitedPlaces.map { VisitedPlace(name: $0, date: nil) }
        for trip in store.trips {
            guard let location = trip.location?.trimmingCharacters(in: .whitespaces),
                  !location.isEmpty else { continue }
            let tripDate = trip.startDate ?? trip.endDate
            if let index = places.firstIndex(where: { $0.name.caseInsensitiveCompare(location) == .orderedSame }) {
                // Fill in a date for a place the user typed manually, if the trip has one.
                if places[index].date == nil, let tripDate {
                    places[index] = VisitedPlace(name: places[index].name, date: tripDate)
                }
            } else {
                places.append(VisitedPlace(name: location, date: tripDate))
            }
        }
        return places
    }

    /// Trips the signed-in user created, newest first — the profile's "My trips" rail.
    private var myTrips: [Trip] {
        store.trips
            .filter { $0.creatorID == store.currentUser.id }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if !store.userProfile.bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(store.userProfile.bio)
                        .font(.app(.body))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }

                detailsCard

                FriendsSection { token in
                    viewingProfile = SharedProfileLink(token: token)
                }

                placesSection

                tripsSection
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .background {
            LinearGradient(
                colors: [Color(.systemIndigo).opacity(0.25), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let url = friends.shareURL() {
                    ShareLink(item: url, subject: Text(verbatim: store.currentUser.name),
                              message: Text("Add me on TripSplit")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .task { await friends.refresh() }
        .sheet(isPresented: $showEditor) {
            EditProfileView()
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $viewingProfile) { link in
            NavigationStack {
                SharedProfileView(token: link.token)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 110)
            Text(store.currentUser.name.isEmpty ? "TripSplit User" : store.currentUser.name)
                .font(.app(.title, .bold))
            if let email = auth.email {
                Text(email)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            if let dob = store.userProfile.dateOfBirth {
                detailRow(icon: "birthday.cake.fill", color: Color(hex: 0xEC4899), title: "Birthday",
                          value: dob.formatted(date: .long, time: .omitted))
            }
            detailRow(icon: "suitcase.fill", color: Theme.accent, title: "Trips",
                      value: "\(store.trips.count)")
            detailRow(icon: "mappin.and.ellipse", color: Theme.positive, title: "Places visited",
                      value: "\(visitedPlaces.count)", showsDivider: false)
        }
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func detailRow(icon: String, color: Color, title: LocalizedStringKey, value: String, showsDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SettingsIconBadge(icon: icon, color: color)
                Text(title)
                    .font(.app(.body))
                Spacer()
                Text(value)
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            if showsDivider { Divider() }
        }
    }

    @ViewBuilder
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where I've been")
                .font(.app(.title3, .bold))

            if visitedPlaces.isEmpty {
                Text("Add places you've visited from Edit, or set a location on your trips.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                // Full-bleed horizontal rail of passport-style cards (negative padding
                // cancels the parent's inset so the row runs edge to edge like a gallery).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(visitedPlaces) { VisitedPlaceCard(place: $0) }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tripsSection: some View {
        if !myTrips.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("My trips")
                    .font(.app(.title3, .bold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(myTrips) { trip in
                            Button { selectedTrip = trip } label: {
                                ProfileTripCard(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A passport-stamp style card for a visited place: a location glyph on a tinted
/// panel, with the place name and (when known) the month/year shown beneath it.
/// Modeled on the reference "Where … has been" cards, styled to the app theme.
struct VisitedPlaceCard: View {
    let place: VisitedPlace

    /// Deterministic accent per place so the rail reads as a varied set of stamps
    /// rather than one repeated color.
    private static let tints: [UInt32] = [0x6366F1, 0x0EA5E9, 0x10B981, 0xF59E0B, 0xEC4899, 0x14B8A6]
    private var tint: Color {
        Color(hex: Self.tints[abs(place.id.hashValue) % Self.tints.count])
    }

    private var monthYear: String? {
        place.date?.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(tint.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                    }
                Image(systemName: "airplane")
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(14)
                Image(systemName: "globe.americas.fill")
                    .font(.app(size: 46, weight: .regular))
                    .foregroundStyle(tint.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 150, height: 132)

            Text(place.name)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)
            Text(verbatim: monthYear ?? " ")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }
}

/// A compact trip card for the profile's "My trips" rail: cover image with the
/// trip name, location, and dates beneath. Tapping opens the trip detail sheet.
struct ProfileTripCard: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TripCoverView(trip: trip)
                .frame(width: 220, height: 148)
                .clipShape(.rect(cornerRadius: 18))

            Text(trip.name)
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let location = trip.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty {
                Label {
                    Text(verbatim: location)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if let dates = trip.dateRangeText {
                Text(verbatim: dates)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 220, alignment: .leading)
    }
}

/// A minimal left-aligned wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (subview, position) in zip(subviews, result.positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }
        return (CGSize(width: totalWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Edit profile sheet

/// Editor for everything on the profile: photo, name, date of birth, bio, and the
/// visited-places list. Saving persists locally and to the `profiles` table.
struct EditProfileView: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hasDateOfBirth = false
    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now
    @State private var bio = ""
    @State private var places: [String] = []
    @State private var newPlace = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    /// True once the user taps "Remove Photo" — the only action that deletes the cloud
    /// avatar. `imageData == nil` alone just means no local copy (e.g. after reinstall).
    @State private var photoRemoved = false
    @State private var isSaving = false

    /// Whether the account has an avatar this sheet can show/remove: a locally picked
    /// photo, or the cloud avatar (still present after reinstalls).
    private var hasPhoto: Bool {
        imageData != nil || (!photoRemoved && store.currentUser.avatarURL != nil)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection

                Section("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                }

                Section("Date of birth") {
                    Toggle("Show date of birth", isOn: $hasDateOfBirth.animation())
                    if hasDateOfBirth {
                        DatePicker("Birthday", selection: $dateOfBirth,
                                   in: ...Date.now, displayedComponents: .date)
                    }
                }

                Section {
                    TextField("Tell your travel buddies about yourself…", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("About you")
                }

                placesSection
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
                    imageData = Self.downsized(data) ?? data
                    photoRemoved = false
                }
            }
        }
    }

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    if imageData == nil && hasPhoto {
                        // No local copy (fresh install) but the cloud avatar exists.
                        AvatarView(person: store.currentUser, size: 96)
                    } else {
                        ProfileAvatar(imageData: imageData, initials: initials, size: 96)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(hasPhoto ? "Change Photo" : "Add Photo")
                    }
                    if hasPhoto {
                        Button("Remove Photo", role: .destructive) {
                            imageData = nil
                            photoItem = nil
                            photoRemoved = true
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private var placesSection: some View {
        Section {
            ForEach(places, id: \.self) { place in
                Label(place, systemImage: "mappin")
            }
            .onDelete { places.remove(atOffsets: $0) }

            HStack {
                TextField("Add a place (e.g. Tokyo, Japan)", text: $newPlace)
                    .onSubmit(addPlace)
                Button(action: addPlace) {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newPlace.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Where I've been")
        } footer: {
            Text("Locations from your trips are added to your profile automatically.")
        }
    }

    private func addPlace() {
        let place = newPlace.trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty,
              !places.contains(where: { $0.caseInsensitiveCompare(place) == .orderedSame }) else { return }
        places.append(place)
        newPlace = ""
    }

    private func load() {
        name = store.currentUser.name
        imageData = store.profileImageData
        bio = store.userProfile.bio
        places = store.userProfile.visitedPlaces
        if let dob = store.userProfile.dateOfBirth {
            hasDateOfBirth = true
            dateOfBirth = dob
        }
    }

    private func save() {
        var profile = store.userProfile
        profile.displayName = name.trimmingCharacters(in: .whitespaces)
        profile.dateOfBirth = hasDateOfBirth ? dateOfBirth : nil
        profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.visitedPlaces = places
        isSaving = true
        Task {
            await store.saveProfile(profile, imageData: imageData, removePhoto: photoRemoved)
            isSaving = false
            dismiss()
        }
    }

    /// Re-encodes a picked photo down to a modest size so it stays small in storage.
    static func downsized(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 512
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // scale = 1 so `newSize` IS the pixel size — the renderer default (screen scale,
        // 3x on device) would triple the dimensions and defeat the downsizing.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

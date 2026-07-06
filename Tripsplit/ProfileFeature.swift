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

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case bio
        case avatarPath = "avatar_path"
        case visitedPlaces = "visited_places"
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(dateOfBirth.map(Self.dobFormatter.string(from:)), forKey: .dateOfBirth)
        try c.encode(bio, forKey: .bio)
        try c.encode(avatarPath, forKey: .avatarPath)
        try c.encode(visitedPlaces, forKey: .visitedPlaces)
    }
}

// MARK: - Profiles repository (Supabase REST)

/// Reads/writes the signed-in user's row in `public.profiles`. The row is created
/// server-side by the `auth_users_create_profile` trigger, so the client only ever
/// SELECTs and PATCHes it (RLS restricts both to the user's own row).
actor ProfilesRepository {
    static let shared = ProfilesRepository()
    private let session = BackendSecurity.secureSession

    private static let columns = "display_name,date_of_birth,bio,avatar_path,visited_places"

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

// MARK: - Profile page ("Show profile")

/// The user's public-facing profile card: photo, name, bio, birthday, and the
/// places they've been (their own list merged with locations from their trips).
struct ProfileDetailView: View {
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth

    @State private var showEditor = false

    /// The user's own list first, then any trip locations not already in it.
    private var visitedPlaces: [String] {
        var places = store.userProfile.visitedPlaces
        for trip in store.trips {
            guard let location = trip.location?.trimmingCharacters(in: .whitespaces),
                  !location.isEmpty,
                  !places.contains(where: { $0.caseInsensitiveCompare(location) == .orderedSame })
            else { continue }
            places.append(location)
        }
        return places
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if !store.userProfile.bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(store.userProfile.bio)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }

                detailsCard

                placesSection
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            EditProfileView()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 110)
            Text(store.currentUser.name.isEmpty ? "TripSplit User" : store.currentUser.name)
                .font(.title.bold())
            if let email = auth.email {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            if let dob = store.userProfile.dateOfBirth {
                detailRow(icon: "birthday.cake", title: "Birthday",
                          value: dob.formatted(date: .long, time: .omitted))
            }
            detailRow(icon: "suitcase", title: "Trips", value: "\(store.trips.count)")
            detailRow(icon: "mappin.and.ellipse", title: "Places visited",
                      value: "\(visitedPlaces.count)", showsDivider: false)
        }
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func detailRow(icon: String, title: LocalizedStringKey, value: String, showsDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                Text(title)
                    .font(.body)
                Spacer()
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            if showsDivider { Divider() }
        }
    }

    @ViewBuilder
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where I've been")
                .font(.title3.bold())

            if visitedPlaces.isEmpty {
                Text("Add places you've visited from Edit, or set a location on your trips.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                PlaceChips(places: visitedPlaces)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Wrapping rows of place-name chips.
struct PlaceChips: View {
    let places: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(places, id: \.self) { place in
                Label(place, systemImage: "mappin")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.secondary.opacity(0.12), in: .capsule)
            }
        }
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
    @State private var isSaving = false

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
                }
            }
        }
    }

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    ProfileAvatar(imageData: imageData, initials: initials, size: 96)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(imageData == nil ? "Add Photo" : "Change Photo")
                    }
                    if imageData != nil {
                        Button("Remove Photo", role: .destructive) {
                            imageData = nil
                            photoItem = nil
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
            await store.saveProfile(profile, imageData: imageData)
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

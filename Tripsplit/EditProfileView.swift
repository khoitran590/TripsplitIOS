import SwiftUI
import PhotosUI
import UIKit
import MapKit

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
    @State private var visibility = ProfileVisibility()
    @State private var newPlace = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    /// True once the user taps "Remove Photo" — the only action that deletes the cloud
    /// avatar. `imageData == nil` alone just means no local copy (e.g. after reinstall).
    @State private var photoRemoved = false
    @State private var isSaving = false
    /// Set when the cloud write failed: the sheet stays open so the edits aren't lost.
    @State private var showSaveFailed = false
    @State private var showDiscardConfirmation = false
    /// Apple Maps autocomplete for the "Where I've been" field.
    @StateObject private var placeCompleter = PlaceSearchCompleter()
    @State private var isResolvingPlace = false

    /// What `load()` put on screen, so Cancel can tell edits from an untouched sheet.
    @State private var loadedSnapshot: [String] = []

    /// Longest bio the profile card and every friend's copy of it are laid out for.
    private static let bioLimit = 160

    /// The editable fields flattened for comparison against `loadedSnapshot`.
    private var snapshot: [String] {
        [name, bio, hasDateOfBirth ? UserProfile.dobFormatter.string(from: dateOfBirth) : ""] + places
    }

    private var hasChanges: Bool {
        snapshot != loadedSnapshot || photoRemoved || imageData != store.profileImageData
            || visibility != store.userProfile.visibility
    }

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
            ZStack {
                LinearGradient(colors: Theme.sheetGradient, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        photoCard
                        detailsCard
                        bioCard
                        placesCard
                        visibilityCard
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { showDiscardConfirmation = true } else { dismiss() }
                    }
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
            .alert("Couldn't save your profile", isPresented: $showSaveFailed) {
                Button("Try Again") { save() }
                Button("Close", role: .cancel) { dismiss() }
            } message: {
                Text("Your changes are saved on this device but couldn't be uploaded. Check your connection and try again.")
            }
            .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirmation,
                                titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
    }

    private var photoCard: some View {
        TripCard(title: "Photo", icon: "person.crop.circle.fill") {
            HStack {
                Spacer()
                if imageData == nil && hasPhoto {
                    // No local copy (fresh install) but the cloud avatar exists.
                    AvatarView(person: store.currentUser, size: 96)
                } else {
                    ProfileAvatar(imageData: imageData, initials: initials, size: 96)
                }
                Spacer()
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(hasPhoto ? "Change Photo" : "Add Photo", systemImage: "photo.on.rectangle.angled")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .actionFill(tint: Theme.accent)

            if hasPhoto {
                Button {
                    imageData = nil
                    photoItem = nil
                    photoRemoved = true
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.negative)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .controlSurface(in: .capsule)
            }
        }
    }

    private var detailsCard: some View {
        TripCard(title: "About you", icon: "person.text.rectangle.fill") {
            TextField("Your name", text: $name)
                .textContentType(.name)
                .font(.app(.title3, .semibold))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            Toggle("Show date of birth", isOn: $hasDateOfBirth.animation())
                .font(.app(.body))
                .tint(Theme.accent)

            if hasDateOfBirth {
                DatePicker("Birthday", selection: $dateOfBirth,
                           in: ...Date.now, displayedComponents: .date)
                    .font(.app(.body))
            }
        }
    }

    private var bioCard: some View {
        TripCard(title: "Bio", icon: "text.quote") {
            TextField("Tell your travel buddies about yourself…", text: $bio, axis: .vertical)
                .font(.app(.body))
                .lineLimit(3...6)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                // The bio renders in a fixed-height card on the profile and on every
                // friend's copy of it, so it is capped rather than left to grow.
                .onChange(of: bio) { _, value in
                    if value.count > Self.bioLimit { bio = String(value.prefix(Self.bioLimit)) }
                }

            Text(verbatim: "\(bio.count)/\(Self.bioLimit)")
                .font(.app(.caption))
                .foregroundStyle(bio.count >= Self.bioLimit ? Theme.warning : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .monospacedDigit()
        }
    }

    /// Per-section privacy. Sharing a profile link used to hand over the birthday, bio,
    /// places and trip list with no way to withhold any of them; `profile_by_token`
    /// enforces these server-side, so a hidden section never leaves the database.
    private var visibilityCard: some View {
        TripCard(title: "Shown on your shared profile", icon: "eye.fill") {
            Toggle("Bio", isOn: $visibility.bio)
            Toggle("Birthday", isOn: $visibility.birthday)
            Toggle("Where I've been", isOn: $visibility.places)
            Toggle("Trips", isOn: $visibility.trips)

            Text("You always see everything on your own profile. These control what other people see when they open your link.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .font(.app(.body))
        .tint(Theme.accent)
    }

    /// Trip locations that already appear on the profile but aren't in the user's own
    /// list, so the editor can show them as read-only rather than omitting them.
    private var tripDerivedPlaces: [String] {
        var seen = Set(places.map { $0.lowercased() })
        var derived: [String] = []
        for trip in store.trips {
            guard let location = trip.location?.trimmingCharacters(in: .whitespaces),
                  !location.isEmpty, seen.insert(location.lowercased()).inserted else { continue }
            derived.append(location)
        }
        return derived
    }

    private var placesCard: some View {
        TripCard(title: "Where I've been", icon: "mappin.and.ellipse") {
            ForEach(places, id: \.self) { place in
                HStack(spacing: 10) {
                    Image(systemName: "mappin")
                        .foregroundStyle(Theme.accent)
                    Text(verbatim: place)
                        .font(.app(.body))
                    Spacer(minLength: 0)
                    Button {
                        places.removeAll { $0 == place }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.app(.body))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove")
                }
            }

            HStack(spacing: 10) {
                TextField("Search a place (e.g. Tokyo)", text: $newPlace)
                    .autocorrectionDisabled()
                    .onSubmit(addPlace)
                if isResolvingPlace {
                    ProgressView()
                } else {
                    Button(action: addPlace) {
                        Image(systemName: "plus.circle.fill")
                            .font(.app(.title3))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(newPlace.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
            .onChange(of: newPlace) { _, value in
                placeCompleter.update(query: value)
            }

            ForEach(Array(placeCompleter.suggestions.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                Button {
                    Task { await select(suggestion) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: suggestion.title)
                                .font(.app(.subheadline))
                                .foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(verbatim: suggestion.subtitle)
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            // Places the profile shows because a trip has that location. They were
            // invisible here before, so a stamp the user couldn't find in this list
            // looked like a bug; they're listed as read-only with the reason why.
            if !tripDerivedPlaces.isEmpty {
                Divider()
                Text("From your trips")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(tripDerivedPlaces, id: \.self) { place in
                    HStack(spacing: 10) {
                        Image(systemName: "suitcase.fill")
                            .foregroundStyle(.tertiary)
                        Text(verbatim: place)
                            .font(.app(.body))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                Text("These come from your trips' locations. Change a trip's location to change its place here.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Turns a tapped suggestion into a "Place, Region" name. Resolving the completion
    /// gives the placemark, so the region is the state for home-country places and the
    /// country for foreign ones ("Yucca Valley, California" / "Osaka, Japan") — which is
    /// also what `PlaceTheme` reads to pick the right language for its keywords.
    private func select(_ suggestion: MKLocalSearchCompletion) async {
        isResolvingPlace = true
        defer { isResolvingPlace = false }

        var name = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        let request = MKLocalSearch.Request(completion: suggestion)
        if let context = try? await MKLocalSearch(request: request).start()
            .mapItems.first?.addressRepresentations?.cityWithContext {
            // `cityWithContext` can carry a postal code ("Twentynine Palms, CA 92277"),
            // so the region is rebuilt from its letter-only words.
            let region = PlaceRegion.regionWords(in: context).joined(separator: " ")
            let city = context.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            // A landmark ("Joshua Tree National Park") keeps its own name; only the region
            // is taken from the city context.
            let place = context.localizedCaseInsensitiveContains(suggestion.title) ? (city ?? suggestion.title) : suggestion.title
            name = region.isEmpty ? place : "\(place), \(region)"
        }

        newPlace = name
        placeCompleter.clear()
        addPlace()
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
        visibility = store.userProfile.visibility
        if let dob = store.userProfile.dateOfBirth {
            hasDateOfBirth = true
            dateOfBirth = dob
        }
        loadedSnapshot = snapshot
    }

    private func save() {
        var profile = store.userProfile
        profile.displayName = name.trimmingCharacters(in: .whitespaces)
        profile.dateOfBirth = hasDateOfBirth ? dateOfBirth : nil
        profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.visitedPlaces = places
        profile.visibility = visibility
        isSaving = true
        Task {
            let saved = await store.saveProfile(profile, imageData: imageData, removePhoto: photoRemoved)
            isSaving = false
            // A failed upload used to dismiss exactly like a successful one.
            if saved { dismiss() } else { showSaveFailed = true }
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

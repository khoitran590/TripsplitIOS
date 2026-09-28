import SwiftUI
import MapKit

// MARK: - Shared profile sections
//
// One set of views renders a profile both on its owner's Profile tab and on a friend's
// device (`SharedProfileView`), so "Viewing as Friends" shows the real layout rather
// than a look-alike.

/// The passport cover as the profile's banner — the same six covers as the share card.
struct ProfileCoverBanner: View {
    let cover: ShareCardCover
    var height: CGFloat = 140

    var body: some View {
        LinearGradient(colors: cover.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Passport")
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(3.5)
                    Text(verbatim: cover.code)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(2.5)
                        .opacity(0.75)
                }
                .foregroundStyle(cover.foil)
                .padding(18)
            }
            .overlay(alignment: .trailing) {
                Image(systemName: "globe")
                    .font(.system(size: height * 0.55, weight: .ultraLight))
                    .foregroundStyle(cover.foil.opacity(0.85))
                    .padding(.trailing, 26)
            }
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .accessibilityHidden(true)
    }
}

/// Cover, overlapping avatar, name, home base / languages / birthday, bio and travel
/// styles.
struct ProfileHeader: View {
    let person: Person
    var imageData: Data? = nil
    let name: String
    let showcase: ProfileShowcase
    let bio: String
    var birthday: MonthDay? = nil
    /// Makes the avatar a button (with a camera badge) on the owner's own profile.
    var onEditPhoto: (() -> Void)? = nil

    private let avatarSize: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProfileCoverBanner(cover: showcase.passportCover)
                .overlay(alignment: .bottomLeading) {
                    avatar
                        .padding(4)
                        .background(Theme.surfaceSubtle, in: .circle)
                        .offset(x: 16, y: avatarSize / 2)
                }
                .padding(.bottom, avatarSize / 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: name)
                    .font(.app(size: 26, weight: .bold))
                    .foregroundStyle(Theme.ink)

                let homeBase = showcase.homeBase.trimmingCharacters(in: .whitespaces)
                let languages = showcase.languages.trimmingCharacters(in: .whitespaces)
                if !homeBase.isEmpty || !languages.isEmpty || birthday != nil {
                    FlowLayout(spacing: 12) {
                        if !homeBase.isEmpty { metaItem(homeBase, icon: "house.fill") }
                        if !languages.isEmpty { metaItem(languages, icon: "character.bubble.fill") }
                        if let birthday { metaItem(birthday.formatted, icon: "birthday.cake.fill") }
                    }
                }

                if !bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: bio)
                        .font(.app(.subheadline))
                        .foregroundStyle(Theme.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                let styles = showcase.knownStyles
                if !styles.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(styles) { style in
                            Text(style.label)
                                .font(.app(.footnote, .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 30)
                                .background(Theme.accent.opacity(0.12), in: .capsule)
                        }
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Travel style")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var avatar: some View {
        if let onEditPhoto {
            Button(action: onEditPhoto) {
                AvatarView(person: person, imageData: imageData, size: avatarSize)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface, in: .circle)
                            .overlay(Circle().stroke(Theme.separator, lineWidth: 0.5))
                            .shadow(color: Theme.elevatedShadow, radius: 4, y: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile photo")
            .accessibilityHint("Opens profile editing")
        } else {
            AvatarView(person: person, imageData: imageData, size: avatarSize)
                .accessibilityHidden(true)
        }
    }

    private func metaItem(_ text: String, icon: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: icon).font(.app(.caption))
        }
        .font(.app(.subheadline))
        .foregroundStyle(Theme.textSecondary)
    }
}

/// Answered prompts, one card each, the answer set in serif so it reads as the person's
/// own voice rather than app chrome.
struct TravelNotesSection: View {
    let notes: [(prompt: TravelPrompt, answer: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Travel notes")
                .font(.app(.title3, .bold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(notes, id: \.prompt) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.prompt.label)
                        .font(.app(.caption, .bold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: note.answer)
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelPadding(horizontal: 18, vertical: 16)
                .homePanel(cornerRadius: Theme.cardRadius)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Where I've been": the passport stamps (unchanged `VisitedPlaceCard`s) or the same
/// places on a map, plus the favorite place and its one-line memory.
struct PlacesShowcaseSection<Trailing: View>: View {
    let title: LocalizedStringKey
    let places: [VisitedPlace]
    var favorite: String? = nil
    var memory: String = ""
    /// `PlaceKey`s the viewer has been to as well, marked "You too" on a friend's page.
    var sharedKeys: Set<String> = []
    @ViewBuilder var trailing: () -> Trailing

    private enum Mode: Hashable { case stamps, map }
    @State private var mode: Mode = .stamps
    @State private var geocoder = VisitedPlaceGeocoder.shared

    /// The favorite first, so the rail opens on it.
    private var ordered: [VisitedPlace] {
        guard let favoriteID = favoriteID,
              let index = places.firstIndex(where: { $0.id == favoriteID }) else { return places }
        var ordered = places
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    private var favoriteID: String? {
        guard let favorite, places.contains(where: { $0.id == favorite.lowercased() }) else { return nil }
        return favorite.lowercased()
    }

    private var pins: [MappedPlace] {
        places.compactMap { place in
            geocoder.coordinate(for: place.name).map {
                MappedPlace(name: place.name, latitude: $0.latitude, longitude: $0.longitude)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.app(.title3, .bold))
                    .foregroundStyle(Theme.ink)
                if !places.isEmpty {
                    Text(verbatim: "\(places.count)")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                trailing()
            }
            .accessibilityAddTraits(.isHeader)

            if !places.isEmpty {
                Picker("Show places as", selection: $mode) {
                    Text("Stamps").tag(Mode.stamps)
                    Text("Map").tag(Mode.map)
                }
                .pickerStyle(.segmented)

                switch mode {
                case .stamps:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ordered) { place in
                                VisitedPlaceCard(place: place)
                                    .overlay(alignment: .topTrailing) {
                                        if place.id == favoriteID { favoriteBadge }
                                    }
                                    .overlay(alignment: .topLeading) {
                                        if sharedKeys.contains(PlaceKey.of(place.name)) { youTooPill }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                case .map:
                    map
                }

                if let favoriteID, let place = places.first(where: { $0.id == favoriteID }) {
                    favoriteCard(place)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: places.map(\.name)) { await geocoder.resolve(places.map(\.name)) }
    }

    private var youTooPill: some View {
        Text("You too")
            .font(.app(.caption2, .bold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(Theme.accent, in: .capsule)
    }

    private var favoriteBadge: some View {
        Image(systemName: "heart.fill")
            .font(.app(.caption, .bold))
            .foregroundStyle(Theme.negative)
            .frame(width: 28, height: 28)
            .background(Theme.surface, in: .circle)
            .shadow(color: Theme.elevatedShadow, radius: 3, y: 1)
            .accessibilityLabel("Favorite")
    }

    private func favoriteCard(_ place: VisitedPlace) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.app(.subheadline))
                .foregroundStyle(Theme.negative)
                .frame(width: 36, height: 36)
                .background(Theme.negative.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text("Favorite · \(place.shortName)")
                    .font(.app(.caption, .bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
                let memory = memory.trimmingCharacters(in: .whitespaces)
                if !memory.isEmpty {
                    Text(verbatim: memory)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .panelPadding(horizontal: 16, vertical: 14)
        .homePanel(cornerRadius: Theme.cardRadius)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var map: some View {
        let pins = pins
        if pins.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
                .homePanel(cornerRadius: 24)
        } else {
            Map(initialPosition: .region(Self.region(for: pins)), interactionModes: [.pan, .zoom]) {
                ForEach(pins) { place in
                    Marker(place.name, systemImage: "mappin", coordinate: place.coordinate)
                        .tint(Theme.accent)
                }
            }
            // A new identity per pin set so the camera re-fits as places resolve.
            .id(pins.map(\.id))
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: 24))
            .shadow(color: Theme.elevatedShadow, radius: 8, y: 4)
            .accessibilityLabel("Map of the places they've been")
        }
    }

    /// A region containing every pin, with padding so markers aren't clipped at the rim.
    static func region(for places: [MappedPlace]) -> MKCoordinateRegion {
        let latitudes = places.map(\.latitude)
        let longitudes = places.map(\.longitude)
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else {
            return MKCoordinateRegion(center: .init(latitude: 20, longitude: 0),
                                      span: .init(latitudeDelta: 120, longitudeDelta: 120))
        }
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                            longitude: (minLongitude + maxLongitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLatitude - minLatitude) * 1.5, 4),
                                    longitudeDelta: max((maxLongitude - minLongitude) * 1.5, 4))
        return MKCoordinateRegion(center: center, span: span)
    }
}

extension PlacesShowcaseSection where Trailing == EmptyView {
    init(title: LocalizedStringKey, places: [VisitedPlace], favorite: String? = nil, memory: String = "",
         sharedKeys: Set<String> = []) {
        self.init(title: title, places: places, favorite: favorite, memory: memory,
                  sharedKeys: sharedKeys) { EmptyView() }
    }
}

/// Places someone wants to go, as chips. On a friend's page, ones the viewer wants too
/// are filled.
struct BucketListSection<Trailing: View>: View {
    let places: [String]
    var sharedKeys: Set<String> = []
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Bucket list")
                    .font(.app(.title3, .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                trailing()
            }
            .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8) {
                ForEach(places, id: \.self) { place in
                    let shared = sharedKeys.contains(PlaceKey.of(place))
                    Label {
                        Text(verbatim: PlaceKey.displayName(of: place))
                    } icon: {
                        Image(systemName: shared ? "checkmark" : "bookmark.fill")
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(shared ? Theme.onAccent : Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(shared ? Theme.accent : Theme.fieldBackground, in: .capsule)
                    .accessibilityValue(shared ? Text("You want to go too") : Text(""))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension BucketListSection where Trailing == EmptyView {
    init(places: [String], sharedKeys: Set<String> = []) {
        self.init(places: places, sharedKeys: sharedKeys) { EmptyView() }
    }
}

/// Trip-feed photos the owner picked, in a three-column grid.
struct MomentsSection<Trailing: View>: View {
    let moments: [ProfileMoment]
    @ViewBuilder var trailing: () -> Trailing

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Moments")
                    .font(.app(.title3, .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                trailing()
            }
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(moments, id: \.path) { moment in
                    MomentTile(moment: moment)
                }
            }
            .clipShape(.rect(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MomentsSection where Trailing == EmptyView {
    init(moments: [ProfileMoment]) {
        self.init(moments: moments) { EmptyView() }
    }
}

/// One square photo with its caption.
struct MomentTile: View {
    let moment: ProfileMoment

    var body: some View {
        Theme.fieldBackground
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CachedStorageImage(path: moment.path) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .loading:
                        ProgressView()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !moment.caption.isEmpty {
                    Text(verbatim: moment.caption)
                        .font(.app(.caption2, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: .capsule)
                        .padding(6)
                }
            }
            .clipped()
            // `scaledToFill` overflow still hit-tests past `.clipped()`.
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(moment.caption.isEmpty ? Text("Photo") : Text(verbatim: moment.caption))
    }
}

/// What the viewer and a friend have in common, from what each already shares.
struct MutualContextCard: View {
    let friendName: String
    let context: MutualContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You and \(friendName)")
                .font(.app(.headline))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if !context.sharedPlaces.isEmpty {
                row(icon: "mappin.and.ellipse",
                    text: Text("You've both been to \(ListFormatter.localizedString(byJoining: context.sharedPlaces))"))
            }
            if !context.tripsTogether.isEmpty {
                row(icon: "suitcase.fill",
                    text: Text("^[\(context.tripsTogether.count) trip](inflect: true) together · \(ListFormatter.localizedString(byJoining: Array(context.tripsTogether.prefix(2))))"))
            }
            if !context.sharedBucket.isEmpty {
                row(icon: "bookmark.fill",
                    text: Text("You both want to go to \(ListFormatter.localizedString(byJoining: context.sharedBucket))"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelPadding(horizontal: 16, vertical: 16)
        .homePanel(cornerRadius: Theme.cardRadius)
        .accessibilityElement(children: .combine)
    }

    private func row(icon: String, text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.app(.footnote, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.12), in: .circle)
            text
                .font(.app(.subheadline))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

/// Badges as medals. On the owner's profile every earned badge shows, pins can be
/// toggled, and the closest unearned badge shows its progress; friends see what the
/// owner pinned (or, with no pins, what the shared counts earn).
struct BadgesSection: View {
    let badges: [ProfileBadge]
    var pinned: [ProfileBadge] = []
    var next: (badge: ProfileBadge, current: Int, target: Int)? = nil
    /// Set on the owner's profile only.
    var onTogglePin: ((ProfileBadge) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Badges")
                    .font(.app(.title3, .bold))
                    .foregroundStyle(Theme.ink)
                if !badges.isEmpty {
                    Text(verbatim: "\(badges.count)")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                if !badges.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(badges) { badge in
                            if let onTogglePin {
                                Button { onTogglePin(badge) } label: { medal(badge) }
                                    .buttonStyle(.plain)
                                    .disabled(!pinned.contains(badge) && pinned.count >= ProfileBadge.pinLimit)
                                    .accessibilityHint(pinned.contains(badge)
                                                       ? Text("Unpins it from your shared profile")
                                                       : Text("Pins it to your shared profile"))
                            } else {
                                medal(badge)
                            }
                        }
                    }
                    if onTogglePin != nil {
                        Text("Tap up to 3 badges to pin them for friends. With none pinned, friends see the ones they can count.")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                if let next {
                    if !badges.isEmpty { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Next: \(Text(next.badge.title))")
                                .font(.app(.footnote, .semibold))
                            Spacer()
                            Text("\(next.current) of \(next.target)")
                                .font(.app(.footnote))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        ProgressView(value: Double(next.current), total: Double(next.target))
                            .tint(Theme.accent)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelPadding(horizontal: 16, vertical: 16)
            .homePanel(cornerRadius: Theme.cardRadius)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medal(_ badge: ProfileBadge) -> some View {
        let isPinned = pinned.contains(badge)
        return VStack(spacing: 6) {
            Image(systemName: badge.symbol)
                .font(.app(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(badge.color, in: .circle)
                .overlay(Circle().inset(by: 3).stroke(.white.opacity(0.35), lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.app(size: 10, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 22, height: 22)
                            .background(Theme.accent, in: .circle)
                            .offset(x: 4, y: -4)
                    }
                }
            Text(badge.title)
                .font(.app(.caption, .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPinned ? .isSelected : [])
    }
}

/// A profile as friends see it — the body of `SharedProfileView`, and the owner's own
/// "Viewing as Friends" preview. `actions` sits under the header (the friend button).
struct ProfileShowcaseContent<Actions: View>: View {
    let profile: PublicProfile
    /// What the viewer shares with this person; nil on the owner's own preview.
    var mutual: MutualContext? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 24) {
            ProfileHeader(person: profile.person, name: profile.name, showcase: profile.showcase,
                          bio: profile.bio, birthday: profile.birthday)

            actions()

            if let mutual, !mutual.isEmpty {
                MutualContextCard(friendName: profile.name, context: mutual)
            }

            let notes = profile.showcase.answeredPrompts
            if !notes.isEmpty {
                TravelNotesSection(notes: notes)
            }

            if !profile.visitedPlaces.isEmpty {
                PlacesShowcaseSection(title: "Where \(profile.name) has been",
                                      places: profile.visitedPlaces,
                                      favorite: profile.showcase.favoritePlace,
                                      memory: profile.showcase.favoriteMemory,
                                      sharedKeys: mutual?.sharedPlaceKeys ?? [])
            }

            if !profile.showcase.bucketList.isEmpty {
                BucketListSection(places: profile.showcase.bucketList,
                                  sharedKeys: mutual?.sharedBucketKeys ?? [])
            }

            if !profile.showcase.moments.isEmpty {
                MomentsSection(moments: profile.showcase.moments)
            }

            let badges = profile.displayedBadges
            if !badges.isEmpty {
                BadgesSection(badges: badges)
            }

            if !profile.trips.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Trips")
                        .font(.app(.title3, .bold))
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(profile.trips) { SummaryTripCard(trip: $0) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

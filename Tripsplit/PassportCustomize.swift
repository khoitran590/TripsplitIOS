import SwiftUI

/// Where the owner makes the passport card theirs: which places are stamped, which three
/// numbers it headlines, the line at its foot, and the personal seal. Pushed from
/// `ProfileShareSheet`, which re-renders the card from the profile on the way back.
///
/// Every pick is saved straight to `showcase.card`, the way the cover is.
struct PassportCustomizeView: View {
    let name: String
    let places: [VisitedPlace]
    let statValues: [PassportStat: Int]
    let cover: ShareCardCover

    @Environment(TripStore.self) private var store
    /// Held locally while typing so a keystroke isn't a profile save.
    @State private var motto = ""
    @FocusState private var mottoFocused: Bool

    private var style: PassportCardStyle { store.userProfile.showcase.card }

    private func update(_ change: (inout PassportCardStyle) -> Void) {
        store.updateShowcase { change(&$0.card) }
    }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        Form {
            Section {
                if places.isEmpty {
                    Text("Add places to your profile to stamp them here.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    stampChips
                }
            } header: {
                Text("Featured stamps")
            } footer: {
                Text("Pick up to 3 favorite places to stamp on your card. With none picked, your first places are stamped.")
            }

            Section {
                ForEach(0..<3, id: \.self) { slot in
                    Picker(selection: statBinding(slot)) {
                        ForEach(PassportStat.allCases) { stat in
                            Text(stat.label).tag(stat)
                        }
                    } label: {
                        Text(verbatim: "\(statValues[style.headlineStats[slot]] ?? 0)")
                            .font(.app(.title3, .bold))
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Headline numbers")
            } footer: {
                Text("The three numbers printed across the card.")
            }

            Section("Personal line") {
                Picker("Personal line", selection: lineBinding) {
                    ForEach(PassportLine.allCases) { line in
                        Text(line.label).tag(line)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if style.personalLine == .motto {
                    TextField("Motto", text: $motto, prompt: Text("Window seat, always."))
                        .focused($mottoFocused)
                        .submitLabel(.done)
                        .onSubmit(saveMotto)
                        .onChange(of: motto) { _, text in
                            if text.count > PassportCardStyle.mottoLimit {
                                motto = String(text.prefix(PassportCardStyle.mottoLimit))
                            }
                        }
                        .onChange(of: mottoFocused) { _, focused in
                            if !focused { saveMotto() }
                        }
                }
            }

            Section("Personal seal") {
                Toggle("Show seal", isOn: toggle(\.showsSeal))
                if style.showsSeal {
                    let seal = style.seal(for: name)
                    sealRow("Frame", options: PassportSealFrame.allCases, selected: seal.frame,
                            label: \.label) { option in
                        PassportSeal(outline: option, motif: seal.motif, initials: initials,
                                     color: cover.stampInks[0])
                    } pick: { option in
                        update { $0.sealFrame = option.rawValue }
                    }
                    sealRow("Motif", options: PassportSealMotif.allCases, selected: seal.motif,
                            label: \.label) { option in
                        PassportSeal(outline: seal.frame, motif: option, initials: initials,
                                     color: cover.stampInks[0])
                    } pick: { option in
                        update { $0.sealMotif = option.rawValue }
                    }
                }
            }

            Section("Show on card") {
                Toggle("Home base", isOn: toggle(\.showsHomeBase))
                Toggle("QR code to add me", isOn: toggle(\.showsQR))
            }
        }
        .tint(Theme.accent)
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("Customize passport")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { motto = style.motto }
        .onDisappear(perform: saveMotto)
    }

    /// The visited places as chips; a picked one is filled. A fourth pick is refused
    /// rather than silently dropping the first.
    private var stampChips: some View {
        let picked = style.featuredPlaces.map { $0.lowercased() }
        return FlowLayout(spacing: 8) {
            ForEach(places) { place in
                let isOn = picked.contains(place.id)
                Button {
                    update { card in
                        if isOn {
                            card.featuredPlaces.removeAll { $0.lowercased() == place.id }
                        } else if card.featuredPlaces.count < PassportCardStyle.stampLimit {
                            card.featuredPlaces.append(place.name)
                        }
                    }
                } label: {
                    Text(verbatim: place.shortName)
                        .font(.app(.subheadline, isOn ? .semibold : nil))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(isOn ? Theme.accentPastel : Theme.surface, in: .capsule)
                        .overlay(Capsule().stroke(isOn ? .clear : Theme.separator, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!isOn && picked.count >= PassportCardStyle.stampLimit)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    /// One row of seal previews, each drawn with the option applied to the current seal.
    private func sealRow<Option: Identifiable & Equatable, Preview: View>(
        _ title: LocalizedStringKey,
        options: [Option],
        selected: Option,
        label: KeyPath<Option, LocalizedStringKey>,
        @ViewBuilder preview: @escaping (Option) -> Preview,
        pick: @escaping (Option) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.app(.subheadline))
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options) { option in
                        Button { pick(option) } label: {
                            preview(option)
                                .frame(width: 44, height: 44)
                                .padding(8)
                                .background(Theme.surface, in: .rect(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(option == selected ? Theme.accent : Theme.separator,
                                                lineWidth: option == selected ? 2.5 : 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(option[keyPath: label]))
                        .accessibilityAddTraits(option == selected ? .isSelected : [])
                    }
                }
                .padding(2)
            }
        }
        .padding(.vertical, 4)
    }

    /// Picking a number another slot already shows swaps the two, so the card never
    /// prints the same count twice.
    private func statBinding(_ slot: Int) -> Binding<PassportStat> {
        Binding {
            style.headlineStats[slot]
        } set: { stat in
            var picks = style.headlineStats
            if let other = picks.firstIndex(of: stat) {
                picks.swapAt(other, slot)
            } else {
                picks[slot] = stat
            }
            update { $0.stats = picks.map(\.rawValue) }
        }
    }

    private var lineBinding: Binding<PassportLine> {
        Binding { style.personalLine } set: { line in update { $0.line = line.rawValue } }
    }

    private func toggle(_ keyPath: WritableKeyPath<PassportCardStyle, Bool>) -> Binding<Bool> {
        Binding { style[keyPath: keyPath] } set: { isOn in update { $0[keyPath: keyPath] = isOn } }
    }

    private func saveMotto() {
        let trimmed = motto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != style.motto else { return }
        update { $0.motto = trimmed }
    }
}

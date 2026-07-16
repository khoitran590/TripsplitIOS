import SwiftUI
import Observation
import Combine
import ImageIO
import PhotosUI
import UIKit
import VisionKit
import MapKit

// MARK: - Add Trip

/// A sheet for creating a trip: name, currency, the owner's personal budget, and local participants.
struct AddTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store

    @State private var name = ""
    @State private var location = ""
    @State private var hasDates = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var currency = "USD"
    @State private var budgetText = ""
    @State private var memberName = ""
    @State private var members: [Person] = []
    @State private var coverPick: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverJPEG: Data?
    @State private var cropCandidate: CoverCropCandidate?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        coverHero
                        header
                        whereCard
                        datesCard
                        budgetCard
                        tripmatesCard
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(Theme.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .padding(.bottom, 12)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { startPlanningButton }
            .onChange(of: coverPick) { _, pick in
                guard let pick else { return }
                Task {
                    guard let data = try? await pick.loadTransferable(type: Data.self) else { return }
                    // Downscale/normalize first, then let the user frame the shot.
                    if let prepared = await UploadImagePreparation.preparedImage(
                        from: data,
                        maxPixelSize: 1_600,
                        compressionQuality: 0.72
                    ) {
                        cropCandidate = CoverCropCandidate(image: prepared.image)
                    } else if let image = UIImage(data: data) {
                        cropCandidate = CoverCropCandidate(image: image)
                    }
                    coverPick = nil
                }
            }
            .fullScreenCover(item: $cropCandidate) { candidate in
                CoverCropView(image: candidate.image) { cropped in
                    coverImage = cropped
                    coverJPEG = nil // Recompressed from the cropped image at save time.
                }
            }
        }
    }

    /// Wanderlog-style full-bleed cover header: the picked photo (or a themed gradient
    /// placeholder) with a small glass "Add photo" chip floating over its corner.
    private var coverHero: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage).resizable().scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Theme.accent, Theme.accentSecondary],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(.rect(cornerRadius: 28))

            PhotosPicker(selection: $coverPick, matching: .images) {
                Label(coverImage == nil ? "Add photo" : "Change photo", systemImage: "camera.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .capsule)
            .padding(12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan a new trip")
                .font(.system(.largeTitle).weight(.bold))
            Text("Name it, pick a place, and bring your crew.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whereCard: some View {
        TripCard(title: "Where to?", icon: "mappin.and.ellipse") {
            HStack(spacing: 10) {
                Image(systemName: "suitcase.fill").foregroundStyle(.secondary)
                TextField("Trip name (e.g. Summer in Tokyo)", text: $name)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            LocationField(text: $location)

            HStack {
                Text("Currency").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Currency", selection: $currency) {
                        ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: .capsule)
                }
            }
        }
    }

    private var datesCard: some View {
        TripCard(title: "When?", icon: "calendar") {
            Toggle("Add travel dates", isOn: $hasDates.animation(.snappy))
                .font(.subheadline.weight(.medium))
                .tint(Theme.accent)
            if hasDates {
                DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    .font(.subheadline)
                DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .font(.subheadline)
            }
        }
    }

    /// The pinned bottom call-to-action, mirroring Wanderlog's "Start planning".
    private var startPlanningButton: some View {
        Button {
            create()
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Label("Start planning", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
        .disabled(!canCreate)
        .opacity(canCreate ? 1 : 0.5)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var budgetCard: some View {
        TripCard(title: "Your budget", icon: "wallet.bifold.fill") {
            Text("How much you can personally spend on this trip.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(currencySymbol(currency)).foregroundStyle(.secondary)
                TextField("0.00", text: $budgetText)
                    .keyboardType(.decimalPad)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
        }
    }

    private var tripmatesCard: some View {
        TripCard(title: "Tripmates", icon: "person.2.fill") {
            Text("You can invite people with an account after the trip is created.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Everyone on the trip so far, as removable chips (owner first, fixed).
            FlowLayout(spacing: 8) {
                if store.currentUser.name.isEmpty {
                    tripmateChip(person: store.currentUser, label: Text("You"), removable: false)
                } else {
                    tripmateChip(person: store.currentUser, label: Text("\(store.currentUser.name) (You)"), removable: false)
                }
                ForEach(members) { member in
                    tripmateChip(person: member, label: Text(verbatim: member.name), removable: true)
                }
            }

            HStack(spacing: 10) {
                TextField("Add tripmate name", text: $memberName)
                    .submitLabel(.done)
                    .onSubmit { addMember() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                Button { addMember() } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                .disabled(memberName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func tripmateChip(person: Person, label: Text, removable: Bool) -> some View {
        HStack(spacing: 6) {
            avatar(person, size: 24)
            label
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if removable {
                Button {
                    members.removeAll { $0.id == person.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, removable ? 8 : 11)
        .padding(.vertical, 5)
        .background(person.color.opacity(0.12), in: .capsule)
    }

    private func addMember() {
        let trimmed = memberName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let color = Color(hex: memberPalette[members.count % memberPalette.count])
        members.append(Person(name: trimmed, color: color))
        memberName = ""
    }

    private func create() {
        let me = store.currentUser
        let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
        var trip = Trip(
            name: name.trimmingCharacters(in: .whitespaces),
            currencyCode: currency,
            creatorID: me.id,
            members: [me] + members,
            budgets: [me.id: Double(budgetText) ?? 0],
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            startDate: hasDates ? startDate : nil,
            endDate: hasDates ? endDate : nil
        )
        isSaving = true
        errorMessage = nil
        Task {
            if let coverImage {
                let jpeg: Data?
                if let coverJPEG {
                    jpeg = coverJPEG
                } else {
                    jpeg = await UploadImagePreparation.jpegData(
                        from: coverImage,
                        maxPixelSize: 1_600,
                        compressionQuality: 0.72
                    )
                }
                guard let jpeg else {
                    errorMessage = "Couldn't prepare the cover photo."
                    isSaving = false
                    return
                }
                do {
                    trip.coverImageURL = try await store.uploadTripCover(jpeg, tripID: trip.id)
                } catch {
                    errorMessage = (error as? AuthError)?.message ?? "Couldn't upload the cover photo."
                    isSaving = false
                    return
                }
            }
            store.addTrip(trip)
            isSaving = false
            dismiss()
        }
    }
}

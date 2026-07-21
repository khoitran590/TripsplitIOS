import SwiftUI
import Observation
import Combine
import ImageIO
import PhotosUI
import UIKit
import VisionKit
import MapKit

// MARK: - Edit Trip

/// Edits a trip's name, location, dates, currency, cover photo, and the signed-in user's
/// budget. Available to the trip owner from the detail hero header.
struct EditTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID

    @State private var name = ""
    @State private var location = ""
    @State private var hasDates = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var currency = "USD"
    @State private var budgetText = ""
    @State private var coverPick: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverJPEG: Data?
    @State private var cropCandidate: CoverCropCandidate?
    @State private var isLoadingCurrentCover = false
    @State private var allowMembersToPayForOthers = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var loaded = false

    /// The trip's currency and the user's budget at load time, so switching the currency
    /// picker can re-derive the converted budget from a stable origin (rather than
    /// compounding conversions) and `save()` knows whether a conversion is needed.
    @State private var originalCurrency = "USD"
    @State private var originalBudget: Double = 0

    private var trip: Trip? { store.trip(tripID) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: Theme.sheetGradient, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        coverCard
                        detailsCard
                        datesCard
                        budgetCard
                        permissionsCard
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.app(.caption))
                                .foregroundStyle(Theme.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }.disabled(!canSave)
                    }
                }
            }
            .task { load() }
            .onChange(of: currency) { _, _ in currencyChanged() }
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

    private var coverCard: some View {
        TripCard(title: "Cover Photo", icon: "photo.fill") {
            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage).resizable().scaledToFill()
                } else if let trip {
                    TripCoverView(trip: trip)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(.rect(cornerRadius: 14))

            PhotosPicker(selection: $coverPick, matching: .images) {
                Label("Change Photo", systemImage: "photo.on.rectangle.angled")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)

            if coverImage != nil || trip?.coverImageURL?.isEmpty == false {
                Button { adjustCurrentCover() } label: {
                    HStack(spacing: 7) {
                        if isLoadingCurrentCover { ProgressView().controlSize(.small) }
                        Label("Resize or reposition", systemImage: "crop")
                    }
                    .font(.app(.subheadline, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .disabled(isLoadingCurrentCover)
            }
        }
    }

    private func adjustCurrentCover() {
        if let coverImage {
            cropCandidate = CoverCropCandidate(image: coverImage)
            return
        }
        guard let stored = trip?.coverImageURL, !stored.isEmpty else { return }
        isLoadingCurrentCover = true
        Task {
            defer { isLoadingCurrentCover = false }
            if let image = await store.editableTripCover(from: stored) {
                cropCandidate = CoverCropCandidate(image: image)
            } else {
                errorMessage = "Couldn't load the current cover photo. Check your connection and try again."
            }
        }
    }

    private var detailsCard: some View {
        TripCard(title: "Trip details", icon: "suitcase.fill") {
            TextField("Trip name", text: $name)
                .font(.app(.title3, .semibold))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            LocationField(text: $location)

            HStack {
                Text("Currency").font(.app(.subheadline)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Currency", selection: $currency) {
                        ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency).font(.app(.subheadline, .semibold))
                        Image(systemName: "chevron.down").font(.app(.caption2, .bold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: .capsule)
                }
            }

            if currency != originalCurrency {
                Label("Existing expenses and budgets will be converted to \(currency) at today's rate.", systemImage: "arrow.left.arrow.right")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var datesCard: some View {
        TripCard(title: "Dates", icon: "calendar") {
            Toggle("Add travel dates", isOn: $hasDates.animation(.snappy))
                .font(.app(.subheadline, .medium))
            if hasDates {
                DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    .font(.app(.subheadline))
                DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .font(.app(.subheadline))
            }
        }
    }

    private var budgetCard: some View {
        TripCard(title: "Your budget", icon: "wallet.bifold.fill") {
            Text("How much you can personally spend on this trip.")
                .font(.app(.footnote)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(currencySymbol(currency)).foregroundStyle(.secondary)
                TextField("0.00", text: $budgetText).keyboardType(.decimalPad)
            }
            .font(.app(.title3, .semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
        }
    }

    private var permissionsCard: some View {
        TripCard(title: "Permissions", icon: "person.badge.key.fill") {
            Toggle(isOn: $allowMembersToPayForOthers) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Members can pay for others")
                        .font(.app(.subheadline, .medium))
                    Text("Let invited members record an expense paid by someone else. You can always do this.")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        guard !loaded, let trip else { return }
        name = trip.name
        location = trip.location ?? ""
        currency = trip.currencyCode
        originalCurrency = trip.currencyCode
        let budget = trip.budget(for: store.currentUser.id)
        originalBudget = budget
        budgetText = budget > 0 ? String(format: "%g", budget) : ""
        if let start = trip.startDate { startDate = start; hasDates = true }
        if let end = trip.endDate { endDate = end; hasDates = true }
        allowMembersToPayForOthers = trip.allowMembersToPayForOthers
        loaded = true
    }

    /// When the currency picker changes, re-derive the displayed budget from the original
    /// value so the field shows the converted amount the user is about to save. Re-deriving
    /// from `originalBudget` (rather than the current text) avoids compounding conversions
    /// when the user switches currencies several times.
    private func currencyChanged() {
        guard loaded else { return }
        guard currency != originalCurrency else {
            budgetText = originalBudget > 0 ? String(format: "%g", originalBudget) : ""
            return
        }
        Task {
            guard let rate = await store.conversionRate(from: originalCurrency, to: currency) else { return }
            budgetText = originalBudget > 0 ? String(format: "%g", SplitEngine.roundToTwo(originalBudget * rate)) : ""
        }
    }

    private func save() {
        guard var updated = trip else { return }
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
                    updated.coverImageURL = try await store.uploadTripCover(jpeg, tripID: tripID)
                } catch {
                    errorMessage = (error as? AuthError)?.message ?? "Couldn't upload the cover photo."
                    isSaving = false
                    return
                }
            }
            // Currency change: convert every stored amount (expenses, shares, tax/tip,
            // settlements, budgets) by the live rate so they reflect real converted value
            // rather than being relabeled. Abort if rates are unavailable so we never
            // silently mislabel amounts (e.g. a 100 USD expense as "100 ₫").
            if currency != originalCurrency {
                guard let rate = await store.conversionRate(from: originalCurrency, to: currency) else {
                    errorMessage = "Couldn't fetch the exchange rate to convert amounts. Check your connection and try again."
                    isSaving = false
                    return
                }
                updated = store.applyingCurrencyConversion(updated, rate: rate)
            }

            let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
            updated.name = name.trimmingCharacters(in: .whitespaces)
            updated.location = trimmedLocation.isEmpty ? nil : trimmedLocation
            updated.currencyCode = currency
            updated.startDate = hasDates ? startDate : nil
            updated.endDate = hasDates ? endDate : nil
            updated.allowMembersToPayForOthers = allowMembersToPayForOthers
            // The budget field is shown (and auto-converted) in the new currency, so save it
            // as typed — this also honors a manual budget edit over the converted default.
            updated.budgets[store.currentUser.id] = Double(budgetText) ?? 0
            store.updateTrip(updated)
            isSaving = false
            dismiss()
        }
    }
}

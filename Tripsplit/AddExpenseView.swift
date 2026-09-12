import SwiftUI
import PhotosUI
import UIKit
import VisionKit
import MapKit

// MARK: - Add Expense

/// A sheet for logging an expense. The trip owner may assign any local participant as
/// payer and choose who shares it.
struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    let tripID: Trip.ID
    /// When set, the sheet edits this expense in place instead of creating a new one.
    var editing: Expense? = nil
    var prefillTitle: String? = nil
    var prefillAmount: Double? = nil
    var prefillLocation: ExpenseLocation? = nil
    /// Opens a new expense with the full group split configuration expanded. Used by
    /// the Trips quick action so "Split expense" always creates a persistent record.
    var startWithFullSplit = false

    @State private var draft = ExpenseDraft()
    @State private var hasConfiguredDraft = false
    @State private var locationQuery = ""
    @State private var isSelectingLocation = false
    @StateObject private var locationCompleter = StopPlaceCompleter()
    @FocusState private var locationFocused: Bool
    @FocusState private var focusedField: ExpenseField?

    private enum ExpenseField: Hashable { case title, amount }

    // Receipt scanning + upload.
    @State private var receiptPick: PhotosPickerItem?
    @State private var receiptImage: UIImage?
    @State private var isScanning = false
    @State private var isUploading = false
    @State private var usedRateLimitedReceiptFallback = false
    @State private var configuringIndex: Int?
    @State private var showCamera = false
    @State private var uploadError: String?
    @State private var showReceiptAIConsent = false
    @State private var pendingConsentReceipt: (image: UIImage, originalData: Data?)?
    @State private var isSaving = false
    @State private var showDetails = false
    @State private var showSplitConfiguration = false

    private var isEditing: Bool { editing != nil }
    private var trip: Trip? { store.trip(tripID) }
    private var isCreator: Bool { trip.map { store.isCreator(of: $0) } ?? false }

    private var resolvedPayer: Person.ID { draft.payer(fallback: store.currentUser.id) }

    /// The creator can always record an expense paid by another member; other (invited)
    /// members can only when the trip's `allowMembersToPayForOthers` permission is on.
    private var canChoosePayer: Bool {
        isCreator || (trip?.allowMembersToPayForOthers ?? false)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: Theme.sheetGradient,
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                if let trip {
                    ScrollView {
                        VStack(spacing: Theme.Space.section) {
                            amountCard(trip)
                            if draft.items.isEmpty {
                                splitCard(trip)
                            }
                            receiptCard(trip)
                            if !draft.items.isEmpty {
                                taxTipCard(trip)
                                itemSplitsCard(trip)
                            }
                            optionalDetails
                        }
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.vertical, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let trip {
                    Button { Task { await save() } } label: {
                        HStack(spacing: 8) {
                            if isSaving { ProgressView().tint(Theme.onAccent) }
                            Text(isEditing ? "Save expense" : "Add expense")
                        }
                    }
                    .buttonStyle(AppActionStyle())
                    .disabled(!draft.canSave(trip, currentUserID: store.currentUser.id) || isSaving || isScanning || isUploading)
                    .accessibilityIdentifier("save-expense")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.background)
                }
            }
            .navigationTitle(isEditing ? "Edit Expense" : "Add Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil; locationFocused = false }
                }
            }
            .onAppear(perform: configureDefaults)
            // In itemized mode the expense total is item prices + tax + tip; keep the
            // amount field in lockstep instead of asking the user to copy it over.
            .onChange(of: draft.grandTotal) {
                if !draft.items.isEmpty { draft.amountText = formatted(draft.grandTotal) }
            }
            .onChange(of: locationQuery) { _, newValue in
                if isSelectingLocation {
                    isSelectingLocation = false
                    return
                }
                draft.expenseLocation = nil
                locationCompleter.update(query: newValue)
            }
            .onChange(of: receiptPick) { _, newValue in
                guard let newValue else { return }
                Task { await handlePickedReceipt(newValue) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocumentCameraView { image in
                    showCamera = false
                    guard let image else { return }
                    Task { await processReceipt(image, originalData: nil) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(
                get: { configuringIndex != nil },
                set: { if !$0 { configuringIndex = nil } }
            )) {
                if let index = configuringIndex, draft.items.indices.contains(index), let trip {
                    ItemSplitConfigView(
                        item: $draft.items[index],
                        members: trip.members,
                        payer: resolvedPayer,
                        currencyCode: trip.currencyCode,
                        currentUserID: store.currentUser.id
                    )
                }
            }
            .sheet(isPresented: $showReceiptAIConsent) {
                AIConsentDisclosureView(purpose: .receiptProcessing) { granted in
                    guard let pending = pendingConsentReceipt else { return }
                    pendingConsentReceipt = nil
                    Task {
                        await scanAndUploadReceipt(
                            pending.image,
                            originalData: pending.originalData,
                            useCloudAI: granted
                        )
                    }
                }
            }
        }
    }

    // MARK: Receipt

    private func receiptCard(_ trip: Trip) -> some View {
        TripCard(title: "Receipt", icon: "doc.text.viewfinder") {
            if let receiptImage {
                Image(uiImage: receiptImage)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 150)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 12))
            }

            HStack(spacing: 10) {
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        showCamera = true
                    } label: {
                        receiptActionLabel(icon: "camera.fill", title: "Scan receipt")
                    }
                    .buttonStyle(.plain)
                }

                PhotosPicker(selection: $receiptPick, matching: .images) {
                    receiptActionLabel(
                        icon: receiptImage == nil ? "photo.on.rectangle" : "arrow.triangle.2.circlepath",
                        title: receiptImage == nil ? "Upload receipt" : "Replace"
                    )
                }
                .buttonStyle(.plain)
            }

            if isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Scanning…").font(Theme.Typography.metadata).foregroundStyle(.secondary)
                }
            } else if isUploading {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Uploading…").font(Theme.Typography.metadata).foregroundStyle(.secondary)
                }
            } else if let uploadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(uploadError, systemImage: "exclamationmark.icloud.fill")
                        .font(Theme.Typography.metadata).foregroundStyle(Theme.negative)
                    if let receiptImage {
                        Button("Retry upload") {
                            Task { await uploadReceipt(receiptImage, originalData: nil) }
                        }
                        .font(.app(.caption, .semibold)).foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                    }
                }
            } else if draft.receiptURL != nil {
                Label("Receipt photo saved", systemImage: "checkmark.icloud.fill")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
            }

            if usedRateLimitedReceiptFallback && !isScanning {
                Label(
                    "Using offline scan — AI limit reached. Try again shortly.",
                    systemImage: "bolt.slash.fill"
                )
                .font(Theme.Typography.metadata)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("receipt-rate-limit-fallback")
            }

            if !draft.items.isEmpty || !draft.removedItems.isEmpty {
                itemsEditor(trip)
            } else if receiptImage != nil && !isScanning {
                Text("No items detected — enter the amount above.")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
            }

            // Quiet entry point into itemized mode without a scan: one tap adds a first
            // blank line and the editor (plus tax/tip and per-item splits) appears.
            if draft.items.isEmpty && draft.removedItems.isEmpty && !isScanning {
                Button {
                    withAnimation(.snappy) { addBlankItem(trip) }
                } label: {
                    Label("Or add items manually", systemImage: "plus.circle")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func receiptActionLabel(icon: String, title label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(label).font(Theme.Typography.rowTitle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .fieldFill()
    }

    private func itemsEditor(_ trip: Trip) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Items (\(draft.items.count))").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Total \(money(draft.itemsTotal, trip.currencyCode))").font(.app(.caption, .semibold))
            }
            ForEach($draft.items) { $item in
                HStack(spacing: 8) {
                    TextField("Item", text: $item.name)
                        .font(Theme.Typography.secondary)
                    Spacer(minLength: 6)
                    Text(currencySymbol(trip.currencyCode)).font(Theme.Typography.secondary).foregroundStyle(.secondary)
                    TextField("0.00", value: $item.price, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Button {
                        removeItem(item)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .fieldFill(cornerRadius: 10)
            }

            HStack {
                Button {
                    addBlankItem(trip)
                } label: {
                    Label("Add item", systemImage: "plus.circle.fill")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                if let last = draft.removedItems.first {
                    Button {
                        undoRemove()
                    } label: {
                        Label("Undo \"\(last.item.name)\"", systemImage: "arrow.uturn.backward")
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }

        }
    }

    /// Removes an item, remembering it (and its position) so the removal can be undone.
    private func removeItem(_ item: ReceiptItem) {
        guard let index = draft.items.firstIndex(where: { $0.id == item.id }) else { return }
        draft.removedItems.insert((item, index), at: 0)
        draft.items.remove(at: index)
        draft.amountText = formatted(draft.grandTotal)
    }

    /// Restores the most recently removed item to its original position.
    private func undoRemove() {
        guard let restored = draft.removedItems.first else { return }
        draft.removedItems.removeFirst()
        let index = min(restored.index, draft.items.count)
        draft.items.insert(restored.item, at: index)
        draft.amountText = formatted(draft.grandTotal)
    }

    /// Appends a blank item the user can fill in for something the scan missed.
    private func addBlankItem(_ trip: Trip) {
        var item = ReceiptItem(name: "", price: 0)
        if draft.payForOthers {
            item.splitMethod = .equalAll
            item.participantIDs = Set(trip.members.map(\.id))
        } else {
            item.splitMethod = .equalSelected
            item.participantIDs = [store.currentUser.id]
        }
        draft.items.append(item)
    }

    @MainActor
    private func handlePickedReceipt(_ pick: PhotosPickerItem) async {
        guard let data = try? await pick.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await processReceipt(image, originalData: data)
    }

    /// Scans an image (from the photo picker or the live camera), populates the editable
    /// item list plus any detected tax/tip, and uploads the photo in the background.
    @MainActor
    private func processReceipt(_ image: UIImage, originalData: Data?) async {
        let userID = store.currentUser.id
        guard AIConsentPreferences.hasDecision(.receiptProcessing, userID: userID) else {
            pendingConsentReceipt = (image, originalData)
            showReceiptAIConsent = true
            return
        }
        await scanAndUploadReceipt(
            image,
            originalData: originalData,
            useCloudAI: AIConsentPreferences.isGranted(.receiptProcessing, userID: userID)
        )
    }

    @MainActor
    private func scanAndUploadReceipt(_ image: UIImage, originalData: Data?, useCloudAI: Bool) async {
        receiptImage = image

        // A freshly picked/replaced photo invalidates the previous scan and upload. Clear
        // the old upload state so the scanning process starts over AND the new image
        // actually re-uploads — the upload guard (`receiptURL == nil`) otherwise skips the
        // upload whenever a URL was already set, silently persisting the previous photo.
        draft.receiptURL = nil
        uploadError = nil
        usedRateLimitedReceiptFallback = false

        isScanning = true
        let scan = await ReceiptScanner.scan(
            image,
            mode: useCloudAI ? .onlineBest : .offlineFast,
            accessToken: useCloudAI ? store.accessToken : nil
        )
        isScanning = false
        usedRateLimitedReceiptFallback = scan.aiRateLimitRetryAfterSeconds != nil
        if !scan.items.isEmpty {
            draft.removedItems = []
            let everyone = Set(store.trip(tripID)?.members.map(\.id) ?? [])
            draft.items = scan.items.map { item in
                var configured = item
                if draft.payForOthers {
                    configured.splitMethod = .equalAll
                    configured.participantIDs = everyone
                } else {
                    configured.splitMethod = .equalSelected
                    configured.participantIDs = [store.currentUser.id]
                }
                return configured
            }
            if let tax = scan.tax { draft.taxText = formatted(tax) }
            if let tip = scan.tip { draft.tipText = formatted(tip) }
            draft.amountText = formatted(draft.grandTotal)
        }

        // Upload in the background; the URL is attached on save (and the save path retries
        // if this hasn't finished or failed by the time the user taps Save).
        await uploadReceipt(image, originalData: originalData)
    }

    /// Uploads the current receipt image to Supabase Storage, recording the public URL on
    /// success or a user-facing reason on failure. Safe to call again to retry.
    @MainActor
    private func uploadReceipt(_ image: UIImage, originalData: Data?) async {
        guard draft.receiptURL == nil else { return }
        guard store.accessToken != nil else {
            uploadError = "Sign in to upload the receipt photo."
            return
        }
        let preparedJPEG: Data?
        if let originalData {
            preparedJPEG = await UploadImagePreparation.jpegData(
                from: originalData,
                maxPixelSize: 2_200,
                compressionQuality: 0.72
            )
        } else {
            preparedJPEG = await UploadImagePreparation.jpegData(
                from: image,
                maxPixelSize: 2_200,
                compressionQuality: 0.72
            )
        }
        let jpeg = preparedJPEG ?? originalData ?? Data()
        guard !jpeg.isEmpty else { uploadError = "Couldn't read the receipt image."; return }

        // Lowercase the id: the storage RLS policy compares the leading folder against
        // `auth.uid()::text`, which Postgres renders lowercase, whereas Swift's
        // `uuidString` is uppercase — a mismatch trips "violates row-level security".
        let path = "\(store.currentUser.id.uuidString.lowercased())/\(draft.expenseID.uuidString.lowercased()).jpg"
        isUploading = true
        uploadError = nil
        do {
            draft.receiptURL = try await store.uploadReceipt(
                jpeg,
                path: path,
                tripID: tripID,
                expenseID: draft.expenseID
            )
        } catch {
            uploadError = (error as? AuthError)?.message ?? "Receipt upload failed."
        }
        isUploading = false
    }

    // MARK: Amount + payer

    @ViewBuilder
    private func amountCard(_ trip: Trip) -> some View {
        cardAmountCard(trip)
    }

    private func cardAmountCard(_ trip: Trip) -> some View {
        TripCard(title: "Expense", icon: "dollarsign.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Amount")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Text(trip.currencyCode).foregroundStyle(Theme.textSecondary)
                    TextField("0.00", text: $draft.amountText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                        .disabled(!draft.items.isEmpty)
                        .accessibilityLabel("Amount in \(trip.currencyCode)")
                        .accessibilityIdentifier("expense-amount")
                }
                .font(Theme.Typography.amount)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .fieldFill()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Dinner", text: $draft.title)
                    .font(.app(.subheadline, .medium))
                    .textContentType(.none)
                    .accessibilityIdentifier("expense-title")
                    .submitLabel(.next)
                    .focused($focusedField, equals: .title)
                    .onSubmit { focusedField = .amount }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .fieldFill()
            }

            if !draft.items.isEmpty {
                Text("Total is calculated from the items, tax, and tip below.")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

           Divider()
            payerRow(trip)
        }
    }

    @ViewBuilder
    private func payerCard(_ trip: Trip) -> some View {
        cardPayerCard(trip)
    }

    @ViewBuilder
    private func payerMenuItems(_ trip: Trip) -> some View {
        ForEach(trip.members) { member in
            Button {
                draft.selectedPayerID = member.id
            } label: {
                let label = LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name)
                if member.id == resolvedPayer {
                    Label(label, systemImage: "checkmark")
                } else {
                    Text(label)
                }
            }
        }
    }

    private func cardPayerCard(_ trip: Trip) -> some View {
        TripCard(title: "Paid by", icon: "creditcard.fill") { payerRow(trip) }
    }

    private func payerRow(_ trip: Trip) -> some View {
        let payer = trip.members.first { $0.id == resolvedPayer } ?? store.currentUser
        return HStack(spacing: 10) {
            Text("Paid by").font(Theme.Typography.secondary).foregroundStyle(Theme.textSecondary)
            Spacer()
            if canChoosePayer {
                Menu { payerMenuItems(trip) } label: { payerLabel(payer) }
                    .accessibilityIdentifier("expense-payer")
            } else {
                payerLabel(payer)
            }
        }
        .frame(minHeight: 44)
    }

    private func payerLabel(_ payer: Person) -> some View {
        HStack(spacing: 8) {
            avatar(payer, size: 28)
            Text(payer.id == store.currentUser.id ? String(localized: "You") : payer.name)
                .font(.app(.subheadline, .medium))
            if canChoosePayer {
                Image(systemName: "chevron.up.chevron.down").font(Theme.Typography.metadata)
            }
        }
        .foregroundStyle(.primary)
    }

    private var optionalDetails: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 16) {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    .font(Theme.Typography.secondary)
                locationCard
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Date & location", systemImage: "calendar")
                    .font(Theme.Typography.rowTitle)
                Text([draft.date.formatted(date: .abbreviated, time: .omitted),
                      draft.expenseLocation?.name ?? locationQuery].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary)
            }
            .frame(minHeight: 44)
        }
        .tint(Theme.accent)
        .padding(18)
        .readableSurface()
        .accessibilityIdentifier("expense-details")
    }

    private var locationCard: some View {
        Group {
            cardLocationCard
        }

    }

    private var cardLocationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Location (optional)", systemImage: "mappin.and.ellipse")
                .font(Theme.Typography.rowTitle)
            HStack(spacing: 10) {
                TextField("Merchant or place", text: $locationQuery)
                    .font(.app(.subheadline, .medium))
                    .focused($locationFocused)
                    .autocorrectionDisabled()
                if !locationQuery.isEmpty {
                    Button {
                        locationQuery = ""
                        draft.expenseLocation = nil
                        locationCompleter.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .fieldFill()

            if locationFocused && !locationCompleter.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(locationCompleter.suggestions.prefix(5).enumerated()), id: \.offset) { index, suggestion in
                        Button { selectExpenseLocation(suggestion) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).font(Theme.Typography.rowTitle)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(Theme.Typography.metadata).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if index < min(locationCompleter.suggestions.count, 5) - 1 { Divider() }
                    }
                }
                .fieldFill()
            } else if let location = draft.expenseLocation, let address = location.address {
                Label(address, systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
            }
        }
    }

    private func selectExpenseLocation(_ suggestion: MKLocalSearchCompletion) {
        isSelectingLocation = true
        locationQuery = suggestion.title
        locationCompleter.clear()
        locationFocused = false
        Task {
            let request = MKLocalSearch.Request(completion: suggestion)
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first,
                  locationQuery == suggestion.title else { return }
            draft.expenseLocation = ExpenseLocation(
                name: item.name ?? suggestion.title,
                address: item.address?.fullAddress,
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude
            )
        }
    }

    // MARK: Split

    private func splitCard(_ trip: Trip) -> some View {
        let outcome = draft.result(for: trip, currentUserID: store.currentUser.id)
        return TripCard(title: "Split", icon: "divide.circle.fill") {
            DisclosureGroup(isExpanded: $showSplitConfiguration) {
                VStack(alignment: .leading, spacing: 14) {
                    payForOthersButton(trip)

                    if draft.payForOthers {
                        Menu {
                            ForEach(SplitMethod.allCases) { option in
                                Button {
                                    draft.method = option
                                    draft.configureForMethod(trip, currentUserID: store.currentUser.id)
                                } label: {
                                    Label(LocalizedStringKey(option.rawValue), systemImage: option.icon)
                                }
                            }
                        } label: {
                            HStack {
                                 Image(systemName: draft.method.icon)
                                Text(LocalizedStringKey(draft.method.rawValue)).font(Theme.Typography.rowTitle)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(Theme.Typography.metadata).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(minHeight: 0)
                            .background {
                                RoundedRectangle(cornerRadius: 12).fill(Theme.fieldBackground)
                            }
                        }

                        switch draft.method {
                        case .equalAll:
                            Text("Split equally across all \(trip.members.count) member\(trip.members.count == 1 ? "" : "s").")
                                .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                        case .equalSelected:
                            memberToggleList(trip)
                        case .noSplit:
                            singlePayerList(trip)
                        case .percentage:
                            valueFields(trip, unit: "%", values: $draft.percentages)
                        case .amount:
                            valueFields(trip, unit: currencySymbol(trip.currencyCode), values: $draft.amounts)
                        }
                    }

                    sharePreview(trip, outcome)
                }
                .padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.payForOthers ? LocalizedStringKey(draft.method.rawValue) : "Just me")
                        .font(Theme.Typography.rowTitle)
                    Text("Your share \(money(outcome.owed[store.currentUser.id] ?? 0, trip.currencyCode))")
                        .font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary)
                }
                .frame(minHeight: 44)
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("expense-split")

            if let message = outcome.message, !outcome.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.caption, .medium))
                    .foregroundStyle(Theme.negative)
            }

        }
    }

    /// Toggle button that switches between "just me" and "pay for others" modes.
    private func payForOthersButton(_ trip: Trip) -> some View {
        Button {
            withAnimation(.snappy) {
                draft.payForOthers.toggle()
                if draft.payForOthers {
                    draft.method = .equalAll
                    draft.configureForMethod(trip, currentUserID: store.currentUser.id)
                    if !draft.items.isEmpty {
                        let everyone = Set(trip.members.map(\.id))
                        draft.items = draft.items.map {
                            var u = $0
                            u.splitMethod = .equalAll
                            u.participantIDs = everyone
                            return u
                        }
                        draft.amountText = formatted(draft.grandTotal)
                    }
                } else {
                    draft.method = .noSplit
                    draft.noSplitAssignee = store.currentUser.id
                    if !draft.items.isEmpty {
                        draft.items = draft.items.map {
                            var u = $0
                            u.splitMethod = .equalSelected
                            u.participantIDs = [store.currentUser.id]
                            return u
                        }
                        draft.amountText = formatted(draft.grandTotal)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: draft.payForOthers ? "checkmark.square.fill" : "square")
                    .font(.app(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pay for others")
                        .font(Theme.Typography.rowTitle)
                    Text(draft.payForOthers ? "Covering other members' expenses" : "Only covering your own share")
                        .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func memberToggleList(_ trip: Trip) -> some View {
        ForEach(trip.members) { member in
            Button {
                if draft.selected.contains(member.id) { draft.selected.remove(member.id) }
                else { draft.selected.insert(member.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: draft.selected.contains(member.id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(Theme.accent)
                    avatar(member, size: 30)
                    Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                        .font(.app(.subheadline, .medium))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func singlePayerList(_ trip: Trip) -> some View {
        ForEach(trip.members) { member in
            Button {
                draft.noSplitAssignee = member.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: (draft.noSplitAssignee ?? resolvedPayer) == member.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(Theme.accent)
                    avatar(member, size: 30)
                    Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                        .font(.app(.subheadline, .medium))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func valueFields(_ trip: Trip, unit: String, values: Binding<[Person.ID: Double]>) -> some View {
        ForEach(trip.members) { member in
            HStack(spacing: 10) {
                avatar(member, size: 30)
                Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                    .font(.app(.subheadline, .medium))
                Spacer()
                TextField("0", value: Binding(
                    get: { values.wrappedValue[member.id] ?? 0 },
                    set: { values.wrappedValue[member.id] = $0 }
                ), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .fieldFill(cornerRadius: 10)
                Text(unit).font(Theme.Typography.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func sharePreview(_ trip: Trip, _ outcome: SplitResult) -> some View {
        VStack(spacing: 4) {
            ForEach(trip.members) { member in
                let owed = outcome.owed[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                            .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.app(.caption, .semibold))
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func chip(label: String, selected isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Theme.accent : Theme.fieldBackground, in: .capsule)
    }

    // MARK: Per-item split

    @ViewBuilder
    private func taxTipCard(_ trip: Trip) -> some View {
        TripCard(title: "Tax & tip", icon: "percent") {
            Text("Allocated across items by each person's subtotal.")
                .font(Theme.Typography.metadata).foregroundStyle(.secondary)
            extraField(trip, title: "Tax", text: $draft.taxText)
            extraField(trip, title: "Tip", text: $draft.tipText)
        }
    }

    private func extraField(_ trip: Trip, title label: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.app(.subheadline, .medium))
            Spacer()
            Text(currencySymbol(trip.currencyCode)).font(Theme.Typography.secondary).foregroundStyle(.secondary)
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .fieldFill(cornerRadius: 10)
        }
    }

    private func itemSplitsCard(_ trip: Trip) -> some View {
        let outcome = draft.allocatedShares(trip, currentUserID: store.currentUser.id)
        return TripCard(title: "Item splits", icon: "list.bullet.indent") {
            payForOthersButton(trip)

            Text("Tap an item to choose how it's split.")
                .font(Theme.Typography.metadata).foregroundStyle(.secondary)

            ForEach(draft.items.indices, id: \.self) { index in
                let item = draft.items[index]
                Button {
                    if item.splitMethod == .equalSelected && item.participantIDs.isEmpty {
                        draft.items[index].participantIDs = Set(trip.members.map(\.id))
                    }
                    configuringIndex = index
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(Theme.Typography.rowTitle).lineLimit(1)
                            Label(LocalizedStringKey(item.splitMethod.rawValue), systemImage: item.splitMethod.icon)
                                .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(money(item.price, trip.currencyCode)).font(Theme.Typography.rowTitle)
                        Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent)
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .fieldFill(cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }

            if !outcome.valid {
                Label("Some items still need a valid split.", systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.caption, .medium)).foregroundStyle(Theme.negative)
            }

           Divider()
            totalRow("Subtotal", draft.itemsTotal, trip)
            if draft.taxAmount > 0.005 { totalRow("Tax", draft.taxAmount, trip) }
            if draft.tipAmount > 0.005 { totalRow("Tip", draft.tipAmount, trip) }
            totalRow("Total", draft.grandTotal, trip, bold: true)

           Divider()
            Text("Each person owes").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
            ForEach(trip.members) { member in
                let owed = outcome.shares[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                            .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.app(.caption, .semibold))
                    }
                }
            }
        }
    }

    private func totalRow(_ label: LocalizedStringKey, _ value: Double, _ trip: Trip, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.app(.caption, bold ? .bold : .regular))
                .foregroundStyle(bold ? .primary : .secondary)
            Spacer()
            Text(money(value, trip.currencyCode))
                .font(.app(.caption, bold ? .bold : .semibold))
        }
    }

    // MARK: Defaults + save

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    private func configureDefaults() {
        // Returning from receipt capture must retain the in-progress form and upload ID.
        guard !hasConfiguredDraft, let trip else { return }
        hasConfiguredDraft = true
        showSplitConfiguration = startWithFullSplit
        draft = ExpenseDraft(
            trip: trip,
            currentUserID: store.currentUser.id,
            editing: editing,
            startWithFullSplit: startWithFullSplit,
            prefillTitle: prefillTitle,
            prefillAmount: prefillAmount,
            prefillLocation: prefillLocation
        )
        if let location = draft.expenseLocation {
            isSelectingLocation = true
            locationQuery = location.name
        }
    }

    @MainActor
    private func save() async {
        guard let trip else { return }

        // If a receipt photo was captured but its upload hasn't landed (still in flight,
        // or failed earlier), make one more attempt so the URL is attached before saving.
        // The expense is saved regardless — the photo is optional, the split data isn't.
        if let receiptImage, draft.receiptURL == nil {
            isSaving = true
            await uploadReceipt(receiptImage, originalData: nil)
            isSaving = false
        }

        guard let expense = draft.preparedExpense(for: trip, currentUserID: store.currentUser.id, editing: editing) else { return }
        if isEditing {
            store.updateExpense(expense, in: trip.id)
        } else {
            store.addExpense(expense, to: trip.id)
        }
        dismiss()
    }
}

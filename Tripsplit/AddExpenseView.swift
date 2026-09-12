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

    @State private var title = ""
    @State private var amountText = ""
    @State private var date = Date()
    @State private var locationQuery = ""
    @State private var expenseLocation: ExpenseLocation?
    @State private var isSelectingLocation = false
    @StateObject private var locationCompleter = StopPlaceCompleter()
    @FocusState private var locationFocused: Bool
    @FocusState private var focusedField: ExpenseField?

    private enum ExpenseField: Hashable { case title, amount }

    // Split configuration (mirrors the capstone's per-method split: equal/all,
    // equal/selected, single-payer, percentage, by-amount).
    @State private var method: SplitMethod = .equalAll
    @State private var selected: Set<Person.ID> = []
    @State private var noSplitAssignee: Person.ID?
    @State private var percentages: [Person.ID: Double] = [:]
    @State private var amounts: [Person.ID: Double] = [:]

    // Receipt scanning + upload.
    @State private var expenseID = UUID()
    @State private var receiptPick: PhotosPickerItem?
    @State private var receiptImage: UIImage?
    @State private var items: [ReceiptItem] = []
    @State private var receiptURL: String?
    @State private var isScanning = false
    @State private var isUploading = false
    @State private var usedRateLimitedReceiptFallback = false
    @State private var configuringIndex: Int?
    @State private var showCamera = false
    @State private var taxText = ""
    @State private var tipText = ""
    @State private var uploadError: String?
    @State private var showReceiptAIConsent = false
    @State private var pendingConsentReceipt: (image: UIImage, originalData: Data?)?
    @State private var isSaving = false
    @State private var showDetails = false
    @State private var showSplitConfiguration = false
    /// When false (default) the expense only covers the current user's share.
    /// Toggling true unlocks the full split-method picker and per-item configuration.
    @State private var payForOthers = false
    /// Who fronted the expense. `nil` falls back to the current user; the creator (or any
    /// invited member when the trip allows it) can switch this to another member.
    @State private var selectedPayerID: Person.ID?
    /// Removed items kept so a deletion can be undone (most-recent first).
    @State private var removedItems: [(item: ReceiptItem, index: Int)] = []
    /// The ruled amount numeral. Tied to `.largeTitle` so it still answers Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var ruledAmountSize: CGFloat = 60

    private var isEditing: Bool { editing != nil }
    private var trip: Trip? { store.trip(tripID) }
    private var isCreator: Bool { trip.map { store.isCreator(of: $0) } ?? false }

    private var total: Double { Double(amountText) ?? 0 }
    private var resolvedPayer: Person.ID { selectedPayerID ?? store.currentUser.id }

    /// The creator can always record an expense paid by another member; other (invited)
    /// members can only when the trip's `allowMembersToPayForOthers` permission is on.
    private var canChoosePayer: Bool {
        isCreator || (trip?.allowMembersToPayForOthers ?? false)
    }

    /// Live split computation, reused for validation, the per-person preview, and save.
    private func result(for trip: Trip) -> SplitResult {
        SplitEngine.calculate(
            total: total,
            method: method,
            people: trip.members,
            payer: resolvedPayer,
            selected: selected,
            noSplitAssignee: noSplitAssignee ?? resolvedPayer,
            percentages: percentages,
            amounts: amounts
        )
    }

    private func canSave(_ trip: Trip) -> Bool {
        if !items.isEmpty {
            return itemsTotal > 0 && allocatedShares(trip).valid
        }
        return total > 0 && result(for: trip).isValid
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
                            if items.isEmpty {
                                splitCard(trip)
                            }
                            receiptCard(trip)
                            if !items.isEmpty {
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
                    .disabled(!canSave(trip) || isSaving || isScanning || isUploading)
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
            .onChange(of: grandTotal) {
                if !items.isEmpty { amountText = formatted(grandTotal) }
            }
            .onChange(of: locationQuery) { _, newValue in
                if isSelectingLocation {
                    isSelectingLocation = false
                    return
                }
                expenseLocation = nil
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
                if let index = configuringIndex, items.indices.contains(index), let trip {
                    ItemSplitConfigView(
                        item: $items[index],
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
            } else if receiptURL != nil {
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

            if !items.isEmpty || !removedItems.isEmpty {
                itemsEditor(trip)
            } else if receiptImage != nil && !isScanning {
                Text("No items detected — enter the amount above.")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
            }

            // Quiet entry point into itemized mode without a scan: one tap adds a first
            // blank line and the editor (plus tax/tip and per-item splits) appears.
            if items.isEmpty && removedItems.isEmpty && !isScanning {
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

    private func receiptActionLabel(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(Theme.Typography.rowTitle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .fieldFill()
    }

    private func itemsEditor(_ trip: Trip) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Items (\(items.count))").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Total \(money(itemsTotal, trip.currencyCode))").font(.app(.caption, .semibold))
            }
            ForEach($items) { $item in
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

                if let last = removedItems.first {
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
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        removedItems.insert((item, index), at: 0)
        items.remove(at: index)
        amountText = formatted(grandTotal)
    }

    /// Restores the most recently removed item to its original position.
    private func undoRemove() {
        guard let restored = removedItems.first else { return }
        removedItems.removeFirst()
        let index = min(restored.index, items.count)
        items.insert(restored.item, at: index)
        amountText = formatted(grandTotal)
    }

    /// Appends a blank item the user can fill in for something the scan missed.
    private func addBlankItem(_ trip: Trip) {
        var item = ReceiptItem(name: "", price: 0)
        if payForOthers {
            item.splitMethod = .equalAll
            item.participantIDs = Set(trip.members.map(\.id))
        } else {
            item.splitMethod = .equalSelected
            item.participantIDs = [store.currentUser.id]
        }
        items.append(item)
    }

    private var itemsTotal: Double {
        SplitEngine.roundToTwo(items.reduce(0) { $0 + $1.price })
    }

    private var taxAmount: Double { max(0, Double(taxText) ?? 0) }
    private var tipAmount: Double { max(0, Double(tipText) ?? 0) }
    private var extras: Double { SplitEngine.roundToTwo(taxAmount + tipAmount) }
    /// Items subtotal plus tax and tip — the amount actually charged.
    private var grandTotal: Double { SplitEngine.roundToTwo(itemsTotal + extras) }

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
        receiptURL = nil
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
            removedItems = []
            let everyone = Set(store.trip(tripID)?.members.map(\.id) ?? [])
            items = scan.items.map { item in
                var configured = item
                if payForOthers {
                    configured.splitMethod = .equalAll
                    configured.participantIDs = everyone
                } else {
                    configured.splitMethod = .equalSelected
                    configured.participantIDs = [store.currentUser.id]
                }
                return configured
            }
            if let tax = scan.tax { taxText = formatted(tax) }
            if let tip = scan.tip { tipText = formatted(tip) }
            amountText = formatted(grandTotal)
        }

        // Upload in the background; the URL is attached on save (and the save path retries
        // if this hasn't finished or failed by the time the user taps Save).
        await uploadReceipt(image, originalData: originalData)
    }

    /// Uploads the current receipt image to Supabase Storage, recording the public URL on
    /// success or a user-facing reason on failure. Safe to call again to retry.
    @MainActor
    private func uploadReceipt(_ image: UIImage, originalData: Data?) async {
        guard receiptURL == nil else { return }
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
        let path = "\(store.currentUser.id.uuidString.lowercased())/\(expenseID.uuidString.lowercased()).jpg"
        isUploading = true
        uploadError = nil
        do {
            receiptURL = try await store.uploadReceipt(
                jpeg,
                path: path,
                tripID: tripID,
                expenseID: expenseID
            )
        } catch {
            uploadError = (error as? AuthError)?.message ?? "Receipt upload failed."
        }
        isUploading = false
    }

    // MARK: Amount + payer

    /// One row of the ruled field list: a tracked-caps label on the left, the current
    /// value (or its editable field) on the right, closed by a full-bleed rule. It
    /// replaces the card each of these fields had on the card themes.
    private func ruledFieldRow<Trailing: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label).inscription().foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 12)
                trailing()
            }
            .frame(minHeight: 46)
            RuledDivider()
        }
    }

    @ViewBuilder
    private func amountCard(_ trip: Trip) -> some View {
        if Theme.isRuled {
            ruledAmountCard(trip)
        } else {
            cardAmountCard(trip)
        }
    }

    /// The ruled amount block: the label carries the currency so the numeral row is
    /// nothing but the numeral, with title and date as ruled rows beneath it.
    private func ruledAmountCard(_ trip: Trip) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("Amount")
                    Text(verbatim: "·")
                    Text(verbatim: trip.currencyCode)
                }
                .inscription()
                .foregroundStyle(Theme.textSecondary)

                TextField("0.00", text: $amountText)
                    .font(.app(size: ruledAmountSize, weight: .medium))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .focused($focusedField, equals: .amount)
                    .disabled(!items.isEmpty)
                    .accessibilityLabel("Amount in \(trip.currencyCode)")

                if !items.isEmpty {
                    Text("Total is calculated from the items, tax, and tip below.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 18)

            ruledFieldRow("Title") {
                TextField("Dinner", text: $title)
                    .font(.app(.subheadline, .medium))
                    .multilineTextAlignment(.trailing)
                    .textContentType(.none)
                    .accessibilityIdentifier("expense-title")
                    .submitLabel(.next)
                    .focused($focusedField, equals: .title)
                    .onSubmit { focusedField = .amount }
            }

            ruledFieldRow("Date") {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }

    private func cardAmountCard(_ trip: Trip) -> some View {
        TripCard(title: "Expense", icon: "dollarsign.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Amount")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Text(trip.currencyCode).foregroundStyle(Theme.textSecondary)
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                        .disabled(!items.isEmpty)
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
                TextField("Dinner", text: $title)
                    .font(.app(.subheadline, .medium))
                    .textContentType(.none)
                    .accessibilityIdentifier("expense-title")
                    .submitLabel(.next)
                    .focused($focusedField, equals: .title)
                    .onSubmit { focusedField = .amount }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .fieldFill()
            }

            if !items.isEmpty {
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
        if Theme.isRuled {
            ruledPayerRow(trip)
        } else {
            cardPayerCard(trip)
        }
    }

    /// The payer picker as one ruled row: label left, current payer and a chevron
    /// right. The menu it presents is the same one the card themes open.
    private func ruledPayerRow(_ trip: Trip) -> some View {
        let payer = trip.members.first { $0.id == resolvedPayer } ?? store.currentUser
        let isMe = payer.id == store.currentUser.id
        return ruledFieldRow("Paid by") {
            if canChoosePayer {
                Menu {
                    payerMenuItems(trip)
                } label: {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(isMe ? "You" : payer.name))
                            .font(.app(.subheadline, .medium))
                        Image(systemName: "chevron.right")
                            .font(.app(.caption2, .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
            } else {
                Text(LocalizedStringKey(isMe ? "You" : payer.name))
                    .font(.app(.subheadline, .medium))
            }
        }
    }

    @ViewBuilder
    private func payerMenuItems(_ trip: Trip) -> some View {
        ForEach(trip.members) { member in
            Button {
                selectedPayerID = member.id
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
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .font(Theme.Typography.secondary)
                locationCard
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Date & location", systemImage: "calendar")
                    .font(Theme.Typography.rowTitle)
                Text([date.formatted(date: .abbreviated, time: .omitted),
                      expenseLocation?.name ?? locationQuery].filter { !$0.isEmpty }.joined(separator: " · "))
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
            if Theme.isRuled {
                ruledLocationRow
            } else {
                cardLocationCard
            }
        }

    }

    /// The location field as one ruled row, with the completer's suggestions listed
    /// bare beneath it instead of inside a filled card.
    private var ruledLocationRow: some View {
        VStack(spacing: 0) {
            ruledFieldRow("Location (optional)") {
                HStack(spacing: 8) {
                    TextField("Merchant or place", text: $locationQuery)
                        .font(.app(.subheadline, .medium))
                        .multilineTextAlignment(.trailing)
                        .focused($locationFocused)
                        .autocorrectionDisabled()
                    if !locationQuery.isEmpty {
                        Button {
                            locationQuery = ""
                            expenseLocation = nil
                            locationCompleter.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if locationFocused && !locationCompleter.suggestions.isEmpty {
                ForEach(Array(locationCompleter.suggestions.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                    Button { selectExpenseLocation(suggestion) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(Theme.Typography.rowTitle)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(Theme.Typography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    RuledDivider()
                }
            } else if let expenseLocation, let address = expenseLocation.address {
                Label(address, systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
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
                        expenseLocation = nil
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
            } else if let expenseLocation, let address = expenseLocation.address {
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
            expenseLocation = ExpenseLocation(
                name: item.name ?? suggestion.title,
                address: item.address?.fullAddress,
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude
            )
        }
    }

    // MARK: Split

    private func splitCard(_ trip: Trip) -> some View {
        let outcome = result(for: trip)
        return TripCard(title: "Split", icon: "divide.circle.fill") {
            DisclosureGroup(isExpanded: $showSplitConfiguration) {
                VStack(alignment: .leading, spacing: 14) {
                    payForOthersButton(trip)

                    if payForOthers {
                        Menu {
                            ForEach(SplitMethod.allCases) { option in
                                Button {
                                    method = option
                                    configureForMethod(trip)
                                } label: {
                                    Label(LocalizedStringKey(option.rawValue), systemImage: option.icon)
                                }
                            }
                        } label: {
                            HStack {
                                // The ruled style carries no icon chrome: the method reads as a
                                // value on a field row, not as a filled control.
                                if !Theme.isRuled { Image(systemName: method.icon) }
                                Text(LocalizedStringKey(method.rawValue)).font(Theme.Typography.rowTitle)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(Theme.Typography.metadata).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Theme.isRuled ? 0 : 14)
                            .padding(.vertical, Theme.isRuled ? 0 : 12)
                            .frame(minHeight: Theme.isRuled ? 46 : 0)
                            .background {
                                if !Theme.isRuled {
                                    RoundedRectangle(cornerRadius: 12).fill(Theme.fieldBackground)
                                }
                            }
                        }
                        if Theme.isRuled { RuledDivider() }

                        switch method {
                        case .equalAll:
                            Text("Split equally across all \(trip.members.count) member\(trip.members.count == 1 ? "" : "s").")
                                .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                        case .equalSelected:
                            memberToggleList(trip)
                        case .noSplit:
                            singlePayerList(trip)
                        case .percentage:
                            valueFields(trip, unit: "%", values: $percentages)
                        case .amount:
                            valueFields(trip, unit: currencySymbol(trip.currencyCode), values: $amounts)
                        }
                    }

                    sharePreview(trip, outcome)
                }
                .padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(payForOthers ? LocalizedStringKey(method.rawValue) : "Just me")
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
                payForOthers.toggle()
                if payForOthers {
                    method = .equalAll
                    configureForMethod(trip)
                    if !items.isEmpty {
                        let everyone = Set(trip.members.map(\.id))
                        items = items.map {
                            var u = $0
                            u.splitMethod = .equalAll
                            u.participantIDs = everyone
                            return u
                        }
                        amountText = formatted(grandTotal)
                    }
                } else {
                    method = .noSplit
                    noSplitAssignee = store.currentUser.id
                    if !items.isEmpty {
                        items = items.map {
                            var u = $0
                            u.splitMethod = .equalSelected
                            u.participantIDs = [store.currentUser.id]
                            return u
                        }
                        amountText = formatted(grandTotal)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: payForOthers ? "checkmark.square.fill" : "square")
                    .font(.app(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pay for others")
                        .font(Theme.Typography.rowTitle)
                    Text(payForOthers ? "Covering other members' expenses" : "Only covering your own share")
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
                if selected.contains(member.id) { selected.remove(member.id) }
                else { selected.insert(member.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected.contains(member.id) ? "checkmark.square.fill" : "square")
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
                noSplitAssignee = member.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: (noSplitAssignee ?? resolvedPayer) == member.id ? "largecircle.fill.circle" : "circle")
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

    private func chip(label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(selected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.accent : Theme.fieldBackground, in: .capsule)
    }

    // MARK: Per-item split

    /// Each scanned item carries its own split; the expense total per member is the sum
    /// of that member's share across every item. Mirrors the capstone's per-item model.
    private func perItemShares(_ trip: Trip) -> (shares: [Person.ID: Double], valid: Bool) {
        var totals: [Person.ID: Double] = [:]
        var valid = true
        for item in items {
            let outcome = SplitEngine.calculate(
                total: item.price,
                method: item.splitMethod,
                people: trip.members,
                payer: resolvedPayer,
                selected: item.participantIDs,
                noSplitAssignee: item.soloPayerID ?? resolvedPayer,
                percentages: item.percentages,
                amounts: item.amounts
            )
            if !outcome.isValid { valid = false }
            for (member, owed) in outcome.owed where owed > 0.005 {
                totals[member, default: 0] += owed
            }
        }
        return (totals.mapValues { SplitEngine.roundToTwo($0) }, valid)
    }

    /// Per-item shares with tax and tip allocated on top, proportional to each person's
    /// subtotal. The combined shares sum exactly to `grandTotal`.
    private func allocatedShares(_ trip: Trip) -> (shares: [Person.ID: Double], valid: Bool) {
        let base = perItemShares(trip)
        guard extras > 0.005 else { return base }

        let allocation = SplitEngine.allocateProportionally(extras, weights: base.shares)
        var combined = base.shares
        for (id, add) in allocation {
            combined[id] = SplitEngine.roundToTwo((combined[id] ?? 0) + add)
        }
        return (combined, base.valid)
    }

    @ViewBuilder
    private func taxTipCard(_ trip: Trip) -> some View {
        if Theme.isRuled {
            // Two ruled rows instead of a card: label left, amount field right.
            VStack(spacing: 0) {
                ruledFieldRow("Tax") { extraAmountField(trip, text: $taxText) }
                ruledFieldRow("Tip") { extraAmountField(trip, text: $tipText) }
                Text("Allocated across items by each person's subtotal.")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } else {
            TripCard(title: "Tax & tip", icon: "percent") {
                Text("Allocated across items by each person's subtotal.")
                    .font(Theme.Typography.metadata).foregroundStyle(.secondary)
                extraField(trip, title: "Tax", text: $taxText)
                extraField(trip, title: "Tip", text: $tipText)
            }
        }
    }

    private func extraAmountField(_ trip: Trip, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(currencySymbol(trip.currencyCode))
                .font(Theme.Typography.secondary).foregroundStyle(.secondary)
            TextField("0.00", text: text)
                .font(.app(.subheadline, .medium))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }

    private func extraField(_ trip: Trip, title: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.app(.subheadline, .medium))
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
        let outcome = allocatedShares(trip)
        return TripCard(title: "Item splits", icon: "list.bullet.indent") {
            payForOthersButton(trip)

            Text("Tap an item to choose how it's split.")
                .font(Theme.Typography.metadata).foregroundStyle(.secondary)

            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button {
                    if item.splitMethod == .equalSelected && item.participantIDs.isEmpty {
                        items[index].participantIDs = Set(trip.members.map(\.id))
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
            totalRow("Subtotal", itemsTotal, trip)
            if taxAmount > 0.005 { totalRow("Tax", taxAmount, trip) }
            if tipAmount > 0.005 { totalRow("Tip", tipAmount, trip) }
            totalRow("Total", grandTotal, trip, bold: true)

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

    /// Sets sensible defaults when switching split methods.
    private func configureForMethod(_ trip: Trip) {
        switch method {
        case .equalSelected:
            if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
        case .noSplit:
            if noSplitAssignee == nil { noSplitAssignee = resolvedPayer }
        default:
            break
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    private func configureDefaults() {
        guard let trip else { return }
        showSplitConfiguration = startWithFullSplit
        if let editing {
            expenseID = editing.id
            selectedPayerID = editing.payerID
            title = editing.title
            amountText = formatted(editing.amount)
            date = editing.date
            items = editing.items
            receiptURL = editing.receiptURL
            if let location = editing.location {
                expenseLocation = location
                isSelectingLocation = true
                locationQuery = location.name
            }
            selected = editing.participantIDs
            if editing.tax > 0 { taxText = formatted(editing.tax) }
            if editing.tip > 0 { tipText = formatted(editing.tip) }
            // Reconstruct an editable split from the stored per-member shares.
            if !editing.shares.isEmpty {
                method = .amount
                amounts = editing.shares
            }
            // Restore "pay for others" if anyone besides the current user was included.
            let me = store.currentUser.id
            payForOthers = editing.participantIDs.contains(where: { $0 != me })
                || editing.shares.keys.contains(where: { $0 != me })
            return
        }
        // Default: the user only covers their own share, paid by themselves. The
        // explicit Split Expense shortcut opts into the saved group-split flow.
        selectedPayerID = store.currentUser.id
        payForOthers = startWithFullSplit
        method = startWithFullSplit ? .equalAll : .noSplit
        noSplitAssignee = store.currentUser.id
        if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
        if let prefillTitle { title = prefillTitle }
        if let prefillAmount, prefillAmount > 0 { amountText = formatted(prefillAmount) }
        if let prefillLocation {
            expenseLocation = prefillLocation
            isSelectingLocation = true
            locationQuery = prefillLocation.name
        }
    }

    @MainActor
    private func save() async {
        guard let trip else { return }

        // If a receipt photo was captured but its upload hasn't landed (still in flight,
        // or failed earlier), make one more attempt so the URL is attached before saving.
        // The expense is saved regardless — the photo is optional, the split data isn't.
        if let receiptImage, receiptURL == nil {
            isSaving = true
            await uploadReceipt(receiptImage, originalData: nil)
            isSaving = false
        }

        // When the receipt has items, the total and split come from the per-item config;
        // otherwise they come from the single expense-level split.
        let amountToSave: Double
        let shares: [Person.ID: Double]
        if items.isEmpty {
            let outcome = result(for: trip)
            guard total > 0, outcome.isValid else { return }
            amountToSave = total
            shares = outcome.owed.filter { $0.value > 0.005 }
        } else {
            let outcome = allocatedShares(trip)
            guard itemsTotal > 0, outcome.valid else { return }
            amountToSave = grandTotal
            shares = outcome.shares.filter { $0.value > 0.005 }
        }

        let participantIDs = Set(shares.keys)
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Expense" : title
        // Tax/tip only apply to the per-item receipt flow.
        let savedTax = items.isEmpty ? 0 : taxAmount
        let savedTip = items.isEmpty ? 0 : tipAmount

        if let editing {
            var updated = editing
            updated.title = resolvedTitle
            updated.amount = amountToSave
            updated.payerID = resolvedPayer
            updated.participantIDs = participantIDs
            updated.date = date
            updated.shares = shares
            updated.items = items
            updated.receiptURL = receiptURL ?? editing.receiptURL
            updated.tax = savedTax
            updated.tip = savedTip
            updated.location = expenseLocation
            store.updateExpense(updated, in: trip.id)
        } else {
            let expense = Expense(
                id: expenseID,
                title: resolvedTitle,
                amount: amountToSave,
                payerID: resolvedPayer,
                participantIDs: participantIDs,
                date: date,
                shares: shares,
                receiptURL: receiptURL,
                items: items,
                tax: savedTax,
                tip: savedTip,
                location: expenseLocation
            )
            store.addExpense(expense, to: trip.id)
        }
        dismiss()
    }
}

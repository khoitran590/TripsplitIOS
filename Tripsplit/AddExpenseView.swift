import SwiftUI
import Observation
import Combine
import ImageIO
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

    @State private var title = ""
    @State private var amountText = ""
    @State private var date = Date()

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
    @State private var isSaving = false
    /// When false (default) the expense only covers the current user's share.
    /// Toggling true unlocks the full split-method picker and per-item configuration.
    @State private var payForOthers = false
    /// Who fronted the expense. `nil` falls back to the current user; the creator (or any
    /// invited member when the trip allows it) can switch this to another member.
    @State private var selectedPayerID: Person.ID?
    /// Removed items kept so a deletion can be undone (most-recent first).
    @State private var removedItems: [(item: ReceiptItem, index: Int)] = []

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
                        VStack(spacing: 18) {
                            if !isEditing {
                                OneTimeTipBanner(
                                    key: "tipScanReceiptDismissed",
                                    icon: "doc.text.viewfinder",
                                    message: "Skip the typing: scan the receipt with the Camera button below and the items, tax, and tip fill in automatically."
                                )
                            }
                            amountCard(trip)
                            payerCard(trip)
                            receiptCard(trip)
                            if items.isEmpty {
                                splitCard(trip)
                            } else {
                                taxTipCard(trip)
                                itemSplitsCard(trip)
                            }
                        }
                        .padding()
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Expense" : "Add Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!(trip.map(canSave) ?? false))
                    }
                }
            }
            .onAppear(perform: configureDefaults)
            // In itemized mode the expense total is item prices + tax + tip; keep the
            // amount field in lockstep instead of asking the user to copy it over.
            .onChange(of: grandTotal) {
                if !items.isEmpty { amountText = formatted(grandTotal) }
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
        }
    }

    // MARK: Receipt

    private func receiptCard(_ trip: Trip) -> some View {
        TripCard(title: "Receipt & Items", icon: "doc.text.viewfinder") {
            if receiptImage == nil && items.isEmpty && removedItems.isEmpty {
                Text("Scan a receipt to fill in the items and total for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                        receiptActionLabel(icon: "camera.fill", title: "Camera")
                    }
                    .buttonStyle(.plain)
                }

                PhotosPicker(selection: $receiptPick, matching: .images) {
                    receiptActionLabel(
                        icon: receiptImage == nil ? "photo.on.rectangle" : "arrow.triangle.2.circlepath",
                        title: receiptImage == nil ? "Library" : "Replace"
                    )
                }
                .buttonStyle(.plain)
            }

            if isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                }
            } else if isUploading {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let uploadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(uploadError, systemImage: "exclamationmark.icloud.fill")
                        .font(.caption).foregroundStyle(Theme.negative)
                    if let receiptImage {
                        Button("Retry upload") {
                            Task { await uploadReceipt(receiptImage, originalData: nil) }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                    }
                }
            } else if receiptURL != nil {
                Label("Receipt photo saved", systemImage: "checkmark.icloud.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if usedRateLimitedReceiptFallback && !isScanning {
                Label(
                    "Using offline scan — AI limit reached. Try again shortly.",
                    systemImage: "bolt.slash.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("receipt-rate-limit-fallback")
            }

            if !items.isEmpty || !removedItems.isEmpty {
                itemsEditor(trip)
            } else if receiptImage != nil && !isScanning {
                Text("No items detected — enter the amount manually below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Quiet entry point into itemized mode without a scan: one tap adds a first
            // blank line and the editor (plus tax/tip and per-item splits) appears.
            if items.isEmpty && removedItems.isEmpty && !isScanning {
                Button {
                    withAnimation(.snappy) { addBlankItem(trip) }
                } label: {
                    Label("Or add items manually", systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func receiptActionLabel(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
    }

    private func itemsEditor(_ trip: Trip) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Items (\(items.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Total \(money(itemsTotal, trip.currencyCode))").font(.caption.weight(.semibold))
            }
            ForEach($items) { $item in
                HStack(spacing: 8) {
                    TextField("Item", text: $item.name)
                        .font(.subheadline)
                    Spacer(minLength: 6)
                    Text(currencySymbol(trip.currencyCode)).font(.subheadline).foregroundStyle(.secondary)
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
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
            }

            HStack {
                Button {
                    addBlankItem(trip)
                } label: {
                    Label("Add item", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                if let last = removedItems.first {
                    Button {
                        undoRemove()
                    } label: {
                        Label("Undo \"\(last.item.name)\"", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
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
        receiptImage = image

        // A freshly picked/replaced photo invalidates the previous scan and upload. Clear
        // the old upload state so the scanning process starts over AND the new image
        // actually re-uploads — the upload guard (`receiptURL == nil`) otherwise skips the
        // upload whenever a URL was already set, silently persisting the previous photo.
        receiptURL = nil
        uploadError = nil
        usedRateLimitedReceiptFallback = false

        isScanning = true
        let scan = await ReceiptScanner.scan(image, accessToken: store.accessToken)
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
            receiptURL = try await store.uploadReceipt(jpeg, path: path)
        } catch {
            uploadError = (error as? AuthError)?.message ?? "Receipt upload failed."
        }
        isUploading = false
    }

    // MARK: Amount + payer

    private func amountCard(_ trip: Trip) -> some View {
        TripCard(title: "Expense", icon: "dollarsign.circle.fill") {
            TextField("Title (e.g. Dinner)", text: $title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            HStack(spacing: 2) {
                Text(currencySymbol(trip.currencyCode)).foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .disabled(!items.isEmpty)
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            if !items.isEmpty {
                Text("Total is calculated from the items, tax, and tip below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DatePicker("Date", selection: $date, displayedComponents: .date)
                .font(.subheadline)
        }
    }

    private func payerCard(_ trip: Trip) -> some View {
        let payer = trip.members.first { $0.id == resolvedPayer } ?? store.currentUser
        let isMe = payer.id == store.currentUser.id
        return TripCard(title: "Paid by", icon: "creditcard.fill") {
            if canChoosePayer {
                Menu {
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
                } label: {
                    HStack(spacing: 10) {
                        avatar(payer, size: 30)
                        Text(LocalizedStringKey(isMe ? "You" : payer.name)).font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                }
            } else {
                HStack {
                    avatar(payer, size: 30)
                    Text(LocalizedStringKey(isMe ? "You" : payer.name)).font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
        }
    }

    // MARK: Split

    private func splitCard(_ trip: Trip) -> some View {
        let outcome = result(for: trip)
        return TripCard(title: "Split", icon: "divide.circle.fill") {
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
                        Image(systemName: method.icon)
                        Text(LocalizedStringKey(method.rawValue)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                }

                switch method {
                case .equalAll:
                    Text("Split equally across all \(trip.members.count) member\(trip.members.count == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.secondary)
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

            if let message = outcome.message, !outcome.isValid {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.negative)
            }

            sharePreview(trip, outcome)
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
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pay for others")
                        .font(.subheadline.weight(.semibold))
                    Text(payForOthers ? "Covering other members' expenses" : "Only covering your own share")
                        .font(.caption).foregroundStyle(.secondary)
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
                        .font(.subheadline.weight(.medium))
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
                        .font(.subheadline.weight(.medium))
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
                    .font(.subheadline.weight(.medium))
                Spacer()
                TextField("0", value: Binding(
                    get: { values.wrappedValue[member.id] ?? 0 },
                    set: { values.wrappedValue[member.id] = $0 }
                ), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
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
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func chip(label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(color).interactive() : .regular.interactive(), in: .capsule)
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

    private func taxTipCard(_ trip: Trip) -> some View {
        TripCard(title: "Tax & tip", icon: "percent") {
            Text("Allocated across items by each person's subtotal.")
                .font(.caption).foregroundStyle(.secondary)
            extraField(trip, title: "Tax", text: $taxText)
            extraField(trip, title: "Tip", text: $tipText)
        }
    }

    private func extraField(_ trip: Trip, title: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(currencySymbol(trip.currencyCode)).font(.subheadline).foregroundStyle(.secondary)
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
        }
    }

    private func itemSplitsCard(_ trip: Trip) -> some View {
        let outcome = allocatedShares(trip)
        return TripCard(title: "Item splits", icon: "list.bullet.indent") {
            payForOthersButton(trip)

            Text("Tap an item to choose how it's split.")
                .font(.caption).foregroundStyle(.secondary)

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
                            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Label(LocalizedStringKey(item.splitMethod.rawValue), systemImage: item.splitMethod.icon)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(money(item.price, trip.currencyCode)).font(.subheadline.weight(.semibold))
                        Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent)
                    }
                    .contentShape(.rect)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            if !outcome.valid {
                Label("Some items still need a valid split.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.negative)
            }

            Divider()
            totalRow("Subtotal", itemsTotal, trip)
            if taxAmount > 0.005 { totalRow("Tax", taxAmount, trip) }
            if tipAmount > 0.005 { totalRow("Tip", tipAmount, trip) }
            totalRow("Total", grandTotal, trip, bold: true)

            Divider()
            Text("Each person owes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(trip.members) { member in
                let owed = outcome.shares[member.id] ?? 0
                if owed > 0.005 {
                    HStack {
                        Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(owed, trip.currencyCode)).font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func totalRow(_ label: LocalizedStringKey, _ value: Double, _ trip: Trip, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(bold ? .caption.weight(.bold) : .caption)
                .foregroundStyle(bold ? .primary : .secondary)
            Spacer()
            Text(money(value, trip.currencyCode))
                .font(.caption.weight(bold ? .bold : .semibold))
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
        if let editing {
            expenseID = editing.id
            selectedPayerID = editing.payerID
            title = editing.title
            amountText = formatted(editing.amount)
            date = editing.date
            items = editing.items
            receiptURL = editing.receiptURL
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
        // Default: the user only covers their own share, paid by themselves.
        selectedPayerID = store.currentUser.id
        payForOthers = false
        method = .noSplit
        noSplitAssignee = store.currentUser.id
        if selected.isEmpty { selected = Set(trip.members.map(\.id)) }
        if let prefillTitle { title = prefillTitle }
        if let prefillAmount, prefillAmount > 0 { amountText = formatted(prefillAmount) }
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
                tip: savedTip
            )
            store.addExpense(expense, to: trip.id)
        }
        dismiss()
    }
}

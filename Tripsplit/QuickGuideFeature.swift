import SwiftUI

/// Targets shared by the manual guide and the returning-user refresher.
enum QuickGuideAction: Equatable {
    case createTrip, openTrip, addExpense, members, balances, practice
}

enum QuickGuideTopic: String, CaseIterable, Identifiable {
    case trips, expenses, balances
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .trips: "Create or join a trip"
        case .expenses: "Add and split an expense"
        case .balances: "Understand balances and repay"
        }
    }
    var icon: String {
        switch self {
        case .trips: "person.2"
        case .expenses: "doc.viewfinder"
        case .balances: "arrow.left.arrow.right"
        }
    }
    var navigationTitle: LocalizedStringKey {
        switch self {
        case .trips: "Trips"
        case .expenses: "Expenses"
        case .balances: "Balances"
        }
    }
}

struct QuickGuideView: View {
    var hasTrip = false
    var canCreateTrip = false
    var onAction: ((QuickGuideAction) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var openedAt = Date()
    @State private var topicOpenedAt = Date()
    @State private var activeTopic: QuickGuideTopic?
    @State private var reviewedTopics: Set<QuickGuideTopic> = []
    @State private var didTakeAction = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick a task for a quick refresher. You can return to this guide anytime.")
                    ForEach(QuickGuideTopic.allCases) { topic in
                        NavigationLink {
                            topicPage(topic)
                        } label: {
                            Label(topic.title, systemImage: topic.icon)
                                .padding(.vertical, 6)
                        }
                    }
                }
                if let onAction {
                    Section {
                        Button("Try a practice trip") { recordAction(.practice); onAction(.practice) }
                            .frame(minHeight: 44)
                    } footer: {
                        Text("Practice uses sample data. It does not change your account or send payments.")
                    }
                }
            }
            .navigationTitle("Quick guide")
            .toolbar { closeToolbar }
            .accessibilityIdentifier("quick-guide")
        }
        .onAppear {
            openedAt = Date()
            OnboardingAnalytics.shared.record(.guideOpened, source: .guide)
        }
        .onDisappear {
            if !didTakeAction { OnboardingAnalytics.shared.record(.guideDismissed, source: .guide, topic: activeTopic?.rawValue, elapsed: Date().timeIntervalSince(openedAt)) }
        }
    }

    private func topicPage(_ topic: QuickGuideTopic) -> some View {
        List {
            switch topic {
            case .trips:
                Section("Start a trip") {
                    Text("Create a trip with a name and currency. Dates, a budget, and a photo can be added later.")
                    if canCreateTrip { action("Create a trip", .createTrip) }
                }
                Section("Bring your tripmates") {
                    Text("Open Members & invitations in your trip to invite people to their accounts. Adding a name alone creates a participant for splitting; it does not send an invitation.")
                    if hasTrip { action("Open members & invitations", .members) }
                }
                Section("Join a friend's trip") {
                    Text("Open the invitation link your friend shared, sign in or create an account, then confirm Join Trip. You will land in that trip.")
                }
            case .expenses:
                Section("Who paid?") {
                    Text("Choose Add expense in your trip. Enter what it was for, the amount, and the person who paid. To share the cost, enable Pay for others and choose the participants.")
                }
                Section("Scan and review") {
                    Text("Scan a receipt or choose a photo, then review the items, tax, tip, and total. You can use on-device scanning or choose cloud assistance when asked. Correct anything the scan missed.")
                }
                Section("Choose who shares it") {
                    Text("Split equally, select participants, enter exact amounts or percentages, or assign each receipt item. Check the per-person preview before saving.")
                    if hasTrip { action("Add an expense", .addExpense) }
                    else if canCreateTrip { action("Create a trip first", .createTrip) }
                }
            case .balances:
                Section("Read your balance") {
                    Text("You owe is money you need to repay. You're owed is money others need to repay you. These can both be nonzero, even if your net balance is zero.")
                    Text("Home totals use your chosen home currency. Each trip keeps its own currency. If rates are unavailable, check that trip's native balance.")
                }
                Section("Record a repayment") {
                    Text("Open a suggested payment in the trip's balances. Pay your tripmate outside TripSplit, then record the amount and method. TripSplit records payments; it does not transfer money.")
                    Text("Recorded payments are pending until confirmed. Only confirmed payments reduce the remaining debt. Check the payment history if the balance has not changed.")
                    if hasTrip { action("View balances", .balances) }
                }
            }
            Section {
                Button(reviewedTopics.contains(topic) ? "Task reviewed" : "I've reviewed this task") {
                    reviewedTopics.insert(topic)
                    OnboardingAnalytics.shared.record(.guideTopicCompleted, source: .guide, topic: topic.rawValue, elapsed: Date().timeIntervalSince(topicOpenedAt))
                }
                .disabled(reviewedTopics.contains(topic))
                .frame(minHeight: 44)
            }
        }
        .onAppear {
            activeTopic = topic
            topicOpenedAt = Date()
            OnboardingAnalytics.shared.record(.guideTopicOpened, source: .guide, topic: topic.rawValue)
        }
        .navigationTitle(topic.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeToolbar }
    }

    @ToolbarContentBuilder private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }

    private func recordAction(_ action: QuickGuideAction) {
        didTakeAction = true
        OnboardingAnalytics.shared.record(.guideAction, source: .guide, topic: String(describing: action))
    }

    @ViewBuilder private func action(_ title: LocalizedStringKey, _ action: QuickGuideAction) -> some View {
        if let onAction {
            Button(title) { recordAction(action); onAction(action) }.frame(minHeight: 44)
        }
    }
}

/// Presents each action only after the guide has actually dismissed. Practice
/// owns value data only; the real store is never injected into that experience.
private struct QuickGuidePresentation: ViewModifier {
    @Binding var isPresented: Bool
    var tripID: Trip.ID?
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(OnboardingCoordinator.self) private var onboarding
    @State private var pendingAction: QuickGuideAction?
    @State private var showCreate = false
    @State private var showPractice = false
    @State private var destination: GuideTripDestination?
    @State private var createdTripID: Trip.ID?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in if presented { onboarding.guideOpened() } }
            .sheet(isPresented: $isPresented, onDismiss: routeAction) {
                QuickGuideView(
                    hasTrip: tripID != nil || !store.myTrips.isEmpty,
                    canCreateTrip: auth.isAuthenticated,
                    onAction: { action in pendingAction = action; isPresented = false }
                )
            }
            .sheet(isPresented: $showPractice) { PracticeTripView() }
            .sheet(isPresented: $showCreate, onDismiss: {
                if let id = createdTripID {
                    createdTripID = nil
                    destination = GuideTripDestination(id: id, action: .openTrip)
                }
            }) {
                AddTripView { createdTripID = $0.id }
            }
            .sheet(item: $destination) { target in
                if target.action == .addExpense { AddExpenseView(tripID: target.id) }
                else { TripDetailView(tripID: target.id, initialGuideAction: target.action) }
            }
    }

    private func routeAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .practice: showPractice = true
        case .createTrip: showCreate = auth.isAuthenticated
        default:
            if let id = tripID ?? store.recommendedTrip?.id {
                destination = GuideTripDestination(id: id, action: action)
            }
        }
    }
}

struct GuideTripDestination: Identifiable {
    let id: Trip.ID
    var action: QuickGuideAction = .openTrip
}

extension View {
    func quickGuide(isPresented: Binding<Bool>, tripID: Trip.ID? = nil) -> some View {
        modifier(QuickGuidePresentation(isPresented: isPresented, tripID: tripID))
    }
}

struct FirstTripChecklist: View {
    let trip: Trip
    let userID: Person.ID
    var onMembers: () -> Void
    var onExpense: () -> Void
    var onBalances: () -> Void
    @AppStorage private var visible: Bool

    static func key(userID: Person.ID, tripID: Trip.ID) -> String {
        "tripsplit.firstExpense.\(userID.uuidString.lowercased()).\(tripID.uuidString.lowercased())"
    }

    init(trip: Trip, userID: Person.ID, onMembers: @escaping () -> Void,
         onExpense: @escaping () -> Void, onBalances: @escaping () -> Void) {
        self.trip = trip
        self.userID = userID
        self.onMembers = onMembers
        self.onExpense = onExpense
        self.onBalances = onBalances
        _visible = AppStorage(wrappedValue: false, Self.key(userID: userID, tripID: trip.id))
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your first shared expense")
                        .font(.app(.headline)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { visible = false } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Dismiss setup checklist")
                }
                Button(action: onMembers) {
                    Label(trip.members.count > 1 ? "Tripmates added — manage invitations" : "Add or invite tripmates",
                          systemImage: trip.members.count > 1 ? "checkmark.circle" : "person.badge.plus")
                }.frame(minHeight: 44)
                Button(action: onExpense) {
                    Label(trip.expenses.isEmpty ? "Add your first expense" : "Expense saved — add another",
                          systemImage: trip.expenses.isEmpty ? "plus.circle" : "checkmark.circle")
                }.frame(minHeight: 44)
                if !trip.expenses.isEmpty {
                    Button {
                        visible = false
                        onBalances()
                    } label: { Label("See who owes what", systemImage: "arrow.left.arrow.right") }
                        .frame(minHeight: 44)
                }
            }
            .font(.app(.subheadline))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("first-expense-checklist")
        }
    }
}

import SwiftUI
import LocalAuthentication
import ShoeboxCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .loading:
                Color.screenBackground.ignoresSafeArea()
            case .failed(let message, let isNewerVersion):
                RecoveryView(message: message, isNewerVersion: isNewerVersion)
            case .ready:
                if model.hasOnboarded {
                    MainTabs()
                } else {
                    OnboardingView()
                        .transition(.opacity)
                }
            }
            if model.isLocked {
                LockView()
                    .transition(.opacity)
                    .zIndex(2)
            } else if scenePhase != .active, model.requiresUnlock {
                // Keeps balances out of the app switcher.
                PrivacyCover()
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.hasOnboarded)
        .animation(.easeInOut(duration: 0.2), value: model.isLocked)
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .sheet(item: $model.sheet, onDismiss: { model.flushQueuedDrafts() }) { sheet in
            switch sheet {
            case .newExpense(let drafts):
                ExpenseEditor(mode: .new(drafts: drafts))
            case .editExpense(let id):
                ExpenseEditor(mode: .edit(id))
            case .newWithdrawal(let expenseID):
                WithdrawalEditor(mode: .new(expenseID: expenseID))
            case .editWithdrawal(let id):
                WithdrawalEditor(mode: .edit(id))
            }
        }
        .documentCapture(source: $model.capture) { drafts in
            model.receive(drafts)
        }
        .onChange(of: model.isLocked) { _, locked in
            if !locked { model.flushQueuedDrafts() }
        }
        .onChange(of: model.hasOnboarded) { _, done in
            if done { model.flushQueuedDrafts() }
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Summary", systemImage: "chart.pie.fill", value: AppTab.summary) {
                SummaryView()
            }
            Tab("Expenses", systemImage: "list.bullet.rectangle.portrait.fill", value: AppTab.expenses) {
                ExpensesView()
            }
            Tab("Withdrawals", systemImage: "arrow.down.to.line.circle.fill", value: AppTab.withdrawals) {
                WithdrawalsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
    }
}

/// The "add" control used in navigation bars: one tap opens every way to file an expense.
struct AddExpenseMenu<LabelContent: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var label: LabelContent

    var body: some View {
        Menu {
            CaptureMenuItems { model.capture = $0 }
            Divider()
            Button { model.sheet = .newExpense(drafts: []) } label: { Label("Enter manually", systemImage: "square.and.pencil") }
        } label: {
            label
        }
        .accessibilityLabel("Add expense")
        .accessibilityIdentifier("add-expense")
    }
}

struct BannerView: View {
    var banner: Banner

    var body: some View {
        Label(banner.text, systemImage: banner.style == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(banner.style == .success ? Color.brand : Color.attention)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Lock

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.brand)
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.screenBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 96, height: 96)
                    .background(Color.brandSoft, in: Circle())
                Text("Shoebox is locked")
                    .font(.title2.weight(.semibold))
                if failed {
                    Text("Couldn't confirm it's you. Try again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Unlock") { unlock() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
            .padding(32)
        }
        .onAppear { if scenePhase == .active { unlock() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { unlock() }
        }
    }

    private func unlock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on the device: there is nothing to check against, so do not lock the user out.
            model.isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your HSA records") { success, _ in
            Task { @MainActor in
                if success {
                    model.isLocked = false
                    failed = false
                } else {
                    failed = true
                }
            }
        }
    }
}

// MARK: - Recovery

/// Shown when the ledger cannot be opened. Nothing is written from this screen except an explicit restore.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    var message: String
    var isNewerVersion: Bool
    @State private var confirming: ArchiveStore.Backup?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Color.attention)
                        Text(isNewerVersion ? "Update needed" : "Your ledger couldn't be opened")
                            .font(.title2.weight(.bold))
                        Text(message)
                            .foregroundStyle(.secondary)
                        Text("Your documents are untouched. Nothing has been changed or deleted.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                if !isNewerVersion {
                    let backups = model.store.backups()
                    Section {
                        if backups.isEmpty {
                            Text("No daily copies were found.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(backups.prefix(14)) { backup in
                            Button {
                                confirming = backup
                            } label: {
                                LabeledContent(Format.dayLong(backup.day)) {
                                    Text("Restore")
                                }
                            }
                        }
                    } header: {
                        Text("Daily copies")
                    } footer: {
                        Text("Shoebox keeps a copy of the ledger for each day it changed. Restoring one keeps the damaged file alongside it.")
                    }
                }
                Section {
                    Button("Try again") { model.load() }
                }
            }
            .navigationTitle("Shoebox")
            .confirmationDialog("Restore this copy?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                Button("Restore") {
                    if let confirming { model.restore(confirming) }
                    confirming = nil
                }
            } message: {
                Text("Changes made after that day will not be in the restored ledger.")
            }
        }
    }
}

import SwiftUI
import ShoeboxCore

@main
struct ShoeboxApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = State(initialValue: Launch.makeModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.brand)
                .onOpenURL { url in
                    model.receive(fileAt: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background, model.requiresUnlock {
                        model.isLocked = true
                    }
                }
        }
    }
}

/// Launch arguments used for screenshots and UI checks. `-demo` swaps in a throwaway sample archive,
/// so the real one is never touched.
enum Launch {
    static let arguments = ProcessInfo.processInfo.arguments

    static var isDemo: Bool { arguments.contains("-demo") }
    static var startEmpty: Bool { arguments.contains("-empty") }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func makeModel() -> AppModel {
        guard isDemo else {
            let model = AppModel.live()
            model.load()
            return model
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShoeboxDemo-\(UUID().uuidString)", isDirectory: true)
        let store = ArchiveStore(root: root)
        if !startEmpty {
            let ledger = DemoData.ledger(today: .today(), store: store) { expense, kind in
                (Reports.sampleDocument(for: expense, kind: kind), "pdf")
            }
            try? store.save(ledger)
        }
        let model = AppModel(store: store, isDemo: true)
        model.load()
        if arguments.contains("-onboarding") { model.hasOnboarded = false }
        if let raw = value(after: "-tab"), let index = Int(raw), let tab = AppTab(rawValue: index) {
            model.tab = tab
        }
        let sorted = model.ledger.expenses.sorted { $0.serviceDate > $1.serviceDate }
        switch value(after: "-screen") {
        case "expense":
            if let expense = sorted.first(where: { !$0.attachments.isEmpty && model.ledger.status(of: $0) == .unreimbursed }) {
                model.tab = .expenses
                model.expensePath = [ExpenseRoute(id: expense.id)]
            }
        case "add":
            let sample = sorted.first.map { Reports.sampleDocument(for: $0, kind: .receipt) }
            let drafts = sample.map { [DraftDocument(data: $0, fileExtension: "pdf", originalName: "Scan.pdf", kind: .receipt,
                                                     thumbnail: Thumbnailer.thumbnail(forPDF: $0, side: 240))] } ?? []
            model.sheet = .newExpense(drafts: drafts)
        case "withdraw":
            model.tab = .withdrawals
            model.sheet = .newWithdrawal(expenseID: nil)
        case "withdrawal":
            if let withdrawal = model.ledger.withdrawals.sorted(by: { $0.date > $1.date }).first {
                model.tab = .withdrawals
                model.withdrawalPath.append(WithdrawalRoute(id: withdrawal.id))
            }
        default:
            break
        }
        return model
    }
}

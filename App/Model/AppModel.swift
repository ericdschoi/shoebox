import SwiftUI
import UIKit
import ShoeboxCore

/// Sheets the app can present from anywhere.
enum ActiveSheet: Identifiable {
    case newExpense(drafts: [DraftDocument])
    case editExpense(UUID)
    case newWithdrawal(expenseID: UUID?)
    case editWithdrawal(UUID)

    var id: String {
        switch self {
        case .newExpense: return "new-expense"
        case .editExpense(let id): return "edit-expense-\(id)"
        case .newWithdrawal(let id): return "new-withdrawal-\(id?.uuidString ?? "any")"
        case .editWithdrawal(let id): return "edit-withdrawal-\(id)"
        }
    }
}

struct ExpenseRoute: Hashable {
    let id: UUID
}

enum SettingsRoute: Hashable {
    case established, people, backup, integrity, howItWorks
}

enum AppTab: Int, Hashable {
    case summary, expenses, withdrawals, settings
}

struct Banner: Identifiable, Equatable {
    enum Style { case success, warning }
    let id = UUID()
    var text: String
    var style: Style = .success
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// The ledger could not be opened. Nothing is written while in this state.
        case failed(message: String, isNewerVersion: Bool)
    }

    private enum Keys {
        static let onboarded = "hasOnboarded"
        static let requiresUnlock = "requiresUnlock"
        static let mirrorBookmark = "mirrorBookmark"
        static let mirrorName = "mirrorName"
        static let mirrorDate = "mirrorDate"
        static let tabBarWhenOpen = "tabBarWhenOpen"
    }

    private(set) var phase: Phase = .loading
    private(set) var ledger = Ledger()
    let store: ArchiveStore
    let isDemo: Bool
    private let defaults: UserDefaults

    var tab: AppTab = .summary
    var sheet: ActiveSheet?
    var capture: CaptureSource?
    var banner: Banner?
    /// The expense shown beside the list when open, or pushed over it when closed.
    var selectedExpenseID: UUID?
    /// The withdrawal shown beside the list when open, or pushed over it when closed.
    var selectedWithdrawalID: UUID?
    /// Expenses opened from the selected withdrawal.
    var withdrawalDetailPath: [ExpenseRoute] = []
    var settingsPath: [SettingsRoute] = []

    var hasOnboarded: Bool { didSet { if !isDemo { defaults.set(hasOnboarded, forKey: Keys.onboarded) } } }
    var requiresUnlock: Bool { didSet { if !isDemo { defaults.set(requiresUnlock, forKey: Keys.requiresUnlock) } } }
    var isLocked = false
    /// When open on iPhone Duo, tabs sit in a sidebar. Stored inverted so the sidebar is the default.
    var usesTabSidebar: Bool { didSet { if !isDemo { defaults.set(!usesTabSidebar, forKey: Keys.tabBarWhenOpen) } } }

    // Backup folder
    enum MirrorState: Equatable {
        case idle
        case running
        case failed(String)
    }
    private(set) var mirrorName: String?
    private(set) var mirrorDate: Date?
    private(set) var mirrorState: MirrorState = .idle
    private var mirrorTask: Task<Void, Never>?

    /// Documents waiting for the app to be unlocked and ready before they can be filed.
    private var queuedDrafts: [DraftDocument] = []

    init(store: ArchiveStore, isDemo: Bool, defaults: UserDefaults = .standard) {
        self.store = store
        self.isDemo = isDemo
        self.defaults = defaults
        let lock = isDemo ? false : defaults.bool(forKey: Keys.requiresUnlock)
        self.hasOnboarded = isDemo ? true : defaults.bool(forKey: Keys.onboarded)
        self.requiresUnlock = lock
        self.usesTabSidebar = isDemo ? true : !defaults.bool(forKey: Keys.tabBarWhenOpen)
        self.mirrorName = isDemo ? nil : defaults.string(forKey: Keys.mirrorName)
        self.mirrorDate = isDemo ? nil : defaults.object(forKey: Keys.mirrorDate) as? Date
        self.isLocked = lock
    }

    /// The real archive lives in the app's Documents folder, which the Files app shows as "Shoebox".
    static func live() -> AppModel {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return AppModel(store: ArchiveStore(root: documents), isDemo: false)
    }

    // MARK: Loading

    func load() {
        do {
            ledger = try store.loadLedger()
            phase = .ready
            flushQueuedDrafts()
        } catch let error as ArchiveStore.StoreError {
            if case .newerSchema = error {
                phase = .failed(message: error.localizedDescription, isNewerVersion: true)
            } else {
                phase = .failed(message: error.localizedDescription, isNewerVersion: false)
            }
        } catch {
            phase = .failed(message: error.localizedDescription, isNewerVersion: false)
        }
    }

    func restore(_ backup: ArchiveStore.Backup) {
        do {
            ledger = try store.restore(backup)
            phase = .ready
            show("Restored the copy from \(Format.day(backup.day))")
        } catch {
            show("That copy could not be opened", style: .warning)
        }
    }

    // MARK: Saving

    /// Applies a change and writes it to disk before returning. If the write fails the change is
    /// rolled back, so what is on screen always matches what is in the archive.
    @discardableResult
    private func commit(_ change: (inout Ledger) throws -> Void) -> Bool {
        guard phase == .ready else { return false }
        var next = ledger
        do {
            try change(&next)
            try store.save(next)
            ledger = next
            scheduleMirror()
            return true
        } catch {
            show((error as? LocalizedError)?.errorDescription ?? "Couldn't save. Check that there is free space.", style: .warning)
            Haptics.warning()
            return false
        }
    }

    // MARK: Expenses

    /// Saves an expense, filing any new documents under names built from its final details.
    @discardableResult
    func save(_ expense: Expense, adding drafts: [DraftDocument], removing removed: [Attachment] = []) -> Bool {
        var expense = expense
        var stored: [Attachment] = []
        do {
            for draft in drafts {
                let attachment = try store.storeDocument(draft.data, kind: draft.kind, originalName: draft.originalName,
                                                         fileExtension: draft.fileExtension, serviceDate: expense.serviceDate,
                                                         provider: expense.displayProvider, amountCents: expense.amountCents)
                stored.append(attachment)
            }
        } catch {
            store.setAside(stored)
            show("Couldn't save the document. Check that there is free space.", style: .warning)
            return false
        }
        expense.attachments.append(contentsOf: stored)
        let ok = commit { $0.save(expense) }
        if ok {
            store.setAside(removed)
        } else {
            store.setAside(stored)
        }
        return ok
    }

    func setKind(_ kind: AttachmentKind, for attachmentID: UUID, in expenseID: UUID) {
        guard var expense = ledger.expense(expenseID),
              let index = expense.attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        expense.attachments[index].kind = kind
        commit { $0.save(expense) }
    }

    func removeAttachment(_ attachmentID: UUID, from expenseID: UUID) {
        guard var expense = ledger.expense(expenseID),
              let index = expense.attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        let removed = expense.attachments.remove(at: index)
        if commit({ $0.save(expense) }) {
            store.setAside([removed])
        }
    }

    func setInsuranceNotInvolved(_ value: Bool, for expenseID: UUID) {
        guard var expense = ledger.expense(expenseID) else { return }
        expense.insuranceNotInvolved = value
        commit { $0.save(expense) }
    }

    func deleteExpense(_ id: UUID) {
        var attachments: [Attachment] = []
        if commit({ attachments = $0.deleteExpense(id) }) {
            if selectedExpenseID == id { selectedExpenseID = nil }
            withdrawalDetailPath.removeAll { $0.id == id }
            store.setAside(attachments)
            show("Expense deleted")
        }
    }

    // MARK: Withdrawals

    @discardableResult
    func save(_ withdrawal: Withdrawal) -> Bool {
        commit { try $0.save(withdrawal) }
    }

    func deleteWithdrawal(_ id: UUID) {
        if commit({ $0.deleteWithdrawal(id) }) {
            if selectedWithdrawalID == id {
                selectedWithdrawalID = nil
                withdrawalDetailPath = []
            }
            show("Withdrawal deleted")
        }
    }

    // MARK: Settings

    func updateSettings(_ change: (inout LedgerSettings) -> Void) {
        commit { ledger in
            change(&ledger.settings)
            ledger.modifiedAt = Date()
        }
    }

    func isPersonInUse(_ id: UUID) -> Bool {
        ledger.expenses.contains { $0.personID == id }
    }

    // MARK: Incoming documents

    /// Entry point for documents that arrive from the scanner, the pickers or another app.
    func receive(_ drafts: [DraftDocument]) {
        guard !drafts.isEmpty else { return }
        guard phase == .ready, !isLocked, hasOnboarded else {
            queuedDrafts.append(contentsOf: drafts)
            return
        }
        // Give a dismissing picker or scanner time to get out of the way before presenting.
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            if sheet == nil {
                sheet = .newExpense(drafts: drafts)
            } else {
                queuedDrafts.append(contentsOf: drafts)
            }
        }
    }

    func receive(fileAt url: URL) {
        let draft = DocumentBuilder.draft(fromFileAt: url)
        // Files sent from another app's share sheet are copied into an Inbox folder inside the
        // archive. Once read, that copy is clutter, so move it out of the archive.
        let inbox = store.root.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(inbox + "/") {
            try? FileManager.default.removeItem(at: url)
            if let left = try? FileManager.default.contentsOfDirectory(atPath: inbox), left.isEmpty {
                try? FileManager.default.removeItem(atPath: inbox)
            }
        }
        if let draft {
            receive([draft])
        } else {
            show("Shoebox can file PDFs and images", style: .warning)
        }
    }

    func flushQueuedDrafts() {
        guard !queuedDrafts.isEmpty, phase == .ready, !isLocked, hasOnboarded, sheet == nil else { return }
        let drafts = queuedDrafts
        queuedDrafts = []
        receive(drafts)
    }

    // MARK: Banner

    func show(_ text: String, style: Banner.Style = .success) {
        let banner = Banner(text: text, style: style)
        withAnimation(.snappy) { self.banner = banner }
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if self.banner == banner {
                withAnimation(.snappy) { self.banner = nil }
            }
        }
    }

    // MARK: Backup folder

    var hasMirror: Bool { mirrorName != nil }

    func setMirrorFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            show("Couldn't use that folder", style: .warning)
            return
        }
        defaults.set(bookmark, forKey: Keys.mirrorBookmark)
        defaults.set(url.lastPathComponent, forKey: Keys.mirrorName)
        mirrorName = url.lastPathComponent
        mirrorNow()
    }

    func removeMirrorFolder() {
        mirrorTask?.cancel()
        defaults.removeObject(forKey: Keys.mirrorBookmark)
        defaults.removeObject(forKey: Keys.mirrorName)
        defaults.removeObject(forKey: Keys.mirrorDate)
        mirrorName = nil
        mirrorDate = nil
        mirrorState = .idle
    }

    private func scheduleMirror() {
        guard hasMirror, !isDemo else { return }
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.runMirror()
        }
    }

    func mirrorNow() {
        guard hasMirror, !isDemo else { return }
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in await self?.runMirror() }
    }

    private func runMirror() async {
        guard let bookmark = defaults.data(forKey: Keys.mirrorBookmark) else { return }
        mirrorState = .running
        let store = self.store
        let result = await Task.detached(priority: .utility) { () -> Result<ArchiveStore.MirrorReport, Error> in
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return .failure(MirrorError.folderUnavailable)
            }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var outcome: Result<ArchiveStore.MirrorReport, Error> = .failure(MirrorError.folderUnavailable)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder, options: [], error: &coordinationError) { writable in
                outcome = Result { try store.mirror(to: writable.appendingPathComponent("Shoebox Archive", isDirectory: true)) }
            }
            if let coordinationError { return .failure(coordinationError) }
            return outcome
        }.value
        switch result {
        case .success(let report) where report.failed == 0:
            mirrorDate = Date()
            defaults.set(mirrorDate, forKey: Keys.mirrorDate)
            mirrorState = .idle
        case .success(let report):
            mirrorState = .failed("\(report.failed) files could not be copied.")
        case .failure:
            mirrorState = .failed("The folder could not be reached. Choose it again.")
        }
    }

    enum MirrorError: Error { case folderUnavailable }
}

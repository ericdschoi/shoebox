import SwiftUI
import ShoeboxCore

struct WithdrawalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Which pane shows when closed: the list, or the selected withdrawal pushed over it.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    /// Open on iPhone Duo: the list and the selected withdrawal sit side by side.
    private var isTwoPane: Bool { horizontalSizeClass == .regular }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ScrollView {
                VStack(spacing: Metrics.sectionSpacing) {
                    if model.ledger.withdrawals.isEmpty {
                        emptyState
                    } else {
                        overview
                        history
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, 24)
            }
            .background(Color.screenBackground)
            .navigationTitle("Withdrawals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.sheet = .newWithdrawal(expenseID: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Record a withdrawal")
                }
            }
        } detail: {
            NavigationStack(path: $model.withdrawalDetailPath) {
                Group {
                    if let id = model.selectedWithdrawalID {
                        WithdrawalDetailView(withdrawalID: id)
                            .id(id)
                    } else {
                        ContentUnavailableView("No withdrawal selected", systemImage: "arrow.down.to.line",
                                               description: Text("Choose a withdrawal to see the expenses it reimbursed."))
                            .background(Color.screenBackground)
                    }
                }
                .navigationDestination(for: ExpenseRoute.self) { route in
                    ExpenseDetailView(expenseID: route.id, showsLargeDocuments: isTwoPane)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedWithdrawalID, initial: true) { _, selected in
            compactColumn = selected == nil ? .sidebar : .detail
        }
        .onChange(of: isTwoPane, initial: true) { selectFirstIfNeeded() }
        .onChange(of: model.ledger.withdrawals.count) { selectFirstIfNeeded() }
    }

    private var sortedWithdrawals: [Withdrawal] {
        model.ledger.withdrawals.sorted {
            $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date
        }
    }

    /// When open, the right pane always shows something. When closed, nothing is selected until a row is tapped.
    private func selectFirstIfNeeded() {
        guard isTwoPane, model.selectedWithdrawalID == nil else { return }
        model.selectedWithdrawalID = sortedWithdrawals.first?.id
    }

    private func select(_ withdrawal: Withdrawal) {
        if model.selectedWithdrawalID != withdrawal.id {
            model.withdrawalDetailPath = []
            model.selectedWithdrawalID = withdrawal.id
        }
        compactColumn = .detail
    }

    private var emptyState: some View {
        Card {
            EmptyState(symbol: "arrow.down.to.line",
                       title: "No withdrawals yet",
                       message: "When you take money out of your HSA to pay yourself back, record it here. Shoebox matches it to your oldest receipts first, so every dollar is accounted for.")
            HStack {
                Spacer()
                Button("Record a withdrawal") { model.sheet = .newWithdrawal(expenseID: nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Spacer()
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 4)
    }

    private var overview: some View {
        let totals = model.ledger.totals
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Withdrawn so far")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HeroAmount(cents: totals.withdrawnCents, size: 38)
                }
                Divider()
                HStack {
                    figure("Backed by receipts", Format.money(totals.reimbursedCents), tint: .primary)
                    Spacer()
                    figure("Still available", Format.money(totals.availableCents), tint: Color.brand)
                }
                if totals.unmatchedWithdrawalCents > 0 {
                    Label("\(Format.money(totals.unmatchedWithdrawalCents)) isn't matched to an expense yet",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.attention)
                }
            }
        }
        .padding(.top, 4)
    }

    private func figure(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var history: some View {
        let sorted = sortedWithdrawals
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "History")
                .padding(.top, 6)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, withdrawal in
                        if index > 0 { Divider().padding(.leading, 70) }
                        Button {
                            select(withdrawal)
                        } label: {
                            WithdrawalRow(withdrawal: withdrawal)
                                .padding(.horizontal, Metrics.cardPadding)
                                .padding(.vertical, 12)
                                .background(isTwoPane && model.selectedWithdrawalID == withdrawal.id ? Color.brandSoft : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isTwoPane && model.selectedWithdrawalID == withdrawal.id ? .isSelected : [])
                    }
                }
            }
        }
    }
}

struct WithdrawalRow: View {
    var withdrawal: Withdrawal

    var body: some View {
        let count = Set(withdrawal.allocations.map(\.expenseID)).count
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 40, height: 40)
                .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(withdrawal.note.isEmpty ? "Withdrawal" : withdrawal.note)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Format.day(withdrawal.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.money(withdrawal.amountCents))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if withdrawal.unmatchedCents > 0 {
                    TightLabel(text: "\(Format.moneyWhole(withdrawal.unmatchedCents)) unmatched", symbol: "exclamationmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.attention)
                } else {
                    Text(count == 1 ? "1 expense" : "\(count) expenses")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct WithdrawalDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var withdrawalID: UUID

    @State private var confirmingDelete = false
    @State private var share: ShareItem?
    @State private var isExporting = false

    var body: some View {
        Group {
            if let withdrawal = model.ledger.withdrawals.first(where: { $0.id == withdrawalID }) {
                content(withdrawal)
            } else {
                ContentUnavailableView("Withdrawal not found", systemImage: "questionmark.folder",
                                       description: Text("It may have been deleted."))
            }
        }
        .background(Color.screenBackground)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func content(_ withdrawal: Withdrawal) -> some View {
        let matched: [(Expense, Int)] = withdrawal.allocations.compactMap { allocation in
            model.ledger.expense(allocation.expenseID).map { ($0, allocation.cents) }
        }
        .sorted { $0.0.serviceDate < $1.0.serviceDate }
        return ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Format.dayLong(withdrawal.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HeroAmount(cents: withdrawal.amountCents, size: 42)
                        if !withdrawal.note.isEmpty {
                            Text(withdrawal.note)
                                .font(.subheadline)
                        }
                        if withdrawal.unmatchedCents == 0 {
                            Label("Every dollar is matched to a receipt", systemImage: "checkmark.seal.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.brand)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.top, 4)

                if withdrawal.unmatchedCents > 0 {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("\(Format.money(withdrawal.unmatchedCents)) isn't matched to an expense",
                                  systemImage: "exclamationmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.attention)
                            Text("A withdrawal that isn't backed by an eligible expense is generally taxable. File the missing expense, then match it here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Match to expenses") { model.sheet = .editWithdrawal(withdrawal.id) }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                if !matched.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Reimbursed expenses")
                            .padding(.top, 6)
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(matched.enumerated()), id: \.element.0.id) { index, pair in
                                    if index > 0 { Divider().padding(.leading, 70) }
                                    NavigationLink(value: ExpenseRoute(id: pair.0.id)) {
                                        HStack(spacing: 12) {
                                            CategoryIcon(category: pair.0.category)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(pair.0.displayProvider)
                                                    .font(.body.weight(.medium))
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.leading)
                                                Text(Format.day(pair.0.serviceDate))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 8)
                                            VStack(alignment: .trailing, spacing: 3) {
                                                Text(Format.money(pair.1))
                                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                                    .monospacedDigit()
                                                if pair.1 < pair.0.amountCents {
                                                    Text("of \(Format.money(pair.0.amountCents))")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Image(systemName: "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, Metrics.cardPadding)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Button {
                        export(withdrawal)
                    } label: {
                        if isExporting {
                            ProgressView().tint(.white)
                        } else {
                            Label("Export record with documents", systemImage: "doc.richtext")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isExporting)
                    Text("One PDF with a cover sheet and every receipt and EOB behind this withdrawal. Keep it with your tax records.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 28)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit") { model.sheet = .editWithdrawal(withdrawal.id) }
                Menu {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete withdrawal", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this withdrawal?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete withdrawal", role: .destructive) {
                dismiss()
                model.deleteWithdrawal(withdrawal.id)
            }
        } message: {
            Text("The expenses it reimbursed become available again.")
        }
    }

    private func export(_ withdrawal: Withdrawal) {
        isExporting = true
        let ledger = model.ledger
        let store = model.store
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                try? Reports.withdrawalPacket(for: withdrawal, ledger: ledger, store: store)
            }.value
            isExporting = false
            if let url {
                share = ShareItem(url: url)
            } else {
                model.show("Couldn't build the PDF", style: .warning)
            }
        }
    }
}

// MARK: - Editor

struct WithdrawalEditor: View {
    enum Mode {
        case new(expenseID: UUID?)
        case edit(UUID)
    }

    private enum Matching: String, CaseIterable, Identifiable {
        case oldestFirst = "Oldest first"
        case choose = "Choose"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var loaded = false
    @State private var editingID: UUID?
    @State private var createdAt = Date()
    @State private var amountText = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var matching: Matching = .oldestFirst
    @State private var selected = Set<UUID>()
    @FocusState private var amountFocused: Bool

    private var isNew: Bool { editingID == nil }

    private var amountCents: Int? {
        guard let cents = Money.parseCents(amountText), cents > 0 else { return nil }
        return cents
    }

    /// Expenses that still have something to reimburse, oldest first.
    private var candidates: [Expense] {
        model.ledger.expenses
            .filter { model.ledger.remainingCents(for: $0, excluding: editingID) > 0 }
            .sorted { $0.serviceDate == $1.serviceDate ? $0.createdAt < $1.createdAt : $0.serviceDate < $1.serviceDate }
    }

    private var availableCents: Int {
        candidates.reduce(0) { $0 + model.ledger.remainingCents(for: $1, excluding: editingID) }
    }

    private var allocations: [Allocation] {
        guard let cents = amountCents else { return [] }
        return model.ledger.suggestedAllocations(for: cents, limitedTo: matching == .choose ? selected : nil,
                                                 excluding: editingID)
    }

    var body: some View {
        let allocations = self.allocations
        let matched = allocations.reduce(0) { $0 + $1.cents }
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("$")
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .foregroundStyle(amountText.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                            TextField("0.00", text: $amountText)
                                .font(.system(size: 46, weight: .bold, design: .rounded))
                                .keyboardType(.decimalPad)
                                .focused($amountFocused)
                                .fixedSize()
                                .accessibilityLabel("Amount withdrawn")
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { amountFocused = true }
                        if availableCents > 0, amountCents != availableCents {
                            Button("Use everything available · \(Format.money(availableCents))") {
                                amountText = Money.plain(cents: availableCents)
                                matching = .oldestFirst
                                Haptics.tap()
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.brand)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Amount taken from your HSA")
                } footer: {
                    if !amountText.isEmpty && amountCents == nil {
                        Text("Enter an amount like 250.00").foregroundStyle(Color.attention)
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("Note, such as what it paid for", text: $note)
                }

                Section {
                    Picker("Match to", selection: $matching.animation(.snappy)) {
                        ForEach(Matching.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    if candidates.isEmpty {
                        Text("There are no expenses with anything left to reimburse.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows(for: allocations)) { row in
                        matchRow(row)
                    }
                } header: {
                    Text("Expenses this reimburses")
                } footer: {
                    summary(matched: matched)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "Record withdrawal" : "Edit withdrawal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(allocations) }
                        .fontWeight(.semibold)
                        .disabled(amountCents == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { amountFocused = false }
                }
            }
        }
        .onAppear(perform: load)
    }

    private struct MatchRow: Identifiable {
        var expense: Expense
        var remaining: Int
        var applied: Int
        var id: UUID { expense.id }
    }

    /// In "Oldest first" only the expenses being used are listed. In "Choose" every candidate is, so it can be ticked.
    private func rows(for allocations: [Allocation]) -> [MatchRow] {
        let applied = Dictionary(allocations.map { ($0.expenseID, $0.cents) }, uniquingKeysWith: +)
        return candidates.compactMap { expense in
            let cents = applied[expense.id] ?? 0
            if matching == .oldestFirst && cents == 0 { return nil }
            return MatchRow(expense: expense, remaining: model.ledger.remainingCents(for: expense, excluding: editingID), applied: cents)
        }
    }

    private func matchRow(_ row: MatchRow) -> some View {
        let isChosen = selected.contains(row.expense.id)
        return Button {
            guard matching == .choose else { return }
            if isChosen { selected.remove(row.expense.id) } else { selected.insert(row.expense.id) }
            Haptics.tap()
        } label: {
            HStack(spacing: 12) {
                if matching == .choose {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isChosen ? Color.brand : Color.secondary.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.expense.displayProvider)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Format.day(row.expense.serviceDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.applied > 0 ? Format.money(row.applied) : Format.money(row.remaining))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.applied > 0 ? Color.primary : Color.secondary)
                    if row.applied > 0, row.applied < row.remaining {
                        Text("of \(Format.money(row.remaining))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if row.applied == 0 {
                        Text("available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(matching == .choose && isChosen ? .isSelected : [])
    }

    @ViewBuilder
    private func summary(matched: Int) -> some View {
        if let cents = amountCents {
            let unmatched = cents - matched
            if unmatched > 0 {
                Label("\(Format.money(unmatched)) of this isn't matched to an expense. A withdrawal that isn't backed by an eligible expense is generally taxable. You can save now and match it after filing the receipt.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.attention)
            } else {
                Label("All \(Format.money(cents)) is matched to receipts.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.brand)
            }
        } else if matching == .oldestFirst {
            Text("Enter an amount and Shoebox uses up your oldest expenses first.")
        } else {
            Text("Tick the expenses this withdrawal pays you back for.")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .new(let expenseID):
            if let expenseID, let expense = model.ledger.expense(expenseID) {
                matching = .choose
                selected = [expenseID]
                amountText = Money.plain(cents: model.ledger.remainingCents(for: expense))
            } else if Launch.isDemo, let preset = Launch.value(after: "-amount") {
                amountText = preset
            }
        case .edit(let id):
            guard let withdrawal = model.ledger.withdrawals.first(where: { $0.id == id }) else { return }
            editingID = id
            createdAt = withdrawal.createdAt
            amountText = Money.plain(cents: withdrawal.amountCents)
            date = withdrawal.date.date()
            note = withdrawal.note
            selected = Set(withdrawal.allocations.map(\.expenseID))
            matching = selected.isEmpty ? .oldestFirst : .choose
        }
    }

    private func save(_ allocations: [Allocation]) {
        guard let cents = amountCents else { return }
        amountFocused = false
        let withdrawal = Withdrawal(id: editingID ?? UUID(), date: DayDate(date: date), amountCents: cents,
                                    note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    allocations: allocations, createdAt: createdAt)
        guard model.save(withdrawal) else { return }
        Haptics.success()
        model.show(isNew ? "Withdrawal recorded" : "Changes saved")
        dismiss()
    }
}

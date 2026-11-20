import SwiftUI
import ShoeboxCore

struct ExpensesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query = ""
    @State private var filter: Filter = .all
    /// Which pane shows when closed: the list, or the selected expense pushed over it.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case available = "Available"
        case needsPaperwork = "Needs paperwork"
        case reimbursed = "Reimbursed"
        var id: String { rawValue }
    }

    /// Open on iPhone Duo: the list and the selected expense sit side by side.
    private var isTwoPane: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            Group {
                if model.ledger.expenses.isEmpty {
                    ScrollView {
                        EmptyState(symbol: "tray",
                                   title: "No expenses yet",
                                   message: "Every medical expense you pay yourself goes here, with its receipt attached.")
                            .padding(.top, 60)
                        AddExpenseMenu {
                            Label("Add expense", systemImage: "plus")
                                .font(.headline)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 13)
                                .foregroundStyle(.white)
                                .background(Color.brandFill, in: Capsule())
                        }
                    }
                } else {
                    list
                }
            }
            .background(Color.screenBackground)
            .navigationTitle("Expenses")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AddExpenseMenu { Image(systemName: "plus") }
                }
            }
        } detail: {
            NavigationStack {
                if let id = model.selectedExpenseID {
                    ExpenseDetailView(expenseID: id, showsLargeDocuments: isTwoPane)
                        .id(id)
                } else {
                    ContentUnavailableView("No expense selected", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Choose an expense to see its details and receipt."))
                        .background(Color.screenBackground)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedExpenseID, initial: true) { _, selected in
            compactColumn = selected == nil ? .sidebar : .detail
        }
        .onChange(of: compactColumn) { _, column in
            // Closed: going back to the list clears the selection, so tapping the same row opens it again.
            if column == .sidebar, !isTwoPane { model.selectedExpenseID = nil }
        }
        .onChange(of: isTwoPane, initial: true) { selectFirstIfNeeded() }
        .onChange(of: model.ledger.expenses.count) { selectFirstIfNeeded() }
    }

    /// When open, the right pane always shows something. When closed, nothing is selected until a row is tapped.
    private func selectFirstIfNeeded() {
        guard isTwoPane, model.selectedExpenseID == nil else { return }
        model.selectedExpenseID = grouped.first?.expenses.first?.id
    }

    private var list: some View {
        @Bindable var model = model
        let groups = grouped
        return List(selection: $model.selectedExpenseID) {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { option in
                            FilterChip(title: option.rawValue, count: count(for: option), isSelected: filter == option) {
                                withAnimation(.snappy) { filter = option }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.screenPadding)
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if groups.isEmpty {
                Section {
                    ContentUnavailableView.search(text: query.isEmpty ? filter.rawValue : query)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(groups, id: \.year) { group in
                Section {
                    ForEach(group.expenses) { expense in
                        NavigationLink(value: expense.id) {
                            ExpenseRow(expense: expense)
                                .padding(.vertical, 3)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                model.sheet = .editExpense(expense.id)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            if model.ledger.remainingCents(for: expense) > 0 {
                                Button {
                                    model.sheet = .newWithdrawal(expenseID: expense.id)
                                } label: {
                                    Label("Reimburse", systemImage: "arrow.down.to.line")
                                }
                                .tint(Color.brand)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(String(group.year))
                        Spacer()
                        Text(Format.money(group.expenses.reduce(0) { $0 + $1.amountCents }))
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Provider, person, amount or year")
    }

    private func passes(_ expense: Expense, _ option: Filter) -> Bool {
        switch option {
        case .all: return true
        case .available: return model.ledger.remainingCents(for: expense) > 0
        case .needsPaperwork:
            return model.ledger.status(of: expense) != .ineligible && !model.ledger.documentIssues(for: expense).isEmpty
        case .reimbursed: return model.ledger.status(of: expense) == .reimbursed
        }
    }

    private func count(for option: Filter) -> Int {
        model.ledger.expenses.filter { passes($0, option) }.count
    }

    private var grouped: [(year: Int, expenses: [Expense])] {
        let visible = model.ledger.expenses.filter { passes($0, filter) && model.ledger.matches($0, query: query) }
        let byYear = Dictionary(grouping: visible) { $0.serviceDate.year }
        return byYear.keys.sorted(by: >).map { year in
            let sorted = (byYear[year] ?? []).sorted {
                $0.serviceDate == $1.serviceDate ? $0.createdAt > $1.createdAt : $0.serviceDate > $1.serviceDate
            }
            return (year, sorted)
        }
    }
}

struct FilterChip: View {
    var title: String
    var count: Int
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.brandFill : Color.cardBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

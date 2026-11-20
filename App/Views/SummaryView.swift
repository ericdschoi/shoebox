import SwiftUI
import Charts
import ShoeboxCore

struct SummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if model.ledger.expenses.isEmpty {
                        VStack(spacing: Metrics.sectionSpacing) {
                            BalanceCard()
                            firstRun
                        }
                    } else if horizontalSizeClass == .regular {
                        // Open on iPhone Duo: totals on the left, things to act on on the right.
                        HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                            VStack(spacing: Metrics.sectionSpacing) {
                                BalanceCard()
                                StatStrip()
                                yearChart
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: Metrics.sectionSpacing) {
                                attention
                                RecentCard()
                                backupNudge
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: Metrics.sectionSpacing) {
                            BalanceCard()
                            StatStrip()
                            attention
                            yearChart
                            RecentCard()
                            backupNudge
                        }
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, 24)
            }
            .background(Color.screenBackground)
            .navigationTitle("Summary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AddExpenseMenu { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: ExpenseRoute.self) { route in
                ExpenseDetailView(expenseID: route.id)
            }
        }
    }

    @ViewBuilder private var attention: some View {
        if !model.ledger.expensesNeedingAttention.isEmpty {
            AttentionCard()
        }
        if model.ledger.totals.unmatchedWithdrawalCents > 0 {
            UnmatchedCard()
        }
    }

    @ViewBuilder private var yearChart: some View {
        if model.ledger.yearSummaries.count > 0 {
            YearChartCard()
        }
    }

    @ViewBuilder private var backupNudge: some View {
        if !model.hasMirror, !model.isDemo, model.ledger.expenses.count >= 3 {
            BackupNudge()
        }
    }

    private var firstRun: some View {
        Card {
            EmptyState(symbol: "doc.viewfinder",
                       title: "File your first expense",
                       message: "Scan a medical receipt or bill you paid yourself. Shoebox reads it, files it, and adds it to what you can withdraw later.")
        }
    }
}

// MARK: - Balance

struct BalanceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.ledger.totals
        let open = model.ledger.expenses.filter { model.ledger.remainingCents(for: $0) > 0 }.count
        VStack(alignment: .leading, spacing: 0) {
            Text("Available to reimburse")
                .font(.subheadline.weight(.semibold))
                .opacity(0.85)
            HeroAmount(cents: totals.availableCents)
                .padding(.top, 2)
            Text(caption(open: open))
                .font(.footnote)
                .opacity(0.8)
                .padding(.top, 2)
            HStack(spacing: 10) {
                AddExpenseMenu {
                    Label("Add expense", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(Color.heroTop)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Button {
                    model.sheet = .newWithdrawal(expenseID: nil)
                } label: {
                    Label("Withdraw", systemImage: "arrow.down.to.line")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(.white)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(totals.availableCents == 0)
                .opacity(totals.availableCents == 0 ? 0.5 : 1)
                .accessibilityLabel("Record a withdrawal")
            }
            .padding(.top, 20)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [.heroTop, .heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(RadialGradient(colors: [Color.heroGlow.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 170))
                    .frame(width: 340, height: 340)
                    .offset(x: 130, y: -120)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.heroTop.opacity(0.28), radius: 16, y: 8)
        .padding(.top, 4)
    }

    private func caption(open: Int) -> String {
        switch open {
        case 0: return model.ledger.expenses.isEmpty ? "Nothing filed yet" : "Everything eligible has been reimbursed"
        case 1: return "From 1 expense you paid out of pocket"
        default: return "From \(open) expenses you paid out of pocket"
        }
    }
}

struct StatStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.ledger.totals
        HStack(spacing: 10) {
            stat("Paid yourself", Format.moneyWhole(totals.outOfPocketCents), "Total paid out of pocket")
            stat("Reimbursed", Format.moneyWhole(totals.reimbursedCents), "Total reimbursed")
            stat("Documents", "\(totals.documentCount)", "Documents on file")
        }
    }

    private func stat(_ title: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

// MARK: - Attention

struct AttentionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.ledger.expensesNeedingAttention
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.attention)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Paperwork to add")
                            .font(.headline)
                        Text(pending.count == 1 ? "1 expense is missing a document" : "\(pending.count) expenses are missing a document")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Metrics.cardPadding)
                ForEach(pending.prefix(3)) { expense in
                    Divider().padding(.leading, Metrics.cardPadding)
                    NavigationLink(value: ExpenseRoute(id: expense.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(expense.displayProvider)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(Format.day(expense.serviceDate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(model.ledger.documentIssues(for: expense), id: \.self) { issue in
                                        IssueChip(text: issue.label)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Metrics.cardPadding)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if pending.count > 3 {
                    Divider().padding(.leading, Metrics.cardPadding)
                    Button {
                        model.tab = .expenses
                    } label: {
                        Text("See all \(pending.count) in Expenses")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Metrics.cardPadding)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct UnmatchedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.tab = .withdrawals
        } label: {
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.attention)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Format.money(model.ledger.totals.unmatchedWithdrawalCents)) withdrawn without a matching expense")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text("Match it to expenses in Withdrawals so every dollar is backed by a receipt.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chart

struct YearChartCard: View {
    @Environment(AppModel.self) private var model

    private struct Bar: Identifiable {
        var year: String
        var series: String
        var cents: Int
        var id: String { year + series }
    }

    var body: some View {
        let rows = Array(model.ledger.yearSummaries.suffix(8))
        let bars = rows.flatMap { row in
            [Bar(year: String(row.year), series: "Reimbursed", cents: row.reimbursedCents),
             Bar(year: String(row.year), series: "Available", cents: row.availableCents)]
        }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("By year of service")
                        .font(.headline)
                    Text("What you paid yourself, and how much is still waiting")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Year", bar.year), y: .value("Amount", Double(bar.cents) / 100), width: .ratio(0.55))
                        .foregroundStyle(by: .value("Status", bar.series))
                        .cornerRadius(4)
                }
                .chartForegroundStyleScale(["Available": Color.brand, "Reimbursed": Color.brand.opacity(0.28)])
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.hairline)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(Format.moneyWhole(Int(amount * 100)))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel() }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                .frame(height: 190)
                .accessibilityLabel("Out-of-pocket spending by year")
            }
        }
    }
}

// MARK: - Recent

struct RecentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = model.ledger.expenses.sorted {
            $0.serviceDate == $1.serviceDate ? $0.createdAt > $1.createdAt : $0.serviceDate > $1.serviceDate
        }.prefix(4)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recent", actionTitle: "See all") { model.tab = .expenses }
                .padding(.top, 6)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, expense in
                        if index > 0 { Divider().padding(.leading, 70) }
                        NavigationLink(value: ExpenseRoute(id: expense.id)) {
                            ExpenseRow(expense: expense)
                                .padding(.horizontal, Metrics.cardPadding)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct BackupNudge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.tab = .settings
        } label: {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.title3)
                        .foregroundStyle(Color.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep a second copy")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Choose a backup folder in Settings so your records survive a lost phone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

/// One expense in a list: what, when, for whom, how much, and where it stands.
struct ExpenseRow: View {
    @Environment(AppModel.self) private var model
    var expense: Expense

    var body: some View {
        let status = model.ledger.status(of: expense)
        let issues = status == .ineligible ? [] : model.ledger.documentIssues(for: expense)
        HStack(spacing: 12) {
            CategoryIcon(category: expense.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.displayProvider)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !issues.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.attention)
                            .accessibilityLabel("Missing paperwork")
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.money(expense.amountCents))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                TightLabel(text: shortStatus(status), symbol: status.symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [Format.day(expense.serviceDate)]
        if model.ledger.settings.people.count > 1, let person = model.ledger.person(expense.personID) {
            parts.append(person.name)
        }
        return parts.joined(separator: " · ")
    }

    private func shortStatus(_ status: ExpenseStatus) -> String {
        switch status {
        case .unreimbursed: return "Available"
        case .partiallyReimbursed: return "\(Format.moneyWhole(model.ledger.remainingCents(for: expense))) left"
        case .reimbursed: return "Reimbursed"
        case .paidFromHSA: return "HSA paid"
        case .ineligible: return "Not eligible"
        }
    }
}

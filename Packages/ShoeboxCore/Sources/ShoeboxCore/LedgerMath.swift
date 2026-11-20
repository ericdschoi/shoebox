import Foundation

/// Why an expense can or cannot be reimbursed from the HSA.
public enum Eligibility: Hashable, Sendable {
    case eligible
    /// Already paid straight from the HSA.
    case paidFromHSA
    /// Incurred before the HSA was established.
    case beforeEstablishment
    /// Already taken as an itemized deduction.
    case claimedAsDeduction
}

public enum ExpenseStatus: Hashable, Sendable {
    case unreimbursed
    case partiallyReimbursed
    case reimbursed
    case paidFromHSA
    case ineligible

    public var label: String {
        switch self {
        case .unreimbursed: return "Unreimbursed"
        case .partiallyReimbursed: return "Partly reimbursed"
        case .reimbursed: return "Reimbursed"
        case .paidFromHSA: return "Paid from HSA"
        case .ineligible: return "Not eligible"
        }
    }
}

public enum DocumentIssue: Hashable, Sendable {
    case missingReceipt
    case missingEOB

    public var label: String {
        switch self {
        case .missingReceipt: return "No receipt"
        case .missingEOB: return "No EOB"
        }
    }
}

public struct YearSummary: Identifiable, Hashable, Sendable {
    public var year: Int
    /// Paid with personal funds that year.
    public var outOfPocketCents: Int
    /// Of that, how much has since been reimbursed.
    public var reimbursedCents: Int
    /// Of that, how much can still be reimbursed.
    public var availableCents: Int
    public var expenseCount: Int

    public var id: Int { year }
}

public struct LedgerTotals: Hashable, Sendable {
    public var availableCents: Int
    public var outOfPocketCents: Int
    public var reimbursedCents: Int
    public var paidFromHSACents: Int
    public var withdrawnCents: Int
    public var unmatchedWithdrawalCents: Int
    public var expenseCount: Int
    public var documentCount: Int
}

public enum LedgerError: Error, Equatable, LocalizedError {
    case amountMustBePositive
    case allocationExceedsWithdrawal
    case allocationExceedsExpense(provider: String)
    case allocationToUnknownExpense
    case allocationToIneligibleExpense(provider: String)

    public var errorDescription: String? {
        switch self {
        case .amountMustBePositive:
            return "Enter an amount greater than zero."
        case .allocationExceedsWithdrawal:
            return "The matched expenses add up to more than the withdrawal."
        case .allocationExceedsExpense(let provider):
            return "\(provider) would be reimbursed for more than it cost."
        case .allocationToUnknownExpense:
            return "One of the matched expenses no longer exists."
        case .allocationToIneligibleExpense(let provider):
            return "\(provider) is not eligible for reimbursement."
        }
    }
}

extension Ledger {

    // MARK: Per-expense state

    /// Total reimbursed against an expense, optionally ignoring one withdrawal (used while editing it).
    public func reimbursedCents(for expenseID: UUID, excluding withdrawalID: UUID? = nil) -> Int {
        var total = 0
        for w in withdrawals where w.id != withdrawalID {
            for a in w.allocations where a.expenseID == expenseID {
                total += a.cents
            }
        }
        return total
    }

    public func eligibility(of expense: Expense) -> Eligibility {
        if expense.paidFrom == .hsa { return .paidFromHSA }
        if expense.claimedAsDeduction { return .claimedAsDeduction }
        if let established = settings.establishedOn, expense.serviceDate < established {
            return .beforeEstablishment
        }
        return .eligible
    }

    /// What can still be reimbursed for this expense.
    public func remainingCents(for expense: Expense, excluding withdrawalID: UUID? = nil) -> Int {
        guard eligibility(of: expense) == .eligible else { return 0 }
        return max(0, expense.amountCents - reimbursedCents(for: expense.id, excluding: withdrawalID))
    }

    public func status(of expense: Expense) -> ExpenseStatus {
        switch eligibility(of: expense) {
        case .paidFromHSA: return .paidFromHSA
        case .beforeEstablishment, .claimedAsDeduction: return .ineligible
        case .eligible:
            let reimbursed = reimbursedCents(for: expense.id)
            if reimbursed <= 0 { return .unreimbursed }
            return reimbursed >= expense.amountCents ? .reimbursed : .partiallyReimbursed
        }
    }

    /// Paperwork an audit would ask for that is not attached yet.
    public func documentIssues(for expense: Expense) -> [DocumentIssue] {
        var issues: [DocumentIssue] = []
        if !expense.attachments.contains(where: { $0.kind == .receipt }) {
            issues.append(.missingReceipt)
        }
        if !expense.insuranceNotInvolved, !expense.attachments.contains(where: { $0.kind == .eob }) {
            issues.append(.missingEOB)
        }
        return issues
    }

    /// Expenses with missing paperwork, newest first. Ineligible expenses are left out: nothing rides on them.
    public var expensesNeedingAttention: [Expense] {
        expenses
            .filter { status(of: $0) != .ineligible && !documentIssues(for: $0).isEmpty }
            .sorted { $0.serviceDate > $1.serviceDate }
    }

    // MARK: Totals

    public var totals: LedgerTotals {
        var available = 0, outOfPocket = 0, paidFromHSA = 0, documents = 0
        for e in expenses {
            documents += e.attachments.count
            switch e.paidFrom {
            case .hsa: paidFromHSA += e.amountCents
            case .outOfPocket: outOfPocket += e.amountCents
            }
            available += remainingCents(for: e)
        }
        let withdrawn = withdrawals.reduce(0) { $0 + $1.amountCents }
        let matched = withdrawals.reduce(0) { $0 + $1.allocatedCents }
        let unmatched = withdrawals.reduce(0) { $0 + $1.unmatchedCents }
        return LedgerTotals(availableCents: available, outOfPocketCents: outOfPocket, reimbursedCents: matched,
                            paidFromHSACents: paidFromHSA, withdrawnCents: withdrawn,
                            unmatchedWithdrawalCents: unmatched, expenseCount: expenses.count,
                            documentCount: documents)
    }

    /// One row per calendar year that has out-of-pocket expenses, oldest first.
    public var yearSummaries: [YearSummary] {
        var byYear: [Int: YearSummary] = [:]
        for e in expenses where e.paidFrom == .outOfPocket {
            var row = byYear[e.serviceDate.year] ?? YearSummary(year: e.serviceDate.year, outOfPocketCents: 0,
                                                                reimbursedCents: 0, availableCents: 0, expenseCount: 0)
            row.outOfPocketCents += e.amountCents
            row.reimbursedCents += min(e.amountCents, reimbursedCents(for: e.id))
            row.availableCents += remainingCents(for: e)
            row.expenseCount += 1
            byYear[e.serviceDate.year] = row
        }
        return byYear.values.sorted { $0.year < $1.year }
    }

    public var years: [Int] {
        Array(Set(expenses.map { $0.serviceDate.year })).sorted(by: >)
    }

    // MARK: Withdrawals

    public enum AllocationOrder: Sendable {
        case oldestFirst
        case newestFirst
    }

    /// Spreads a withdrawal across eligible expenses. Oldest first is the default because the oldest
    /// receipts are the ones most at risk of fading or going missing.
    public func suggestedAllocations(for amountCents: Int, order: AllocationOrder = .oldestFirst,
                                     limitedTo expenseIDs: Set<UUID>? = nil,
                                     excluding withdrawalID: UUID? = nil) -> [Allocation] {
        guard amountCents > 0 else { return [] }
        var candidates = expenses.filter { expenseIDs?.contains($0.id) ?? true }
        candidates.sort {
            if $0.serviceDate != $1.serviceDate {
                return order == .oldestFirst ? $0.serviceDate < $1.serviceDate : $0.serviceDate > $1.serviceDate
            }
            return $0.createdAt < $1.createdAt
        }
        var left = amountCents
        var result: [Allocation] = []
        for e in candidates {
            guard left > 0 else { break }
            let remaining = remainingCents(for: e, excluding: withdrawalID)
            guard remaining > 0 else { continue }
            let take = min(remaining, left)
            result.append(Allocation(expenseID: e.id, cents: take))
            left -= take
        }
        return result
    }

    public func validate(_ withdrawal: Withdrawal) throws {
        guard withdrawal.amountCents > 0 else { throw LedgerError.amountMustBePositive }
        var perExpense: [UUID: Int] = [:]
        for a in withdrawal.allocations {
            guard a.cents > 0 else { throw LedgerError.amountMustBePositive }
            perExpense[a.expenseID, default: 0] += a.cents
        }
        guard withdrawal.allocatedCents <= withdrawal.amountCents else {
            throw LedgerError.allocationExceedsWithdrawal
        }
        for (expenseID, cents) in perExpense {
            guard let e = expense(expenseID) else { throw LedgerError.allocationToUnknownExpense }
            guard eligibility(of: e) == .eligible else {
                throw LedgerError.allocationToIneligibleExpense(provider: e.displayProvider)
            }
            guard cents <= remainingCents(for: e, excluding: withdrawal.id) else {
                throw LedgerError.allocationExceedsExpense(provider: e.displayProvider)
            }
        }
    }

    /// Adds a new withdrawal or replaces the one with the same id.
    public mutating func save(_ withdrawal: Withdrawal, now: Date = Timestamp.now()) throws {
        try validate(withdrawal)
        if let index = withdrawals.firstIndex(where: { $0.id == withdrawal.id }) {
            withdrawals[index] = withdrawal
        } else {
            withdrawals.append(withdrawal)
        }
        modifiedAt = now
    }

    public mutating func deleteWithdrawal(_ id: UUID, now: Date = Timestamp.now()) {
        withdrawals.removeAll { $0.id == id }
        modifiedAt = now
    }

    // MARK: Expenses

    /// Adds a new expense or replaces the one with the same id.
    ///
    /// If an edit lowers the amount below what was already reimbursed, or makes the expense ineligible,
    /// the affected allocations are trimmed so the ledger never claims more than an expense cost. The
    /// trimmed money shows up as unmatched on the withdrawal, where the user can see and fix it.
    public mutating func save(_ expense: Expense, now: Date = Timestamp.now()) {
        var updated = expense
        updated.modifiedAt = now
        if let index = expenses.firstIndex(where: { $0.id == expense.id }) {
            expenses[index] = updated
        } else {
            expenses.append(updated)
        }
        trimAllocations(for: updated)
        modifiedAt = now
    }

    /// Removes an expense and any allocations that pointed at it. Returns the attachments it had,
    /// so the caller can move their files out of the way.
    @discardableResult
    public mutating func deleteExpense(_ id: UUID, now: Date = Timestamp.now()) -> [Attachment] {
        guard let index = expenses.firstIndex(where: { $0.id == id }) else { return [] }
        let removed = expenses.remove(at: index)
        for w in withdrawals.indices {
            withdrawals[w].allocations.removeAll { $0.expenseID == id }
        }
        modifiedAt = now
        return removed.attachments
    }

    private mutating func trimAllocations(for expense: Expense) {
        let cap = eligibility(of: expense) == .eligible ? expense.amountCents : 0
        var excess = reimbursedCents(for: expense.id) - cap
        guard excess > 0 else { return }
        // Trim the most recent withdrawals first; the oldest matches are the most settled.
        let order = withdrawals.indices.sorted { withdrawals[$0].date > withdrawals[$1].date }
        for w in order {
            guard excess > 0 else { break }
            for a in withdrawals[w].allocations.indices.reversed() where withdrawals[w].allocations[a].expenseID == expense.id {
                guard excess > 0 else { break }
                let cut = min(excess, withdrawals[w].allocations[a].cents)
                withdrawals[w].allocations[a].cents -= cut
                excess -= cut
            }
            withdrawals[w].allocations.removeAll { $0.cents <= 0 }
        }
    }

    // MARK: Duplicates

    /// An existing expense with the same day and amount, and a matching (or missing) provider name.
    /// Filing the same bill twice would overstate what can be withdrawn, so the app asks before saving one.
    public func possibleDuplicate(of expense: Expense) -> Expense? {
        let name = expense.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return expenses.first { other in
            guard other.id != expense.id, other.serviceDate == expense.serviceDate,
                  other.amountCents == expense.amountCents else { return false }
            let otherName = other.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return name.isEmpty || otherName.isEmpty || name == otherName
        }
    }

    // MARK: Search

    public func matches(_ expense: Expense, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        var haystack = [expense.provider, expense.note, expense.category.label, expense.serviceDate.iso,
                        Money.plain(cents: expense.amountCents), String(expense.serviceDate.year)]
        if let person = person(expense.personID) { haystack.append(person.name) }
        return haystack.contains { $0.lowercased().contains(q) }
    }
}

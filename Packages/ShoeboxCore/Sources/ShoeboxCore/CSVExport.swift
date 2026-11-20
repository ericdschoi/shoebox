import Foundation

public enum CSVExport {
    /// Quotes a field when it needs it, and defuses values a spreadsheet might run as a formula.
    public static func field(_ value: String) -> String {
        var v = value
        if let first = v.first, "=+-@\t\r".contains(first) {
            v = "'" + v
        }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }

    public static func expenses(_ ledger: Ledger) -> String {
        var lines = [row(["Date of service", "Provider", "For", "Category", "Amount paid", "Paid from",
                          "Reimbursed", "Still available", "Status", "Receipt", "EOB", "Taken as deduction",
                          "Note", "Documents", "Expense ID"])]
        let sorted = ledger.expenses.sorted {
            $0.serviceDate == $1.serviceDate ? $0.createdAt < $1.createdAt : $0.serviceDate < $1.serviceDate
        }
        for e in sorted {
            let hasReceipt = e.attachments.contains { $0.kind == .receipt }
            let hasEOB = e.attachments.contains { $0.kind == .eob }
            let eob = hasEOB ? "Yes" : (e.insuranceNotInvolved ? "Not needed" : "No")
            lines.append(row([
                e.serviceDate.iso,
                e.provider,
                ledger.person(e.personID)?.name ?? "",
                e.category.label,
                Money.plain(cents: e.amountCents),
                e.paidFrom == .hsa ? "HSA" : "Out of pocket",
                Money.plain(cents: min(e.amountCents, ledger.reimbursedCents(for: e.id))),
                Money.plain(cents: ledger.remainingCents(for: e)),
                ledger.status(of: e).label,
                hasReceipt ? "Yes" : "No",
                eob,
                e.claimedAsDeduction ? "Yes" : "No",
                e.note,
                e.attachments.map(\.relativePath).joined(separator: "; "),
                e.id.uuidString
            ]))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func withdrawals(_ ledger: Ledger) -> String {
        var lines = [row(["Date", "Amount", "Matched to expenses", "Unmatched", "Note", "Expenses reimbursed",
                          "Withdrawal ID"])]
        for w in ledger.withdrawals.sorted(by: { $0.date < $1.date }) {
            let matched = w.allocations.map { a -> String in
                guard let e = ledger.expense(a.expenseID) else { return "Unknown expense \(Money.plain(cents: a.cents))" }
                return "\(e.serviceDate.iso) \(e.displayProvider) \(Money.plain(cents: a.cents))"
            }
            lines.append(row([
                w.date.iso,
                Money.plain(cents: w.amountCents),
                Money.plain(cents: w.allocatedCents),
                Money.plain(cents: w.unmatchedCents),
                w.note,
                matched.joined(separator: "; "),
                w.id.uuidString
            ]))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

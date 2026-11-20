import Foundation

/// A believable sample archive, used for previews, screenshots and tests. Nothing in it is real.
public enum DemoData {
    public typealias DocumentMaker = (_ expense: Expense, _ kind: AttachmentKind) -> (data: Data, fileExtension: String)?

    private struct Row {
        var yearsAgo: Int
        var month: Int
        var day: Int
        var provider: String
        var category: ExpenseCategory
        var cents: Int
        var person: Int
        var receipt: Bool = true
        var eob: Bool = true
        var otc: Bool = false
        var fromHSA: Bool = false
        var note: String = ""
    }

    private static let rows: [Row] = [
        Row(yearsAgo: 4, month: 3, day: 14, provider: "Valley Family Medicine", category: .medical, cents: 18500, person: 0),
        Row(yearsAgo: 4, month: 9, day: 2, provider: "Brightside Dental", category: .dental, cents: 42000, person: 0, note: "Crown, upper left"),
        Row(yearsAgo: 3, month: 1, day: 22, provider: "ClearView Optometry", category: .vision, cents: 31250, person: 1),
        Row(yearsAgo: 3, month: 6, day: 8, provider: "Canyon Imaging Center", category: .labImaging, cents: 67500, person: 0, note: "MRI, right knee"),
        Row(yearsAgo: 3, month: 11, day: 30, provider: "Corner Pharmacy", category: .pharmacy, cents: 4599, person: 1, eob: false, otc: true),
        Row(yearsAgo: 2, month: 2, day: 11, provider: "Valley Family Medicine", category: .medical, cents: 12000, person: 1),
        Row(yearsAgo: 2, month: 5, day: 19, provider: "Northridge Physical Therapy", category: .medical, cents: 96000, person: 0, note: "8 sessions"),
        Row(yearsAgo: 2, month: 10, day: 3, provider: "Brightside Dental", category: .dental, cents: 15000, person: 1),
        Row(yearsAgo: 1, month: 1, day: 9, provider: "Summit Urgent Care", category: .medical, cents: 22500, person: 0),
        Row(yearsAgo: 1, month: 4, day: 27, provider: "Corner Pharmacy", category: .pharmacy, cents: 8840, person: 0, fromHSA: true),
        Row(yearsAgo: 1, month: 8, day: 15, provider: "Sierra Dermatology", category: .medical, cents: 27500, person: 0),
        Row(yearsAgo: 1, month: 12, day: 5, provider: "ClearView Optometry", category: .vision, cents: 38900, person: 0, note: "Exam and lenses"),
        Row(yearsAgo: 0, month: 2, day: 18, provider: "Valley Family Medicine", category: .medical, cents: 14000, person: 0),
        Row(yearsAgo: 0, month: 5, day: 6, provider: "Canyon Imaging Center", category: .labImaging, cents: 21800, person: 1, eob: false),
        Row(yearsAgo: 0, month: 7, day: 21, provider: "Brightside Dental", category: .dental, cents: 16500, person: 0, receipt: false, eob: false),
        Row(yearsAgo: 0, month: 9, day: 12, provider: "Corner Pharmacy", category: .pharmacy, cents: 3275, person: 0, eob: false, otc: true)
    ]

    /// Builds the sample ledger. If a store and a document maker are given, sample documents are
    /// written into the archive so previews and integrity checks have real files to work with.
    public static func ledger(today: DayDate, store: ArchiveStore? = nil, makeDocument: DocumentMaker? = nil) -> Ledger {
        let me = Person(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "Alex", relationship: .accountHolder)
        let spouse = Person(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "Sam", relationship: .spouse)
        let established = DayDate(year: today.year - 4, month: 1, day: 1)
        var ledger = Ledger(settings: LedgerSettings(accountLabel: "Health Savings Account", establishedOn: established,
                                                     people: [me, spouse]))
        let stamp = today.date()
        for (index, row) in rows.enumerated() {
            var day = DayDate(year: today.year - row.yearsAgo, month: row.month, day: row.day) ?? today
            if day > today {
                // Early in the year, pull this year's sample rows back so none sit in the future.
                day = DayDate(year: today.year - 1, month: row.month, day: row.day) ?? today
            }
            var expense = Expense(id: stableID(index), serviceDate: day, provider: row.provider,
                                  personID: row.person == 0 ? me.id : spouse.id, category: row.category,
                                  amountCents: row.cents, paidFrom: row.fromHSA ? .hsa : .outOfPocket,
                                  note: row.note, insuranceNotInvolved: row.otc,
                                  createdAt: stamp.addingTimeInterval(Double(index)), modifiedAt: stamp)
            if let store, let makeDocument {
                var kinds: [AttachmentKind] = []
                if row.receipt { kinds.append(.receipt) }
                if row.eob { kinds.append(.eob) }
                for kind in kinds {
                    guard let doc = makeDocument(expense, kind) else { continue }
                    if let attachment = try? store.storeDocument(doc.data, kind: kind, originalName: "\(kind.label).\(doc.fileExtension)",
                                                                 fileExtension: doc.fileExtension, serviceDate: day,
                                                                 provider: row.provider, amountCents: row.cents, now: stamp) {
                        expense.attachments.append(attachment)
                    }
                }
            }
            ledger.expenses.append(expense)
        }
        // Two past withdrawals, matched oldest first, the way the app suggests.
        for (offset, amount) in [(2, 60500), (1, 110000)] {
            let date = DayDate(year: today.year - offset, month: 12, day: 15) ?? today
            guard date <= today else { continue }
            let eligible = Set(ledger.expenses.filter { $0.serviceDate <= date }.map(\.id))
            let allocations = ledger.suggestedAllocations(for: amount, limitedTo: eligible)
            let withdrawal = Withdrawal(id: stableID(100 + offset), date: date, amountCents: amount,
                                        note: offset == 2 ? "Dental and first visits" : "Toward the new water heater",
                                        allocations: allocations, createdAt: stamp)
            try? ledger.save(withdrawal, now: stamp)
        }
        ledger.createdAt = stamp
        ledger.modifiedAt = stamp
        return ledger
    }

    private static func stableID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n)) ?? UUID()
    }
}

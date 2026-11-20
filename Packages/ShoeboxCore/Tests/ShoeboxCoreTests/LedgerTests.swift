import XCTest
@testable import ShoeboxCore

final class DayDateTests: XCTestCase {
    func testValidation() {
        XCTAssertNotNil(DayDate(year: 2024, month: 2, day: 29))
        XCTAssertNil(DayDate(year: 2023, month: 2, day: 29))
        XCTAssertNil(DayDate(year: 2100, month: 2, day: 29))
        XCTAssertNotNil(DayDate(year: 2000, month: 2, day: 29))
        XCTAssertNil(DayDate(year: 2026, month: 13, day: 1))
        XCTAssertNil(DayDate(year: 2026, month: 4, day: 31))
    }

    func testISORoundTrip() throws {
        let day = try XCTUnwrap(DayDate(iso: "2031-03-04"))
        XCTAssertEqual(day.iso, "2031-03-04")
        XCTAssertNil(DayDate(iso: "2031-3-4"))
        XCTAssertNil(DayDate(iso: "03/04/2031"))
        let data = try JSONEncoder().encode([day])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"2031-03-04\"]")
        XCTAssertEqual(try JSONDecoder().decode([DayDate].self, from: data), [day])
    }

    func testOrderingAndCalendar() throws {
        let a = try XCTUnwrap(DayDate(iso: "2026-12-31"))
        let b = try XCTUnwrap(DayDate(iso: "2027-01-01"))
        XCTAssertLessThan(a, b)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        XCTAssertEqual(DayDate(date: a.date(calendar: calendar), calendar: calendar), a)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(DayDate(date: b.date(calendar: calendar), calendar: calendar), b)
    }
}

final class MoneyTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Money.parseCents("125"), 12500)
        XCTAssertEqual(Money.parseCents("125.5"), 12550)
        XCTAssertEqual(Money.parseCents("125.50"), 12550)
        XCTAssertEqual(Money.parseCents(" $1,250.00 "), 125000)
        XCTAssertEqual(Money.parseCents(".99"), 99)
        XCTAssertEqual(Money.parseCents("0.07"), 7)
        XCTAssertEqual(Money.parseCents("12."), 1200)
        XCTAssertNil(Money.parseCents(""))
        XCTAssertNil(Money.parseCents("."))
        XCTAssertNil(Money.parseCents("-5"))
        XCTAssertNil(Money.parseCents("1.234"))
        XCTAssertNil(Money.parseCents("1.2.3"))
        XCTAssertNil(Money.parseCents("abc"))
        XCTAssertNil(Money.parseCents("12345678901"))
    }

    func testPlain() {
        XCTAssertEqual(Money.plain(cents: 12345), "123.45")
        XCTAssertEqual(Money.plain(cents: 5), "0.05")
        XCTAssertEqual(Money.plain(cents: 0), "0.00")
        XCTAssertEqual(Money.plain(cents: -250), "-2.50")
    }

    func testCentsDoNotDrift() {
        // The classic floating-point trap: 0.10 added ten thousand times.
        let total = (0..<10_000).reduce(0) { sum, _ in sum + (Money.parseCents("0.10") ?? 0) }
        XCTAssertEqual(total, 100_000)
    }
}

final class LedgerMathTests: XCTestCase {
    private func day(_ iso: String) -> DayDate { DayDate(iso: iso)! }

    private func makeLedger() -> (Ledger, a: Expense, b: Expense, c: Expense) {
        var ledger = Ledger(settings: LedgerSettings(establishedOn: day("2022-01-01")))
        let a = Expense(serviceDate: day("2022-03-01"), provider: "A", amountCents: 10_000)
        let b = Expense(serviceDate: day("2023-03-01"), provider: "B", amountCents: 25_000)
        let c = Expense(serviceDate: day("2024-03-01"), provider: "C", amountCents: 5_000)
        ledger.save(b)
        ledger.save(c)
        ledger.save(a)
        return (ledger, a, b, c)
    }

    func testAvailableBalance() {
        let (ledger, _, _, _) = makeLedger()
        XCTAssertEqual(ledger.totals.availableCents, 40_000)
        XCTAssertEqual(ledger.totals.outOfPocketCents, 40_000)
        XCTAssertEqual(ledger.totals.reimbursedCents, 0)
    }

    func testEligibilityRules() {
        var (ledger, _, _, _) = makeLedger()
        let early = Expense(serviceDate: day("2021-12-31"), provider: "Early", amountCents: 9_999)
        let onDay = Expense(serviceDate: day("2022-01-01"), provider: "OnDay", amountCents: 100)
        let deducted = Expense(serviceDate: day("2023-01-01"), provider: "Deducted", amountCents: 7_000, claimedAsDeduction: true)
        let card = Expense(serviceDate: day("2023-01-01"), provider: "Card", amountCents: 3_000, paidFrom: .hsa)
        for e in [early, onDay, deducted, card] { ledger.save(e) }
        XCTAssertEqual(ledger.eligibility(of: early), .beforeEstablishment)
        XCTAssertEqual(ledger.eligibility(of: onDay), .eligible)
        XCTAssertEqual(ledger.eligibility(of: deducted), .claimedAsDeduction)
        XCTAssertEqual(ledger.eligibility(of: card), .paidFromHSA)
        XCTAssertEqual(ledger.status(of: early), .ineligible)
        XCTAssertEqual(ledger.status(of: card), .paidFromHSA)
        // Only the on-day expense adds to what is available.
        XCTAssertEqual(ledger.totals.availableCents, 40_100)
        XCTAssertEqual(ledger.totals.paidFromHSACents, 3_000)
    }

    func testNoEstablishmentDateTreatsEverythingAsEligible() {
        var ledger = Ledger()
        let e = Expense(serviceDate: day("1999-01-01"), provider: "Old", amountCents: 500)
        ledger.save(e)
        XCTAssertEqual(ledger.eligibility(of: e), .eligible)
    }

    func testSuggestedAllocationsOldestFirst() {
        let (ledger, a, b, c) = makeLedger()
        let suggestion = ledger.suggestedAllocations(for: 12_000)
        XCTAssertEqual(suggestion, [Allocation(expenseID: a.id, cents: 10_000), Allocation(expenseID: b.id, cents: 2_000)])
        let newest = ledger.suggestedAllocations(for: 6_000, order: .newestFirst)
        XCTAssertEqual(newest, [Allocation(expenseID: c.id, cents: 5_000), Allocation(expenseID: b.id, cents: 1_000)])
        let limited = ledger.suggestedAllocations(for: 99_999, limitedTo: [c.id])
        XCTAssertEqual(limited, [Allocation(expenseID: c.id, cents: 5_000)])
        XCTAssertEqual(ledger.suggestedAllocations(for: 0), [])
    }

    func testSuggestionNeverExceedsAvailable() {
        let (ledger, _, _, _) = makeLedger()
        let suggestion = ledger.suggestedAllocations(for: 1_000_000)
        XCTAssertEqual(suggestion.reduce(0) { $0 + $1.cents }, 40_000)
    }

    func testWithdrawalLifecycle() throws {
        var (ledger, a, b, _) = makeLedger()
        let w = Withdrawal(date: day("2025-01-10"), amountCents: 12_000,
                           allocations: ledger.suggestedAllocations(for: 12_000))
        try ledger.save(w)
        XCTAssertEqual(ledger.status(of: a), .reimbursed)
        XCTAssertEqual(ledger.status(of: b), .partiallyReimbursed)
        XCTAssertEqual(ledger.remainingCents(for: b), 23_000)
        XCTAssertEqual(ledger.totals.availableCents, 28_000)
        XCTAssertEqual(ledger.totals.reimbursedCents, 12_000)
        XCTAssertEqual(ledger.totals.unmatchedWithdrawalCents, 0)

        // A second withdrawal continues where the first left off.
        let next = ledger.suggestedAllocations(for: 1_000)
        XCTAssertEqual(next, [Allocation(expenseID: b.id, cents: 1_000)])

        ledger.deleteWithdrawal(w.id)
        XCTAssertEqual(ledger.totals.availableCents, 40_000)
        XCTAssertEqual(ledger.status(of: a), .unreimbursed)
    }

    func testEditingAWithdrawalDoesNotCountItAgainstItself() throws {
        var (ledger, a, _, _) = makeLedger()
        var w = Withdrawal(date: day("2025-01-10"), amountCents: 10_000,
                           allocations: [Allocation(expenseID: a.id, cents: 10_000)])
        try ledger.save(w)
        w.note = "edited"
        XCTAssertNoThrow(try ledger.save(w))
        XCTAssertEqual(ledger.withdrawals.count, 1)
        XCTAssertEqual(ledger.withdrawals[0].note, "edited")
    }

    func testValidationRejectsOverReimbursement() throws {
        var (ledger, a, _, _) = makeLedger()
        let tooMuch = Withdrawal(date: day("2025-01-10"), amountCents: 50_000,
                                 allocations: [Allocation(expenseID: a.id, cents: 10_001)])
        XCTAssertThrowsError(try ledger.save(tooMuch)) { XCTAssertEqual($0 as? LedgerError, .allocationExceedsExpense(provider: "A")) }

        let overWithdrawal = Withdrawal(date: day("2025-01-10"), amountCents: 5_000,
                                        allocations: [Allocation(expenseID: a.id, cents: 6_000)])
        XCTAssertThrowsError(try ledger.save(overWithdrawal)) { XCTAssertEqual($0 as? LedgerError, .allocationExceedsWithdrawal) }

        let zero = Withdrawal(date: day("2025-01-10"), amountCents: 0)
        XCTAssertThrowsError(try ledger.save(zero)) { XCTAssertEqual($0 as? LedgerError, .amountMustBePositive) }

        let ghost = Withdrawal(date: day("2025-01-10"), amountCents: 100, allocations: [Allocation(expenseID: UUID(), cents: 100)])
        XCTAssertThrowsError(try ledger.save(ghost)) { XCTAssertEqual($0 as? LedgerError, .allocationToUnknownExpense) }

        // Two withdrawals cannot both claim the same dollars.
        try ledger.save(Withdrawal(date: day("2025-01-10"), amountCents: 10_000, allocations: [Allocation(expenseID: a.id, cents: 10_000)]))
        let double = Withdrawal(date: day("2025-02-10"), amountCents: 1, allocations: [Allocation(expenseID: a.id, cents: 1)])
        XCTAssertThrowsError(try ledger.save(double))

        // Split allocations to the same expense are summed before checking.
        var (fresh, x, _, _) = makeLedger()
        let split = Withdrawal(date: day("2025-01-10"), amountCents: 20_000,
                               allocations: [Allocation(expenseID: x.id, cents: 6_000), Allocation(expenseID: x.id, cents: 6_000)])
        XCTAssertThrowsError(try fresh.save(split))
        x.amountCents = 1
        _ = x
    }

    func testIneligibleExpenseCannotBeReimbursed() {
        var ledger = Ledger(settings: LedgerSettings(establishedOn: day("2022-01-01")))
        let early = Expense(serviceDate: day("2020-01-01"), provider: "Early", amountCents: 1_000)
        ledger.save(early)
        let w = Withdrawal(date: day("2025-01-01"), amountCents: 1_000, allocations: [Allocation(expenseID: early.id, cents: 1_000)])
        XCTAssertThrowsError(try ledger.save(w)) { XCTAssertEqual($0 as? LedgerError, .allocationToIneligibleExpense(provider: "Early")) }
    }

    func testUnmatchedWithdrawalIsTracked() throws {
        var (ledger, a, _, _) = makeLedger()
        try ledger.save(Withdrawal(date: day("2025-01-10"), amountCents: 15_000, allocations: [Allocation(expenseID: a.id, cents: 10_000)]))
        XCTAssertEqual(ledger.withdrawals[0].unmatchedCents, 5_000)
        XCTAssertEqual(ledger.totals.unmatchedWithdrawalCents, 5_000)
        XCTAssertEqual(ledger.totals.withdrawnCents, 15_000)
        XCTAssertEqual(ledger.totals.reimbursedCents, 10_000)
    }

    func testLoweringAnAmountTrimsAllocations() throws {
        var (ledger, a, _, _) = makeLedger()
        try ledger.save(Withdrawal(date: day("2025-01-10"), amountCents: 10_000, allocations: [Allocation(expenseID: a.id, cents: 10_000)]))
        var edited = a
        edited.amountCents = 4_000
        ledger.save(edited)
        XCTAssertEqual(ledger.reimbursedCents(for: a.id), 4_000)
        XCTAssertEqual(ledger.withdrawals[0].unmatchedCents, 6_000)
        XCTAssertEqual(ledger.status(of: edited), .reimbursed)
        XCTAssertNoThrow(try ledger.validate(ledger.withdrawals[0]))
    }

    func testMakingAnExpenseIneligibleReleasesItsAllocations() throws {
        var (ledger, a, _, _) = makeLedger()
        try ledger.save(Withdrawal(date: day("2025-01-10"), amountCents: 10_000, allocations: [Allocation(expenseID: a.id, cents: 10_000)]))
        var edited = a
        edited.claimedAsDeduction = true
        ledger.save(edited)
        XCTAssertEqual(ledger.reimbursedCents(for: a.id), 0)
        XCTAssertTrue(ledger.withdrawals[0].allocations.isEmpty)
        XCTAssertEqual(ledger.withdrawals[0].unmatchedCents, 10_000)
    }

    func testDeletingAnExpenseRemovesItsAllocations() throws {
        var (ledger, a, b, _) = makeLedger()
        try ledger.save(Withdrawal(date: day("2025-01-10"), amountCents: 12_000, allocations: ledger.suggestedAllocations(for: 12_000)))
        ledger.deleteExpense(a.id)
        XCTAssertNil(ledger.expense(a.id))
        XCTAssertEqual(ledger.withdrawals[0].allocations, [Allocation(expenseID: b.id, cents: 2_000)])
        XCTAssertEqual(ledger.withdrawals[0].unmatchedCents, 10_000)
    }

    func testDocumentIssues() {
        var ledger = Ledger()
        let receipt = Attachment(kind: .receipt, relativePath: "Documents/2024/r.pdf", originalName: "r.pdf", sha256: "", byteCount: 1)
        let eob = Attachment(kind: .eob, relativePath: "Documents/2024/e.pdf", originalName: "e.pdf", sha256: "", byteCount: 1)
        let bare = Expense(serviceDate: day("2024-01-01"), provider: "Bare", amountCents: 100)
        let receiptOnly = Expense(serviceDate: day("2024-01-02"), provider: "R", amountCents: 100, attachments: [receipt])
        let otc = Expense(serviceDate: day("2024-01-03"), provider: "OTC", amountCents: 100, attachments: [receipt], insuranceNotInvolved: true)
        let complete = Expense(serviceDate: day("2024-01-04"), provider: "Full", amountCents: 100, attachments: [receipt, eob])
        for e in [bare, receiptOnly, otc, complete] { ledger.save(e) }
        XCTAssertEqual(ledger.documentIssues(for: bare), [.missingReceipt, .missingEOB])
        XCTAssertEqual(ledger.documentIssues(for: receiptOnly), [.missingEOB])
        XCTAssertEqual(ledger.documentIssues(for: otc), [])
        XCTAssertEqual(ledger.documentIssues(for: complete), [])
        XCTAssertEqual(ledger.expensesNeedingAttention.map(\.provider), ["R", "Bare"])
    }

    func testYearSummaries() throws {
        var (ledger, _, _, _) = makeLedger()
        ledger.save(Expense(serviceDate: day("2023-08-01"), provider: "Card", amountCents: 9_000, paidFrom: .hsa))
        try ledger.save(Withdrawal(date: day("2025-01-10"), amountCents: 12_000, allocations: ledger.suggestedAllocations(for: 12_000)))
        let rows = ledger.yearSummaries
        XCTAssertEqual(rows.map(\.year), [2022, 2023, 2024])
        XCTAssertEqual(rows[0].outOfPocketCents, 10_000)
        XCTAssertEqual(rows[0].reimbursedCents, 10_000)
        XCTAssertEqual(rows[0].availableCents, 0)
        XCTAssertEqual(rows[1].outOfPocketCents, 25_000)
        XCTAssertEqual(rows[1].reimbursedCents, 2_000)
        XCTAssertEqual(rows[1].availableCents, 23_000)
        XCTAssertEqual(rows[1].expenseCount, 1)
        // Totals across years agree with the headline number.
        XCTAssertEqual(rows.reduce(0) { $0 + $1.availableCents }, ledger.totals.availableCents)
    }

    func testSearch() {
        var ledger = Ledger(settings: LedgerSettings(people: [Person(name: "Jordan", relationship: .spouse)]))
        let e = Expense(serviceDate: day("2024-06-15"), provider: "Brightside Dental", personID: ledger.settings.people[0].id,
                        category: .dental, amountCents: 42_000, note: "Crown")
        ledger.save(e)
        for q in ["bright", "DENTAL", "crown", "jordan", "2024", "420.00", "  "] {
            XCTAssertTrue(ledger.matches(e, query: q), q)
        }
        XCTAssertFalse(ledger.matches(e, query: "optometry"))
    }

    func testDemoLedgerIsInternallyConsistent() throws {
        let today = day("2026-11-20")
        let ledger = DemoData.ledger(today: today)
        XCTAssertEqual(ledger.expenses.count, 16)
        XCTAssertEqual(ledger.withdrawals.count, 2)
        XCTAssertTrue(ledger.expenses.allSatisfy { $0.serviceDate <= today })
        for w in ledger.withdrawals {
            XCTAssertNoThrow(try ledger.validate(w))
            XCTAssertEqual(w.unmatchedCents, 0)
        }
        let totals = ledger.totals
        XCTAssertEqual(totals.outOfPocketCents - totals.reimbursedCents, totals.availableCents)
        XCTAssertGreaterThan(totals.availableCents, 0)
        // The sample still makes sense on the first day of a year.
        let january = DemoData.ledger(today: day("2027-01-01"))
        XCTAssertTrue(january.expenses.allSatisfy { $0.serviceDate <= day("2027-01-01") })
    }
}

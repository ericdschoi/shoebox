import XCTest
@testable import ShoeboxCore

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256Hasher.hash(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hash(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hasher.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(SHA256Hasher.hash(million),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testChunkedUpdatesMatchOneShot() {
        var bytes = [UInt8]()
        for i in 0..<5000 { bytes.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        let data = Data(bytes)
        let expected = SHA256Hasher.hash(data)
        for chunk in [1, 3, 55, 56, 63, 64, 65, 127, 1000] {
            var hasher = SHA256Hasher()
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                hasher.update(data.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(hasher.finalize(), expected, "chunk size \(chunk)")
        }
    }

    func testBoundaryLengths() {
        // Lengths around the padding boundary are where hand-written SHA-256 usually breaks.
        let known = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        ]
        for (length, digest) in known {
            XCTAssertEqual(SHA256Hasher.hash(Data(repeating: UInt8(ascii: "a"), count: length)), digest, "length \(length)")
        }
    }
}

final class ArchiveStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shoebox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func day(_ iso: String) -> DayDate { DayDate(iso: iso)! }

    func testNewArchiveLoadsEmptyLedger() throws {
        let store = ArchiveStore(root: root.appendingPathComponent("fresh"))
        XCTAssertFalse(store.ledgerExists)
        let ledger = try store.loadLedger()
        XCTAssertTrue(ledger.expenses.isEmpty)
        XCTAssertEqual(ledger.schemaVersion, Ledger.currentSchemaVersion)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = ArchiveStore(root: root)
        let today = day("2026-11-20")
        let ledger = DemoData.ledger(today: today, store: store) { expense, kind in
            (Data("\(expense.provider) \(kind.rawValue)".utf8), "txt")
        }
        try store.save(ledger, today: today)
        let loaded = try store.loadLedger()
        XCTAssertEqual(loaded, ledger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.expensesCSVURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.withdrawalsCSVURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.txt").path))
        // The JSON is something a person can open and read.
        let text = try String(contentsOf: store.ledgerURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"serviceDate\" : \""))
        XCTAssertTrue(text.contains("Documents/"))
        XCTAssertFalse(text.contains("\\/"))
    }

    func testFreshRecordsSurviveARoundTripExactly() throws {
        // Records created "now" must compare equal after a save and load, with no sub-second drift.
        let store = ArchiveStore(root: root)
        var ledger = Ledger(settings: LedgerSettings(people: [Person(name: "Pat", relationship: .accountHolder)]))
        var expense = Expense(serviceDate: day("2026-05-01"), provider: "Clinic", amountCents: 5_000)
        expense.attachments = [try store.storeDocument(Data("x".utf8), kind: .receipt, originalName: "x", fileExtension: "txt",
                                                       serviceDate: expense.serviceDate, provider: "Clinic", amountCents: 5_000)]
        ledger.save(expense)
        try ledger.save(Withdrawal(date: day("2026-06-01"), amountCents: 1_000, allocations: [Allocation(expenseID: expense.id, cents: 1_000)]))
        try store.save(ledger)
        XCTAssertEqual(try store.loadLedger(), ledger)
    }

    func testStoredDocumentNamingAndChecksum() throws {
        let store = ArchiveStore(root: root)
        let data = Data("receipt body".utf8)
        let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000000")!
        let attachment = try store.storeDocument(data, kind: .receipt, originalName: "IMG_0042.JPG", fileExtension: "PDF",
                                                 serviceDate: day("2031-03-04"), provider: "Valley Dental, Inc.",
                                                 amountCents: 12_500, id: id)
        XCTAssertEqual(attachment.relativePath, "Documents/2031/2031-03-04_Valley-Dental-Inc_125.00_receipt_a1b2c3.pdf")
        XCTAssertEqual(attachment.sha256, SHA256Hasher.hash(data))
        XCTAssertEqual(attachment.byteCount, data.count)
        XCTAssertEqual(try Data(contentsOf: store.url(for: attachment)), data)
        XCTAssertThrowsError(try store.storeDocument(Data(), kind: .receipt, originalName: "", fileExtension: "pdf",
                                                     serviceDate: day("2031-03-04"), provider: "X", amountCents: 1))
    }

    func testNaming() {
        XCTAssertEqual(ArchiveNaming.providerSlug("  St. Mary's   Hospital / ER "), "St-Mary-s-Hospital-ER")
        XCTAssertEqual(ArchiveNaming.providerSlug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ArchiveNaming.providerSlug("診療所"), "Unknown")
        XCTAssertEqual(ArchiveNaming.providerSlug(""), "Unknown")
        XCTAssertLessThanOrEqual(ArchiveNaming.providerSlug(String(repeating: "Long Name ", count: 20)).count, 40)
        let name = ArchiveNaming.fileName(serviceDate: day("2026-01-02"), provider: "A/B", amountCents: 5,
                                          kind: .eob, id: UUID(), fileExtension: "../x")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasPrefix("2026-01-02_A-B_0.05_eob_"))
        XCTAssertTrue(name.hasSuffix(".x"))
    }

    func testDailyBackupHoldsThePreviousState() throws {
        let store = ArchiveStore(root: root)
        var ledger = Ledger()
        try store.save(ledger, today: day("2026-01-01"))
        XCTAssertTrue(store.backups().isEmpty, "Nothing to back up before the first save")

        ledger.save(Expense(serviceDate: day("2026-01-01"), provider: "First", amountCents: 100))
        try store.save(ledger, today: day("2026-01-02"))
        ledger.save(Expense(serviceDate: day("2026-01-02"), provider: "Second", amountCents: 200))
        try store.save(ledger, today: day("2026-01-02"))
        try store.save(ledger, today: day("2026-01-03"))

        let backups = store.backups()
        XCTAssertEqual(backups.map(\.day), [day("2026-01-03"), day("2026-01-02")])
        // The 01-02 snapshot is the ledger as it stood before that day's changes: empty.
        XCTAssertEqual(try ArchiveStore.decodeLedger(at: backups[1].url).expenses.count, 0)
        XCTAssertEqual(try ArchiveStore.decodeLedger(at: backups[0].url).expenses.count, 2)
    }

    func testBackupsArePruned() throws {
        let store = ArchiveStore(root: root)
        let ledger = Ledger()
        var current = day("2020-01-01")
        for _ in 0..<(ArchiveStore.backupsToKeep + 15) {
            try store.save(ledger, today: current)
            let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: current.date())!
            current = DayDate(date: next)
        }
        XCTAssertEqual(store.backups().count, ArchiveStore.backupsToKeep)
    }

    func testRestoreKeepsTheReplacedLedger() throws {
        let store = ArchiveStore(root: root)
        var ledger = Ledger()
        ledger.save(Expense(serviceDate: day("2026-01-01"), provider: "Keep me", amountCents: 100))
        try store.save(ledger, today: day("2026-01-01"))
        try store.save(ledger, today: day("2026-01-02"))
        try Data("{ not json".utf8).write(to: store.ledgerURL)
        XCTAssertThrowsError(try store.loadLedger()) { error in
            guard case ArchiveStore.StoreError.unreadable = error else { return XCTFail("\(error)") }
        }
        let backup = try XCTUnwrap(store.backups().first)
        let restored = try store.restore(backup)
        XCTAssertEqual(restored.expenses.map(\.provider), ["Keep me"])
        XCTAssertEqual(try store.loadLedger().expenses.count, 1)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)
        XCTAssertTrue(kept.contains { $0.hasPrefix("replaced-") })
        // The set-aside file is not mistaken for a daily backup.
        XCTAssertFalse(store.backups().contains { $0.url.lastPathComponent.hasPrefix("replaced-") })
    }

    func testNewerSchemaIsRefusedAndNotOverwritten() throws {
        let store = ArchiveStore(root: root)
        let future = "{\"schemaVersion\": 99, \"somethingNew\": true}"
        try Data(future.utf8).write(to: store.ledgerURL)
        XCTAssertThrowsError(try store.loadLedger()) { error in
            XCTAssertEqual(error as? ArchiveStore.StoreError, .newerSchema(found: 99))
        }
        XCTAssertEqual(try String(contentsOf: store.ledgerURL, encoding: .utf8), future)
    }

    func testUnknownEnumValuesDoNotBreakLoading() throws {
        let store = ArchiveStore(root: root)
        var ledger = Ledger(settings: LedgerSettings(people: [Person(name: "Pat", relationship: .dependent)]))
        ledger.save(Expense(serviceDate: day("2026-01-01"), provider: "P", category: .dental, amountCents: 100))
        try store.save(ledger)
        var text = try String(contentsOf: store.ledgerURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"dental\"", with: "\"acupuncture\"")
        text = text.replacingOccurrences(of: "\"dependent\"", with: "\"grandchild\"")
        try Data(text.utf8).write(to: store.ledgerURL)
        let loaded = try store.loadLedger()
        XCTAssertEqual(loaded.expenses[0].category, .other)
        XCTAssertEqual(loaded.settings.people[0].relationship, .other)
    }

    func testVerifyFindsMissingChangedAndUntrackedFiles() throws {
        let store = ArchiveStore(root: root)
        var ledger = Ledger()
        var expense = Expense(serviceDate: day("2026-05-01"), provider: "Clinic", amountCents: 5_000)
        let a = try store.storeDocument(Data("one".utf8), kind: .receipt, originalName: "a", fileExtension: "txt",
                                        serviceDate: expense.serviceDate, provider: expense.provider, amountCents: 5_000)
        let b = try store.storeDocument(Data("two".utf8), kind: .eob, originalName: "b", fileExtension: "txt",
                                        serviceDate: expense.serviceDate, provider: expense.provider, amountCents: 5_000)
        let c = try store.storeDocument(Data("three".utf8), kind: .other, originalName: "c", fileExtension: "txt",
                                        serviceDate: expense.serviceDate, provider: expense.provider, amountCents: 5_000)
        expense.attachments = [a, b, c]
        ledger.save(expense)
        XCTAssertTrue(store.verify(ledger).isClean)
        XCTAssertEqual(store.verify(ledger).checkedCount, 3)

        try FileManager.default.removeItem(at: store.url(for: a))
        try Data("tampered".utf8).write(to: store.url(for: b))
        try Data("stray".utf8).write(to: root.appendingPathComponent("Documents/2026/stray.txt"))
        let report = store.verify(ledger)
        XCTAssertEqual(report.issues.count, 2)
        XCTAssertEqual(report.issues.first { $0.attachment.id == a.id }?.kind, .missing)
        XCTAssertEqual(report.issues.first { $0.attachment.id == b.id }?.kind, .changed)
        XCTAssertEqual(report.untrackedPaths, ["Documents/2026/stray.txt"])
    }

    func testSetAsideMovesRatherThanDeletes() throws {
        let store = ArchiveStore(root: root)
        let a = try store.storeDocument(Data("keep".utf8), kind: .receipt, originalName: "a", fileExtension: "txt",
                                        serviceDate: day("2026-05-01"), provider: "Clinic", amountCents: 100)
        store.setAside([a])
        XCTAssertFalse(store.fileExists(for: a))
        let removed = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Removed").path)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Removed").appendingPathComponent(removed[0])), Data("keep".utf8))
    }

    func testMirrorIsAdditiveAndIncremental() throws {
        let store = ArchiveStore(root: root.appendingPathComponent("archive"))
        let destination = root.appendingPathComponent("mirror")
        let today = day("2026-11-20")
        var ledger = DemoData.ledger(today: today, store: store) { e, k in (Data("\(e.id) \(k)".utf8), "txt") }
        try store.save(ledger, today: today)

        let first = try store.mirror(to: destination)
        XCTAssertGreaterThan(first.copied, 20)
        XCTAssertEqual(first.failed, 0)
        let mirrored = ArchiveStore(root: destination)
        XCTAssertEqual(try mirrored.loadLedger(), ledger)
        XCTAssertTrue(mirrored.verify(ledger).isClean)

        let second = try store.mirror(to: destination)
        XCTAssertEqual(second.copied, 0)
        XCTAssertEqual(second.unchanged, first.copied)

        // Removing a document from the archive leaves the mirror's copy alone.
        let victim = ledger.expenses[0].attachments[0]
        store.setAside([victim])
        ledger.expenses[0].attachments.removeFirst()
        try store.save(ledger, today: today)
        _ = try store.mirror(to: destination)
        XCTAssertTrue(mirrored.fileExists(for: victim))
        XCTAssertEqual(try mirrored.loadLedger(), ledger)
    }
}

final class CSVTests: XCTestCase {
    func testFieldEscaping() {
        XCTAssertEqual(CSVExport.field("plain"), "plain")
        XCTAssertEqual(CSVExport.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExport.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExport.field("two\nlines"), "\"two\nlines\"")
        // Spreadsheet formula injection is neutralised.
        XCTAssertEqual(CSVExport.field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CSVExport.field("+1"), "'+1")
        XCTAssertEqual(CSVExport.field("@cmd"), "'@cmd")
    }

    func testExpenseAndWithdrawalRows() throws {
        var ledger = Ledger(settings: LedgerSettings(people: [Person(name: "Sam", relationship: .spouse)]))
        let e = Expense(serviceDate: DayDate(iso: "2024-06-15")!, provider: "Smith, Jones & Co", personID: ledger.settings.people[0].id,
                        category: .dental, amountCents: 42_000, note: "Crown \"upper\"")
        ledger.save(e)
        try ledger.save(Withdrawal(date: DayDate(iso: "2025-01-01")!, amountCents: 10_000, allocations: [Allocation(expenseID: e.id, cents: 10_000)]))
        let expenses = CSVExport.expenses(ledger).components(separatedBy: "\r\n")
        XCTAssertEqual(expenses.count, 3)
        XCTAssertTrue(expenses[0].hasPrefix("Date of service,Provider,For,Category,Amount paid"))
        XCTAssertTrue(expenses[1].hasPrefix("2024-06-15,\"Smith, Jones & Co\",Sam,Dental,420.00,Out of pocket,100.00,320.00,Partly reimbursed,No,No,No,\"Crown \"\"upper\"\"\""))
        let withdrawals = CSVExport.withdrawals(ledger).components(separatedBy: "\r\n")
        XCTAssertTrue(withdrawals[1].hasPrefix("2025-01-01,100.00,100.00,0.00,,\"2024-06-15 Smith, Jones & Co 100.00\","))
    }
}

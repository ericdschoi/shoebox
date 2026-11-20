import Foundation

/// Reads and writes the archive folder.
///
/// The archive is deliberately plain: one `ledger.json`, spreadsheet copies of it, and the original
/// documents in dated folders. Everything in it can be read without this app.
public struct ArchiveStore: Sendable {
    public static let ledgerFileName = "ledger.json"
    public static let expensesCSVName = "expenses.csv"
    public static let withdrawalsCSVName = "withdrawals.csv"
    public static let readmeName = "README.txt"
    public static let documentsFolder = "Documents"
    public static let backupsFolder = "Backups"
    public static let removedFolder = "Removed"
    public static let backupsToKeep = 60

    public enum StoreError: Error, LocalizedError, Equatable {
        /// The ledger on disk was written by a newer version of the app. It must not be overwritten.
        case newerSchema(found: Int)
        case unreadable(reason: String)
        case emptyDocument

        public var errorDescription: String? {
            switch self {
            case .newerSchema:
                return "This archive was saved by a newer version of Shoebox. Update the app to open it."
            case .unreadable(let reason):
                return "The ledger file could not be read. \(reason)"
            case .emptyDocument:
                return "That document is empty."
            }
        }
    }

    public let root: URL
    private var fm: FileManager { FileManager.default }

    public init(root: URL) {
        self.root = root
    }

    public var ledgerURL: URL { root.appendingPathComponent(ArchiveStore.ledgerFileName) }
    public var expensesCSVURL: URL { root.appendingPathComponent(ArchiveStore.expensesCSVName) }
    public var withdrawalsCSVURL: URL { root.appendingPathComponent(ArchiveStore.withdrawalsCSVName) }
    private var backupsURL: URL { root.appendingPathComponent(ArchiveStore.backupsFolder, isDirectory: true) }

    // MARK: Ledger

    public var ledgerExists: Bool { fm.fileExists(atPath: ledgerURL.path) }

    /// Loads the ledger, or returns a fresh one if the archive is new.
    public func loadLedger() throws -> Ledger {
        guard ledgerExists else { return Ledger() }
        return try ArchiveStore.decodeLedger(at: ledgerURL)
    }

    public static func decodeLedger(at url: URL) throws -> Ledger {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(reason: error.localizedDescription)
        }
        struct Probe: Decodable { let schemaVersion: Int }
        if let probe = try? JSONDecoder().decode(Probe.self, from: data),
           probe.schemaVersion > Ledger.currentSchemaVersion {
            throw StoreError.newerSchema(found: probe.schemaVersion)
        }
        do {
            return try makeDecoder().decode(Ledger.self, from: data)
        } catch {
            throw StoreError.unreadable(reason: "It may be damaged.")
        }
    }

    /// Writes the ledger, its spreadsheet copies and the README. The JSON is written to a temporary
    /// file and swapped in, so a crash mid-save cannot leave half a ledger behind.
    public func save(_ ledger: Ledger, today: DayDate = .today()) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try snapshotBeforeSave(today: today)
        let data = try ArchiveStore.makeEncoder().encode(ledger)
        try data.write(to: ledgerURL, options: .atomic)
        // The spreadsheets and README are conveniences derived from the ledger; failing to write
        // them must not fail the save.
        try? Data(CSVExport.expenses(ledger).utf8).write(to: expensesCSVURL, options: .atomic)
        try? Data(CSVExport.withdrawals(ledger).utf8).write(to: withdrawalsCSVURL, options: .atomic)
        let readme = root.appendingPathComponent(ArchiveStore.readmeName)
        if !fm.fileExists(atPath: readme.path) {
            try? Data(ArchiveStore.readmeText.utf8).write(to: readme, options: .atomic)
        }
    }

    /// Keeps one copy of the ledger per day, as it stood before that day's first change.
    private func snapshotBeforeSave(today: DayDate) throws {
        guard ledgerExists else { return }
        let target = backupsURL.appendingPathComponent("ledger-\(today.iso).json")
        guard !fm.fileExists(atPath: target.path) else { return }
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try? fm.copyItem(at: ledgerURL, to: target)
        let all = backups()
        for stale in all.dropFirst(ArchiveStore.backupsToKeep) {
            try? fm.removeItem(at: stale.url)
        }
    }

    public struct Backup: Identifiable, Hashable, Sendable {
        public var url: URL
        public var day: DayDate
        public var id: URL { url }
    }

    /// Daily ledger snapshots, newest first.
    public func backups() -> [Backup] {
        let names = (try? fm.contentsOfDirectory(atPath: backupsURL.path)) ?? []
        return names.compactMap { name -> Backup? in
            guard name.hasPrefix("ledger-"), name.hasSuffix(".json") else { return nil }
            let iso = String(name.dropFirst("ledger-".count).dropLast(".json".count))
            guard let day = DayDate(iso: iso) else { return nil }
            return Backup(url: backupsURL.appendingPathComponent(name), day: day)
        }
        .sorted { $0.day > $1.day }
    }

    /// Replaces the ledger with a snapshot. The damaged or unwanted ledger is kept beside it, never deleted.
    public func restore(_ backup: Backup, now: Date = Date()) throws -> Ledger {
        let restored = try ArchiveStore.decodeLedger(at: backup.url)
        if ledgerExists {
            let stamp = Int(now.timeIntervalSince1970)
            let aside = backupsURL.appendingPathComponent("replaced-\(stamp).json")
            try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
            try? fm.moveItem(at: ledgerURL, to: aside)
        }
        let data = try ArchiveStore.makeEncoder().encode(restored)
        try data.write(to: ledgerURL, options: .atomic)
        return restored
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Documents

    public func url(for attachment: Attachment) -> URL {
        var url = root
        for part in attachment.relativePath.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }

    public func fileExists(for attachment: Attachment) -> Bool {
        fm.fileExists(atPath: url(for: attachment).path)
    }

    /// Copies a document into the archive under a readable, dated name and records its checksum.
    public func storeDocument(_ data: Data, kind: AttachmentKind, originalName: String, fileExtension: String,
                              serviceDate: DayDate, provider: String, amountCents: Int,
                              id: UUID = UUID(), now: Date = Date()) throws -> Attachment {
        guard !data.isEmpty else { throw StoreError.emptyDocument }
        let name = ArchiveNaming.fileName(serviceDate: serviceDate, provider: provider, amountCents: amountCents,
                                          kind: kind, id: id, fileExtension: fileExtension)
        let folder = "\(ArchiveStore.documentsFolder)/\(serviceDate.year)"
        let folderURL = root.appendingPathComponent(ArchiveStore.documentsFolder, isDirectory: true)
            .appendingPathComponent(String(serviceDate.year), isDirectory: true)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let destination = folderURL.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        return Attachment(id: id, kind: kind, relativePath: "\(folder)/\(name)", originalName: originalName,
                          addedAt: now, sha256: SHA256Hasher.hash(data), byteCount: data.count)
    }

    /// Moves documents into `Removed/` instead of deleting them. An archive meant to last decades
    /// should never lose a file to a slip of the thumb.
    public func setAside(_ attachments: [Attachment]) {
        guard !attachments.isEmpty else { return }
        let removed = root.appendingPathComponent(ArchiveStore.removedFolder, isDirectory: true)
        try? fm.createDirectory(at: removed, withIntermediateDirectories: true)
        for a in attachments {
            let source = url(for: a)
            guard fm.fileExists(atPath: source.path) else { continue }
            var target = removed.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                target = removed.appendingPathComponent("\(a.id.uuidString.prefix(8))-\(source.lastPathComponent)")
            }
            try? fm.moveItem(at: source, to: target)
        }
    }

    // MARK: Integrity

    public struct IntegrityIssue: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// The ledger lists the document but the file is gone.
            case missing
            /// The file exists but its contents no longer match the recorded checksum.
            case changed
        }
        public var kind: Kind
        public var expenseID: UUID
        public var attachment: Attachment
        public var id: UUID { attachment.id }
    }

    public struct IntegrityReport: Hashable, Sendable {
        public var checkedCount: Int
        public var issues: [IntegrityIssue]
        /// Files in `Documents/` that no expense refers to.
        public var untrackedPaths: [String]
        public var isClean: Bool { issues.isEmpty }
    }

    /// Re-reads every document and compares it with the checksum recorded when it was added.
    public func verify(_ ledger: Ledger) -> IntegrityReport {
        var issues: [IntegrityIssue] = []
        var checked = 0
        var tracked = Set<String>()
        for e in ledger.expenses {
            for a in e.attachments {
                checked += 1
                tracked.insert(a.relativePath)
                let fileURL = url(for: a)
                guard fm.fileExists(atPath: fileURL.path) else {
                    issues.append(IntegrityIssue(kind: .missing, expenseID: e.id, attachment: a))
                    continue
                }
                let actual = try? SHA256Hasher.hash(fileAt: fileURL)
                if actual != a.sha256 {
                    issues.append(IntegrityIssue(kind: .changed, expenseID: e.id, attachment: a))
                }
            }
        }
        let untracked = relativeFiles(under: ArchiveStore.documentsFolder).filter { !tracked.contains($0) }.sorted()
        return IntegrityReport(checkedCount: checked, issues: issues, untrackedPaths: untracked)
    }

    // MARK: Mirror

    public struct MirrorReport: Hashable, Sendable {
        public var copied: Int
        public var unchanged: Int
        public var failed: Int
    }

    /// Copies the archive into another folder, such as one in iCloud Drive. One-way and additive:
    /// files are added or refreshed in the destination and never deleted from it.
    public func mirror(to destination: URL) throws -> MirrorReport {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var report = MirrorReport(copied: 0, unchanged: 0, failed: 0)
        for relative in relativeFiles(under: "") {
            var source = root
            var target = destination
            for part in relative.split(separator: "/") {
                source.appendPathComponent(String(part))
                target.appendPathComponent(String(part))
            }
            if isSameFile(source, target) {
                report.unchanged += 1
                continue
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Data(contentsOf: source)
                try data.write(to: target, options: .atomic)
                if let modified = try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date {
                    try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
                }
                report.copied += 1
            } catch {
                report.failed += 1
            }
        }
        return report
    }

    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let attrsA = try? fm.attributesOfItem(atPath: a.path),
              let attrsB = try? fm.attributesOfItem(atPath: b.path) else { return false }
        let sizeA = (attrsA[.size] as? NSNumber)?.int64Value
        let sizeB = (attrsB[.size] as? NSNumber)?.int64Value
        guard sizeA == sizeB, let dateA = attrsA[.modificationDate] as? Date,
              let dateB = attrsB[.modificationDate] as? Date else { return false }
        return abs(dateA.timeIntervalSince(dateB)) < 2
    }

    /// Every regular, non-hidden file under a subfolder of the archive, as forward-slash relative paths.
    func relativeFiles(under subfolder: String) -> [String] {
        let base = subfolder.isEmpty ? root : root.appendingPathComponent(subfolder, isDirectory: true)
        guard let names = try? fm.subpathsOfDirectory(atPath: base.path) else { return [] }
        var result: [String] = []
        for name in names {
            let parts = name.split(separator: "/")
            if parts.contains(where: { $0.hasPrefix(".") }) { continue }
            var isDirectory: ObjCBool = false
            let full = base.appendingPathComponent(name).path
            guard fm.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            result.append(subfolder.isEmpty ? name : "\(subfolder)/\(name)")
        }
        return result
    }

    // MARK: README

    public static let readmeText = """
    SHOEBOX ARCHIVE
    ===============

    This folder holds records of medical expenses kept for a Health Savings Account (HSA).
    It was written by the Shoebox app, but nothing here needs the app to be read.

    What is in this folder
    ----------------------
    ledger.json       The complete record: every expense, every HSA withdrawal, and which
                      withdrawal reimbursed which expense. This file is the source of truth.
    expenses.csv      The same expenses as a spreadsheet. Rewritten on every change.
    withdrawals.csv   The same withdrawals as a spreadsheet. Rewritten on every change.
    Documents/        Receipts and Explanation of Benefits (EOB) statements, in one folder per
                      year of service. File names start with the date of service.
    Backups/          One copy of ledger.json per day on which something changed.
    Removed/          Documents that were removed from an expense. Kept in case that was a mistake.

    How to read ledger.json
    -----------------------
    It is plain JSON text. Amounts are whole cents (12345 means $123.45). Days are written
    YEAR-MONTH-DAY. Each document entry lists its path in this folder and a SHA-256 checksum
    of the file, which can be used to confirm the file has not changed since it was added.

    Why these records matter
    ------------------------
    A qualified medical expense paid with personal money can be reimbursed from an HSA tax-free
    at any later time, provided the expense was incurred after the HSA was established, was not
    reimbursed from anywhere else, and was not taken as a tax deduction. These records are the
    proof. Keep this folder, and keep a second copy somewhere else.
    """
}

public enum ArchiveNaming {
    /// `2031-03-04_Valley-Dental_125.00_receipt_a1b2c3.pdf`
    public static func fileName(serviceDate: DayDate, provider: String, amountCents: Int, kind: AttachmentKind,
                                id: UUID, fileExtension: String) -> String {
        let slug = providerSlug(provider)
        let short = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        var ext = fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if ext.isEmpty { ext = "dat" }
        return "\(serviceDate.iso)_\(slug)_\(Money.plain(cents: amountCents))_\(kind.rawValue)_\(short).\(ext)"
    }

    /// Keeps letters and digits, turns everything else into single hyphens, and caps the length.
    public static func providerSlug(_ provider: String) -> String {
        var out = ""
        var lastWasHyphen = true
        for scalar in provider.unicodeScalars {
            let isPlain = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            if isPlain {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "Unknown" : out
    }
}

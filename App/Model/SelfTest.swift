#if DEBUG
import UIKit
import PDFKit
import ShoeboxCore

/// Exercises the parts of the app a screenshot can't show: PDF exports, the image text-recognition
/// path, integrity checking and the backup mirror. Runs only with `-demo -selftest`, against the
/// throwaway sample archive, and writes its results to the Caches folder for the build to collect.
enum SelfTest {
    @MainActor
    static func run(model: AppModel) {
        let output = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ledger = model.ledger
        let store = model.store
        Task {
            var lines: [String] = []
            func check(_ name: String, _ passed: Bool, _ detail: String = "") {
                lines.append("\(passed ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            }

            // Withdrawal packet
            if let withdrawal = ledger.withdrawals.max(by: { $0.amountCents < $1.amountCents }),
               let url = try? Reports.withdrawalPacket(for: withdrawal, ledger: ledger, store: store),
               let packet = PDFDocument(url: url) {
                let expected = 1 + withdrawal.allocations.count
                    + withdrawal.allocations.compactMap { ledger.expense($0.expenseID) }.reduce(0) { $0 + $1.attachments.count }
                check("withdrawal packet page count", packet.pageCount == expected, "\(packet.pageCount) of \(expected)")
                try? FileManager.default.copyItem(at: url, to: output.appendingPathComponent("packet.pdf"))
            } else {
                check("withdrawal packet", false)
            }

            // Ledger report
            if let url = try? Reports.ledgerReport(ledger), let report = PDFDocument(url: url) {
                check("ledger report", report.pageCount >= 1, "\(report.pageCount) pages")
                try? FileManager.default.copyItem(at: url, to: output.appendingPathComponent("report.pdf"))
            } else {
                check("ledger report", false)
            }

            // Text recognition on a photographed receipt (no embedded text), through the same path a scan takes.
            let photo = receiptPhoto()
            if let draft = DocumentBuilder.draft(fromImage: photo) {
                let recognised = await TextRecognizer.lines(in: draft.data, fileExtension: draft.fileExtension)
                let guess = ReceiptParser.parse(lines: recognised, today: .today())
                check("photo: amount", guess.amountCents == 2484, "\(guess.amountCents ?? -1)")
                check("photo: date", guess.date == DayDate(year: 2026, month: 11, day: 14), guess.date?.iso ?? "nil")
                check("photo: provider", guess.provider == "Corner Pharmacy", guess.provider ?? "nil")
                lines.append("       recognised: \(recognised.joined(separator: " | "))")
                try? draft.data.write(to: output.appendingPathComponent("photo.jpg"))
            } else {
                check("photo: build draft", false)
            }
            if let scan = DocumentBuilder.draft(fromScannedPages: [photo, photo]) {
                let pages = PDFDocument(data: scan.data)?.pageCount ?? 0
                let recognised = await TextRecognizer.lines(in: scan.data, fileExtension: "pdf")
                let guess = ReceiptParser.parse(lines: recognised, today: .today())
                check("scan: two-page PDF", pages == 2, "\(pages) pages, \(scan.data.count / 1024) KB")
                check("scan: amount", guess.amountCents == 2484, "\(guess.amountCents ?? -1)")
            } else {
                check("scan: build PDF", false)
            }

            // Integrity and mirror
            let report = store.verify(ledger)
            check("integrity clean", report.isClean && report.untrackedPaths.isEmpty, "\(report.checkedCount) checked")
            let mirror = FileManager.default.temporaryDirectory.appendingPathComponent("SelfTestMirror-\(UUID().uuidString)")
            if let first = try? store.mirror(to: mirror), let second = try? store.mirror(to: mirror) {
                check("mirror copies everything", first.failed == 0 && first.copied > 0, "\(first.copied) copied")
                check("mirror is incremental", second.copied == 0, "\(second.unchanged) unchanged")
                check("mirror verifies", ArchiveStore(root: mirror).verify(ledger).isClean)
            } else {
                check("mirror", false)
            }

            // Saving through the app model, including filing a document.
            let before = model.ledger.totals.availableCents
            let expense = Expense(serviceDate: .today(), provider: "Self Test Clinic", amountCents: 1234)
            let saved = DocumentBuilder.draft(fromImage: photo).map { model.save(expense, adding: [$0]) } ?? false
            check("save expense with document", saved && model.ledger.totals.availableCents == before + 1234)
            let reloaded = try? store.loadLedger()
            check("saved ledger reloads identically", reloaded == model.ledger)

            try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// A receipt drawn as a picture, slightly rotated on a grey desk, to stand in for a camera photo.
    private static func receiptPhoto() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.35, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 600, y: 800)
            cg.rotate(by: 0.03)
            cg.translateBy(x: -600, y: -800)
            UIColor(white: 0.97, alpha: 1).setFill()
            cg.fill(CGRect(x: 180, y: 140, width: 840, height: 1320))
            let rows: [(String, String, CGFloat, UIFont.Weight)] = [
                ("CORNER PHARMACY", "", 54, .bold),
                ("1234 Ventura Blvd", "", 34, .regular),
                ("11/14/2026  3:42 PM", "", 34, .regular),
                ("", "", 34, .regular),
                ("ATORVASTATIN 20MG", "15.00", 36, .regular),
                ("IBUPROFEN 200MG", "8.99", 36, .regular),
                ("SUBTOTAL", "23.99", 36, .regular),
                ("TAX", "0.85", 36, .regular),
                ("TOTAL", "24.84", 44, .bold),
                ("VISA ****4417", "24.84", 34, .regular),
                ("THANK YOU", "", 34, .regular)
            ]
            var y: CGFloat = 220
            for row in rows {
                let font = UIFont(name: row.3 == .bold ? "Courier-Bold" : "Courier", size: row.2) ?? .systemFont(ofSize: row.2, weight: row.3)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.1, alpha: 1)]
                (row.0 as NSString).draw(at: CGPoint(x: 240, y: y), withAttributes: attributes)
                if !row.1.isEmpty {
                    let width = (row.1 as NSString).size(withAttributes: attributes).width
                    (row.1 as NSString).draw(at: CGPoint(x: 960 - width, y: y), withAttributes: attributes)
                }
                y += row.2 * 2.1
            }
        }
    }
}
#endif

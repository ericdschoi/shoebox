import UIKit
import PDFKit
import ShoeboxCore

/// A minimal page-layout helper for the PDFs the app produces: text flows down the page and a new
/// page starts when it runs out of room.
final class PageWriter {
    static let pageSize = CGSize(width: 612, height: 792) // US Letter, in points
    let margin: CGFloat = 54
    private let context: UIGraphicsPDFRendererContext
    private(set) var y: CGFloat = 0
    private var pageNumber = 0
    private let footer: String

    var contentWidth: CGFloat { PageWriter.pageSize.width - margin * 2 }

    init(context: UIGraphicsPDFRendererContext, footer: String) {
        self.context = context
        self.footer = footer
        newPage()
    }

    func newPage() {
        context.beginPage()
        pageNumber += 1
        y = margin
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray]
        let text = "\(footer)   ·   Page \(pageNumber)" as NSString
        text.draw(at: CGPoint(x: margin, y: PageWriter.pageSize.height - margin + 14), withAttributes: attributes)
    }

    func ensure(_ height: CGFloat) {
        if y + height > PageWriter.pageSize.height - margin { newPage() }
    }

    func space(_ amount: CGFloat) { y += amount }

    @discardableResult
    func text(_ string: String, font: UIFont = .systemFont(ofSize: 10.5), color: UIColor = .black,
              x: CGFloat? = nil, width: CGFloat? = nil, alignment: NSTextAlignment = .left, advance: Bool = true) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let w = width ?? contentWidth
        let bounds = (string as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: attributes, context: nil)
        let height = ceil(bounds.height)
        if advance { ensure(height) }
        (string as NSString).draw(with: CGRect(x: x ?? margin, y: y, width: w, height: height),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        if advance { y += height }
        return height
    }

    func rule(color: UIColor = UIColor(white: 0.8, alpha: 1)) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: margin + contentWidth, y: y))
        color.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    struct Column {
        var title: String
        var fraction: CGFloat
        var alignment: NSTextAlignment = .left
    }

    func row(_ values: [String], columns: [Column], font: UIFont, color: UIColor = .black) {
        var heights: [CGFloat] = []
        var x = margin
        let widths = columns.map { $0.fraction * contentWidth }
        // Measure first so a tall row moves to the next page as a whole.
        for (value, width) in zip(values, widths) {
            let bounds = (value as NSString).boundingRect(with: CGSize(width: width - 8, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                          attributes: [.font: font], context: nil)
            heights.append(ceil(bounds.height))
        }
        let rowHeight = (heights.max() ?? 12) + 8
        ensure(rowHeight)
        for (index, value) in values.enumerated() where index < columns.count {
            let savedY = y
            y += 4
            text(value, font: font, color: color, x: x + 4, width: widths[index] - 8, alignment: columns[index].alignment, advance: false)
            y = savedY
            x += widths[index]
        }
        y += rowHeight
        rule(color: UIColor(white: 0.9, alpha: 1))
    }

    func tableHeader(_ columns: [Column]) {
        row(columns.map(\.title), columns: columns, font: .systemFont(ofSize: 8.5, weight: .semibold), color: .darkGray)
    }
}

enum Reports {
    private static func temporaryURL(named name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private static func render(footer: String, _ draw: (PageWriter) -> Void) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PageWriter.pageSize))
        return renderer.pdfData { context in
            draw(PageWriter(context: context, footer: footer))
        }
    }

    private static func heading(_ page: PageWriter, title: String, subtitle: String) {
        page.text(title, font: .systemFont(ofSize: 22, weight: .bold))
        page.space(4)
        page.text(subtitle, font: .systemFont(ofSize: 11), color: .darkGray)
        page.space(16)
    }

    private static func fact(_ page: PageWriter, _ label: String, _ value: String) {
        page.ensure(18)
        page.text(label, font: .systemFont(ofSize: 10), color: .darkGray, width: 150, advance: false)
        page.text(value, font: .systemFont(ofSize: 10.5, weight: .medium), x: page.margin + 150, width: page.contentWidth - 150)
        page.space(5)
    }

    // MARK: Withdrawal packet

    /// A single PDF that documents one withdrawal: a cover sheet listing the expenses it reimbursed,
    /// followed by every receipt and EOB for those expenses. This is what you would hand over if asked.
    static func withdrawalPacket(for withdrawal: Withdrawal, ledger: Ledger, store: ArchiveStore) throws -> URL {
        let matched: [(Expense, Int)] = withdrawal.allocations.compactMap { allocation in
            ledger.expense(allocation.expenseID).map { ($0, allocation.cents) }
        }
        .sorted { $0.0.serviceDate < $1.0.serviceDate }
        let account = ledger.settings.accountLabel.isEmpty ? "Health Savings Account" : ledger.settings.accountLabel
        let footer = "HSA withdrawal record · \(withdrawal.date.iso) · \(Format.money(withdrawal.amountCents))"

        let cover = render(footer: footer) { page in
            heading(page, title: "HSA Withdrawal Record", subtitle: "Prepared with Shoebox on \(Format.dayLong(.today()))")
            fact(page, "Account", account)
            if let established = ledger.settings.establishedOn {
                fact(page, "HSA established", Format.dayLong(established))
            }
            fact(page, "Withdrawal date", Format.dayLong(withdrawal.date))
            fact(page, "Amount withdrawn", Format.money(withdrawal.amountCents))
            fact(page, "Matched to expenses", Format.money(withdrawal.allocatedCents))
            if withdrawal.unmatchedCents > 0 {
                fact(page, "Not matched", Format.money(withdrawal.unmatchedCents))
            }
            if !withdrawal.note.isEmpty { fact(page, "Note", withdrawal.note) }
            page.space(14)
            page.text("Expenses reimbursed by this withdrawal", font: .systemFont(ofSize: 13, weight: .semibold))
            page.space(8)
            let columns = [
                PageWriter.Column(title: "#", fraction: 0.05),
                PageWriter.Column(title: "DATE OF SERVICE", fraction: 0.16),
                PageWriter.Column(title: "PROVIDER", fraction: 0.29),
                PageWriter.Column(title: "FOR", fraction: 0.14),
                PageWriter.Column(title: "PAID", fraction: 0.12, alignment: .right),
                PageWriter.Column(title: "REIMBURSED HERE", fraction: 0.14, alignment: .right),
                PageWriter.Column(title: "DOCS", fraction: 0.10, alignment: .right)
            ]
            page.rule()
            page.tableHeader(columns)
            for (index, pair) in matched.enumerated() {
                let (expense, cents) = pair
                page.row(["\(index + 1)", expense.serviceDate.iso, expense.displayProvider,
                          ledger.person(expense.personID)?.name ?? "", Format.money(expense.amountCents),
                          Format.money(cents), "\(expense.attachments.count)"],
                         columns: columns, font: .systemFont(ofSize: 9.5))
            }
            page.space(18)
            page.text("""
            Each expense above was paid with personal funds after the HSA was established, has not been \
            reimbursed from any other source beyond the amounts recorded here, and has not been claimed as an \
            itemized deduction. Supporting documents follow in the order listed.
            """, font: .systemFont(ofSize: 9.5), color: .darkGray)
        }

        guard let packet = PDFDocument(data: cover) else { throw CocoaError(.fileWriteUnknown) }
        for (index, pair) in matched.enumerated() {
            let expense = pair.0
            let divider = render(footer: footer) { page in
                page.text("Expense \(index + 1) of \(matched.count)", font: .systemFont(ofSize: 10, weight: .semibold), color: .darkGray)
                page.space(6)
                page.text(expense.displayProvider, font: .systemFont(ofSize: 20, weight: .bold))
                page.space(12)
                fact(page, "Date of service", Format.dayLong(expense.serviceDate))
                fact(page, "For", ledger.person(expense.personID)?.name ?? "Not recorded")
                fact(page, "Category", expense.category.label)
                fact(page, "Amount paid", Format.money(expense.amountCents))
                fact(page, "Reimbursed by this withdrawal", Format.money(pair.1))
                fact(page, "Reimbursed in total", Format.money(ledger.reimbursedCents(for: expense.id)))
                if !expense.note.isEmpty { fact(page, "Note", expense.note) }
                page.space(12)
                page.text("Documents", font: .systemFont(ofSize: 13, weight: .semibold))
                page.space(6)
                if expense.attachments.isEmpty {
                    page.text("No documents are attached to this expense.", color: .darkGray)
                }
                for attachment in expense.attachments {
                    page.text("\(attachment.kind.longLabel) — \(attachment.relativePath)", font: .systemFont(ofSize: 9.5))
                    page.text("SHA-256 \(attachment.sha256)", font: .monospacedSystemFont(ofSize: 7.5, weight: .regular), color: .darkGray)
                    page.space(6)
                }
            }
            append(PDFDocument(data: divider), to: packet)
            for attachment in expense.attachments {
                let url = store.url(for: attachment)
                if attachment.fileExtension == "pdf" {
                    append(PDFDocument(url: url), to: packet)
                } else if let image = UIImage(contentsOfFile: url.path), let page = PDFPage(image: image) {
                    packet.insert(page, at: packet.pageCount)
                }
            }
        }
        let url = temporaryURL(named: "HSA withdrawal \(withdrawal.date.iso).pdf")
        try? FileManager.default.removeItem(at: url)
        guard packet.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func append(_ source: PDFDocument?, to target: PDFDocument) {
        guard let source else { return }
        for index in 0..<source.pageCount {
            // Copy the page so the source document can be released.
            if let page = source.page(at: index)?.copy() as? PDFPage {
                target.insert(page, at: target.pageCount)
            }
        }
    }

    // MARK: Full report

    /// A printable list of every expense and where it stands.
    static func ledgerReport(_ ledger: Ledger) throws -> URL {
        let totals = ledger.totals
        let data = render(footer: "HSA expense record · \(DayDate.today().iso)") { page in
            heading(page, title: "HSA Expense Record", subtitle: "Prepared with Shoebox on \(Format.dayLong(.today()))")
            fact(page, "Account", ledger.settings.accountLabel.isEmpty ? "Health Savings Account" : ledger.settings.accountLabel)
            if let established = ledger.settings.establishedOn {
                fact(page, "HSA established", Format.dayLong(established))
            }
            fact(page, "Paid out of pocket", Format.money(totals.outOfPocketCents))
            fact(page, "Reimbursed so far", Format.money(totals.reimbursedCents))
            fact(page, "Available to reimburse", Format.money(totals.availableCents))
            page.space(14)
            let columns = [
                PageWriter.Column(title: "DATE OF SERVICE", fraction: 0.15),
                PageWriter.Column(title: "PROVIDER", fraction: 0.29),
                PageWriter.Column(title: "FOR", fraction: 0.12),
                PageWriter.Column(title: "PAID", fraction: 0.12, alignment: .right),
                PageWriter.Column(title: "REIMBURSED", fraction: 0.13, alignment: .right),
                PageWriter.Column(title: "STATUS", fraction: 0.19, alignment: .right)
            ]
            page.rule()
            page.tableHeader(columns)
            for expense in ledger.expenses.sorted(by: { $0.serviceDate < $1.serviceDate }) {
                page.row([expense.serviceDate.iso, expense.displayProvider, ledger.person(expense.personID)?.name ?? "",
                          Format.money(expense.amountCents),
                          Format.money(min(expense.amountCents, ledger.reimbursedCents(for: expense.id))),
                          ledger.status(of: expense).label],
                         columns: columns, font: .systemFont(ofSize: 9.5))
            }
        }
        let url = temporaryURL(named: "HSA expense record \(DayDate.today().iso).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Sample documents

    /// Draws a stand-in receipt or EOB for the demo archive. Clearly marked as a sample.
    static func sampleDocument(for expense: Expense, kind: AttachmentKind) -> Data {
        let size = CGSize(width: 420, height: 560)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            context.beginPage()
            func draw(_ string: String, _ y: CGFloat, size: CGFloat = 11, weight: UIFont.Weight = .regular,
                      color: UIColor = .black, alignment: NSTextAlignment = .left) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                (string as NSString).draw(in: CGRect(x: 32, y: y, width: 356, height: 40),
                                          withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                           .foregroundColor: color, .paragraphStyle: paragraph])
            }
            let amount = Format.money(expense.amountCents)
            if kind == .eob {
                draw("Blue River Health Plan", 32, size: 17, weight: .bold)
                draw("Explanation of Benefits", 58, size: 12, color: .darkGray)
                draw("THIS IS NOT A BILL", 78, size: 9, weight: .semibold, color: .gray)
                draw("Provider: \(expense.displayProvider)", 120)
                draw("Service date: \(expense.serviceDate.iso)", 140)
                draw("Billed", 190, color: .darkGray); draw(Format.money(expense.amountCents * 3), 190, alignment: .right)
                draw("Allowed", 212, color: .darkGray); draw(Format.money(expense.amountCents * 2), 212, alignment: .right)
                draw("Plan paid", 234, color: .darkGray); draw(Format.money(expense.amountCents), 234, alignment: .right)
                draw("You owe", 266, size: 13, weight: .semibold); draw(amount, 266, size: 13, weight: .semibold, alignment: .right)
            } else {
                draw(expense.displayProvider, 32, size: 17, weight: .bold, alignment: .center)
                draw("Receipt", 58, size: 12, color: .darkGray, alignment: .center)
                draw("Date of service: \(expense.serviceDate.iso)", 110)
                draw(expense.category.label, 150, color: .darkGray); draw(amount, 150, alignment: .right)
                draw("Total paid", 190, size: 13, weight: .semibold); draw(amount, 190, size: 13, weight: .semibold, alignment: .right)
                draw("Thank you", 250, color: .gray, alignment: .center)
            }
            draw("SAMPLE — NOT A REAL DOCUMENT", 520, size: 8, weight: .semibold, color: .lightGray, alignment: .center)
        }
    }
}

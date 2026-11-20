import SwiftUI
import QuickLook
import ShoeboxCore

struct ExpenseDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var expenseID: UUID
    /// Open on iPhone Duo: documents are shown at the width of the pane, not as small thumbnails.
    var showsLargeDocuments = false

    @State private var captureSource: CaptureSource?
    @State private var captureKind: AttachmentKind = .receipt
    @State private var previewURL: URL?
    @State private var confirmingDelete = false
    @State private var removing: Attachment?

    var body: some View {
        Group {
            if let expense = model.ledger.expense(expenseID) {
                content(expense)
            } else {
                ContentUnavailableView("Expense not found", systemImage: "questionmark.folder",
                                       description: Text("It may have been deleted."))
            }
        }
        .background(Color.screenBackground)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .documentCapture(source: $captureSource) { drafts in
            guard let expense = model.ledger.expense(expenseID) else { return }
            let tagged = drafts.map { draft -> DraftDocument in
                var copy = draft
                copy.kind = captureKind
                return copy
            }
            if model.save(expense, adding: tagged) {
                Haptics.success()
                model.show(tagged.count == 1 ? "\(captureKind.label) added" : "\(tagged.count) documents added")
            }
        }
    }

    private func content(_ expense: Expense) -> some View {
        let status = model.ledger.status(of: expense)
        let remaining = model.ledger.remainingCents(for: expense)
        return ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                header(expense, status: status)
                if showsLargeDocuments, !expense.attachments.isEmpty {
                    largeDocuments(expense)
                }
                if status == .ineligible || status == .paidFromHSA {
                    eligibilityNote(expense)
                }
                if status != .ineligible {
                    paperwork(expense)
                }
                documents(expense)
                details(expense)
                reimbursements(expense)
                if remaining > 0 {
                    Button {
                        model.sheet = .newWithdrawal(expenseID: expense.id)
                    } label: {
                        Label("Reimburse \(Format.money(remaining))", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 28)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit") { model.sheet = .editExpense(expense.id) }
                Menu {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete expense", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this expense?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete expense", role: .destructive) {
                dismiss()
                model.deleteExpense(expense.id)
            }
        } message: {
            if model.ledger.reimbursedCents(for: expense.id) > 0 {
                Text("\(Format.money(model.ledger.reimbursedCents(for: expense.id))) of it was reimbursed. That part of the withdrawal will no longer be matched to an expense. Its documents are moved to the Removed folder, not erased.")
            } else {
                Text("Its documents are moved to the Removed folder in your archive, not erased.")
            }
        }
        .confirmationDialog("Remove this document?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { model.removeAttachment(removing.id, from: expense.id) }
                removing = nil
            }
        } message: {
            Text("The file is moved to the Removed folder in your archive, not erased.")
        }
    }

    // MARK: Header

    private func header(_ expense: Expense, status: ExpenseStatus) -> some View {
        let reimbursed = min(expense.amountCents, model.ledger.reimbursedCents(for: expense.id))
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    CategoryIcon(category: expense.category, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.displayProvider)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle(expense))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .lastTextBaseline) {
                    HeroAmount(cents: expense.amountCents, size: 40)
                    Spacer()
                    StatusBadge(status: status)
                }
                if status == .partiallyReimbursed {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(reimbursed), total: Double(max(expense.amountCents, 1)))
                            .tint(Color.brand)
                        Text("\(Format.money(reimbursed)) reimbursed · \(Format.money(expense.amountCents - reimbursed)) still available")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func subtitle(_ expense: Expense) -> String {
        var parts = [Format.dayLong(expense.serviceDate)]
        if let person = model.ledger.person(expense.personID) { parts.append(person.name) }
        return parts.joined(separator: " · ")
    }

    private func eligibilityNote(_ expense: Expense) -> some View {
        let text: String
        switch model.ledger.eligibility(of: expense) {
        case .paidFromHSA:
            text = "This was paid straight from your HSA, so there is nothing left to reimburse. It's kept here for your records."
        case .beforeEstablishment:
            let established = model.ledger.settings.establishedOn.map(Format.dayLong) ?? "your HSA was established"
            text = "This expense is dated before \(established), so it can't be reimbursed from your HSA."
        case .claimedAsDeduction:
            text = "You marked this as taken as a tax deduction, so it can't also be reimbursed tax-free."
        case .eligible:
            text = ""
        }
        return Card {
            Label {
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Paperwork

    private func paperwork(_ expense: Expense) -> some View {
        let hasReceipt = expense.attachments.contains { $0.kind == .receipt }
        let hasEOB = expense.attachments.contains { $0.kind == .eob }
        return Card(padding: 0) {
            VStack(spacing: 0) {
                checklistRow(title: "Receipt", detail: "Itemized proof of what you paid", done: hasReceipt, kind: .receipt)
                Divider().padding(.leading, 54)
                if expense.insuranceNotInvolved {
                    HStack(spacing: 12) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Explanation of Benefits").font(.body.weight(.medium))
                            Text("Not needed: insurance wasn't involved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Undo") { model.setInsuranceNotInvolved(false, for: expense.id) }
                            .font(.subheadline)
                    }
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 13)
                } else {
                    checklistRow(title: "Explanation of Benefits", detail: "Shows what insurance did and didn't pay", done: hasEOB, kind: .eob)
                    if !hasEOB {
                        Divider().padding(.leading, 54)
                        Button {
                            model.setInsuranceNotInvolved(true, for: expense.id)
                        } label: {
                            Text("Insurance wasn't involved")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 54)
                                .padding(.trailing, Metrics.cardPadding)
                                .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
    }

    private func checklistRow(title: String, detail: String, done: Bool, kind: AttachmentKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(done ? Color.brand : Color.attention)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(done ? "On file" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Menu {
                    CaptureMenuItems { source in
                        captureKind = kind
                        captureSource = source
                    }
                } label: {
                    Text("Add")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.brandSoft, in: Capsule())
                }
                .accessibilityLabel("Add \(title)")
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }

    // MARK: Documents

    private func preview(_ attachment: Attachment) {
        let url = model.store.url(for: attachment)
        if FileManager.default.fileExists(atPath: url.path) {
            previewURL = url
        } else {
            model.show("That file is missing from the archive", style: .warning)
        }
    }

    /// Each document's first page at the width of the pane, so it can be read beside the amounts.
    private func largeDocuments(_ expense: Expense) -> some View {
        VStack(spacing: 12) {
            ForEach(expense.attachments) { attachment in
                Button {
                    preview(attachment)
                } label: {
                    LargeAttachmentPreview(attachment: attachment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(attachment.kind.label), open full screen")
            }
        }
    }

    private func documents(_ expense: Expense) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Documents")
                .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(expense.attachments) { attachment in
                        Button {
                            preview(attachment)
                        } label: {
                            AttachmentThumbnail(attachment: attachment)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Picker("Type", selection: Binding(get: { attachment.kind },
                                                             set: { model.setKind($0, for: attachment.id, in: expense.id) })) {
                                ForEach(AttachmentKind.allCases, id: \.self) { kind in
                                    Label(kind.longLabel, systemImage: kind.symbol).tag(kind)
                                }
                            }
                            ShareLink(item: model.store.url(for: attachment)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                removing = attachment
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    Menu {
                        Section("Add a receipt") {
                            CaptureMenuItems { source in
                                captureKind = .receipt
                                captureSource = source
                            }
                        }
                        Section("Add something else") {
                            Button {
                                captureKind = .eob
                                captureSource = .files
                            } label: { Label("EOB from Files", systemImage: "doc.text.magnifyingglass") }
                            Button {
                                captureKind = .other
                                captureSource = .files
                            } label: { Label("Other file", systemImage: "doc") }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.title2.weight(.medium))
                            Text("Add")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.brand)
                        .frame(width: 104, height: 104 * 1.3)
                        .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.brand.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    .accessibilityLabel("Add document")
                }
                .padding(.horizontal, 2)
            }
            if !expense.attachments.isEmpty {
                Text("Touch and hold a document to change its type, share it or remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Details

    private func details(_ expense: Expense) -> some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                detailRow("Category", expense.category.label)
                Divider().padding(.leading, Metrics.cardPadding)
                detailRow("For", model.ledger.person(expense.personID)?.name ?? "Not set")
                Divider().padding(.leading, Metrics.cardPadding)
                detailRow("Paid with", expense.paidFrom == .hsa ? "HSA" : "Personal funds")
                if expense.claimedAsDeduction {
                    Divider().padding(.leading, Metrics.cardPadding)
                    detailRow("Tax deduction", "Claimed")
                }
                if !expense.note.isEmpty {
                    Divider().padding(.leading, Metrics.cardPadding)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Note")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(expense.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    // MARK: Reimbursements

    @ViewBuilder
    private func reimbursements(_ expense: Expense) -> some View {
        let entries: [(Withdrawal, Int)] = model.ledger.withdrawals.compactMap { withdrawal in
            let cents = withdrawal.allocations.filter { $0.expenseID == expense.id }.reduce(0) { $0 + $1.cents }
            return cents > 0 ? (withdrawal, cents) : nil
        }
        .sorted { $0.0.date > $1.0.date }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Reimbursed")
                    .padding(.top, 6)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.0.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Withdrawal on \(Format.day(entry.0.date))")
                                        .font(.subheadline.weight(.medium))
                                    if !entry.0.note.isEmpty {
                                        Text(entry.0.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(Format.money(entry.1))
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, Metrics.cardPadding)
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

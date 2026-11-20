import SwiftUI
import QuickLook
import ShoeboxCore

/// The add and edit form. Built so that the common case, scanning a receipt, is: scan, glance, Save.
struct ExpenseEditor: View {
    enum Mode {
        case new(drafts: [DraftDocument])
        case edit(UUID)
    }

    private enum Field: Hashable {
        case amount, provider, note
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var loaded = false
    @State private var original: Expense?
    @State private var amountText = ""
    @State private var provider = ""
    @State private var date = Date()
    @State private var dateEdited = false
    @State private var personID: UUID?
    @State private var category: ExpenseCategory = .medical
    @State private var categoryEdited = false
    @State private var paidFromHSA = false
    @State private var insuranceNotInvolved = false
    @State private var claimedAsDeduction = false
    @State private var note = ""

    @State private var drafts: [DraftDocument] = []
    @State private var kept: [Attachment] = []
    @State private var removed: [Attachment] = []
    @State private var readDraftIDs = Set<UUID>()
    @State private var isReading = false
    @State private var candidates: [Int] = []
    @State private var filledFromScan = false
    @State private var dateNotFound = false

    @State private var captureSource: CaptureSource?
    @State private var previewURL: URL?
    @State private var confirmingDiscard = false
    @State private var duplicate: Expense?
    @FocusState private var focus: Field?

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var amountCents: Int? {
        guard let cents = Money.parseCents(amountText), cents > 0 else { return nil }
        return cents
    }

    private var serviceDay: DayDate { DayDate(date: date) }

    private var hasChanges: Bool {
        guard loaded else { return false }
        if isNew { return !drafts.isEmpty || !amountText.isEmpty || !provider.isEmpty || !note.isEmpty }
        guard let original else { return false }
        return !drafts.isEmpty || !removed.isEmpty || built(from: original) != original
    }

    var body: some View {
        NavigationStack {
            Form {
                documentsSection
                amountSection
                detailsSection
                moreSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "New expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(amountCents == nil)
                        .accessibilityIdentifier("save-expense")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .alert("Already filed?", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } })) {
                Button("Save anyway") {
                    duplicate = nil
                    save(allowingDuplicate: true)
                }
                Button("Cancel", role: .cancel) { duplicate = nil }
            } message: {
                if let duplicate {
                    Text("You already have \(Format.money(duplicate.amountCents)) at \(duplicate.displayProvider) on \(Format.day(duplicate.serviceDate)). Filing the same bill twice would overstate what you can withdraw.")
                }
            }
            .confirmationDialog("Discard this expense?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button(isNew ? "Discard expense" : "Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .quickLookPreview($previewURL)
        .documentCapture(source: $captureSource) { new in
            drafts.append(contentsOf: new)
            readNextDraft()
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var documentsSection: some View {
        Section {
            if drafts.isEmpty && kept.isEmpty {
                Menu {
                    CaptureMenuItems { captureSource = $0 }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.viewfinder")
                            .font(.title2)
                            .foregroundStyle(Color.brand)
                            .frame(width: 44, height: 44)
                            .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add a receipt")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("Shoebox fills in the details from it")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.brand)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(kept) { attachment in
                            AttachmentThumbnail(attachment: attachment, width: 84)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        kept.removeAll { $0.id == attachment.id }
                                        removed.append(attachment)
                                    } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                        ForEach($drafts) { $draft in
                            Menu {
                                Picker("Type", selection: $draft.kind) {
                                    ForEach(AttachmentKind.allCases, id: \.self) { kind in
                                        Label(kind.longLabel, systemImage: kind.symbol).tag(kind)
                                    }
                                }
                                Button { preview(draft) } label: { Label("View", systemImage: "eye") }
                                Button(role: .destructive) {
                                    drafts.removeAll { $0.id == draft.id }
                                } label: { Label("Remove", systemImage: "trash") }
                            } label: {
                                PaperThumbnail(image: draft.thumbnail, kind: draft.kind, width: 84)
                            } primaryAction: {
                                preview(draft)
                            }
                            .buttonStyle(.plain)
                        }
                        Menu {
                            CaptureMenuItems { captureSource = $0 }
                        } label: {
                            Image(systemName: "plus")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Color.brand)
                                .frame(width: 84, height: 84 * 1.3)
                                .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .accessibilityLabel("Add another document")
                    }
                    .padding(.vertical, 6)
                }
                if isReading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading your document…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if filledFromScan {
                    Label("Filled in from your document. Check it before saving.", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !drafts.isEmpty {
                Text("Tap a document to view it. Touch and hold to mark it as a receipt or an EOB.")
            }
        }
    }

    private var amountSection: some View {
        Section {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("$")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(amountText.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                    TextField("0.00", text: $amountText)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .amount)
                        .fixedSize()
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel("Amount you paid")
                        .accessibilityIdentifier("amount-field")
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { focus = .amount }
                if candidates.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(candidates, id: \.self) { cents in
                                let selected = amountCents == cents
                                Button(Format.money(cents)) {
                                    amountText = Money.plain(cents: cents)
                                    Haptics.tap()
                                }
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(selected ? Color.brandFill : Color(uiColor: .tertiarySystemFill), in: Capsule())
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("What you paid")
        } footer: {
            if !amountText.isEmpty && amountCents == nil {
                Text("Enter an amount like 125.00")
                    .foregroundStyle(Color.attention)
            } else if let original, let cents = amountCents, cents < model.ledger.reimbursedCents(for: original.id) {
                Text("\(Format.money(model.ledger.reimbursedCents(for: original.id))) of this expense has already been reimbursed. Saving a lower amount leaves the difference unmatched on that withdrawal.")
                    .foregroundStyle(Color.attention)
            } else if candidates.count > 1 {
                Text("Other amounts found on the document. Tap one if the first guess is wrong.")
            } else {
                Text("Your share after insurance, not the amount billed.")
            }
        }
    }

    private var detailsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Provider or pharmacy", text: $provider)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .provider)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .accessibilityIdentifier("provider-field")
                let suggestions = providerSuggestions
                if focus == .provider, !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { name in
                                Button(name) { choose(provider: name) }
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Color.brandSoft, in: Capsule())
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.brand)
                            }
                        }
                    }
                }
            }
            DatePicker("Date of service", selection: Binding(get: { date }, set: { date = $0; dateEdited = true; dateNotFound = false }),
                       in: ...Date(), displayedComponents: .date)
            if model.ledger.settings.people.count > 1 {
                Picker("For", selection: $personID) {
                    ForEach(model.ledger.settings.people) { person in
                        Text(person.name).tag(Optional(person.id))
                    }
                }
            }
            Picker("Category", selection: Binding(get: { category }, set: { category = $0; categoryEdited = true })) {
                ForEach(ExpenseCategory.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
        } footer: {
            if let established = model.ledger.settings.establishedOn, serviceDay < established {
                Label("This is before your HSA was established on \(Format.day(established)), so it can't be reimbursed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.attention)
            } else if dateNotFound {
                Label("Couldn't read a date from the document, so this is set to today. Change it to the date of service.",
                      systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(Color.attention)
            }
        }
    }

    private var moreSection: some View {
        Section {
            Toggle("Paid with my HSA card", isOn: $paidFromHSA)
            Toggle("Insurance wasn't involved", isOn: $insuranceNotInvolved)
            Toggle("Claimed as a tax deduction", isOn: $claimedAsDeduction)
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .focused($focus, equals: .note)
        } header: {
            Text("More")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if paidFromHSA {
                    Text("Already paid from your HSA, so this won't add to what you can withdraw. It's filed for your records.")
                } else if claimedAsDeduction {
                    Text("An expense you deducted on your taxes can't also be reimbursed tax-free.")
                } else if insuranceNotInvolved {
                    Text("Shoebox won't ask for an Explanation of Benefits for this one.")
                }
            }
        }
    }

    // MARK: Behaviour

    private var providerSuggestions: [String] {
        let typed = provider.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        var names: [String] = []
        for expense in model.ledger.expenses.sorted(by: { $0.serviceDate > $1.serviceDate }) {
            let name = expense.provider.trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            guard !name.isEmpty, key != typed, typed.isEmpty || key.contains(typed), !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
            if names.count == 6 { break }
        }
        return names
    }

    private func choose(provider name: String) {
        provider = name
        adoptHabits(for: name)
        focus = nil
        Haptics.tap()
    }

    /// A provider you've used before most likely means the same category and the same person.
    private func adoptHabits(for name: String) {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, let previous = model.ledger.expenses
            .filter({ $0.provider.trimmingCharacters(in: .whitespaces).lowercased() == key })
            .max(by: { $0.serviceDate < $1.serviceDate }) else { return }
        if !categoryEdited { category = previous.category }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .new(let initial):
            drafts = initial
            personID = model.ledger.settings.people.first?.id
            if initial.isEmpty {
                focus = .amount
            } else {
                readNextDraft()
            }
        case .edit(let id):
            guard let expense = model.ledger.expense(id) else { return }
            original = expense
            amountText = Money.plain(cents: expense.amountCents)
            provider = expense.provider
            date = expense.serviceDate.date()
            dateEdited = true
            personID = expense.personID
            category = expense.category
            categoryEdited = true
            paidFromHSA = expense.paidFrom == .hsa
            insuranceNotInvolved = expense.insuranceNotInvolved
            claimedAsDeduction = expense.claimedAsDeduction
            note = expense.note
            kept = expense.attachments
        }
    }

    /// Reads documents one at a time and fills in only the fields that are still blank.
    private func readNextDraft() {
        guard !isReading, let draft = drafts.first(where: { !readDraftIDs.contains($0.id) }) else { return }
        readDraftIDs.insert(draft.id)
        isReading = true
        Task {
            let lines = await TextRecognizer.lines(in: draft.data, fileExtension: draft.fileExtension)
            let guess = ReceiptParser.parse(lines: lines, today: .today())
            apply(guess, to: draft.id)
            isReading = false
            readNextDraft()
        }
    }

    private func apply(_ guess: ReceiptGuess, to draftID: UUID) {
        if guess.looksLikeEOB, let index = drafts.firstIndex(where: { $0.id == draftID }) {
            drafts[index].kind = .eob
        }
        guard isNew else { return }
        var filled = false
        if amountText.isEmpty, let cents = guess.amountCents {
            amountText = Money.plain(cents: cents)
            candidates = guess.amountCandidates
            filled = true
        }
        if provider.trimmingCharacters(in: .whitespaces).isEmpty, let name = guess.provider, !guess.looksLikeEOB {
            provider = name
            adoptHabits(for: name)
            filled = true
        }
        if !dateEdited {
            if let day = guess.date {
                date = day.date()
                dateEdited = true
                dateNotFound = false
                filled = true
            } else {
                dateNotFound = true
            }
        }
        if filled {
            withAnimation(.snappy) { filledFromScan = true }
            Haptics.tap()
        }
    }

    private func preview(_ draft: DraftDocument) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(draft.kind.label) \(draft.id.uuidString.prefix(6)).\(draft.fileExtension)")
        do {
            try draft.data.write(to: url, options: .atomic)
            previewURL = url
        } catch {
            model.show("Couldn't open the preview", style: .warning)
        }
    }

    private func built(from base: Expense) -> Expense {
        var expense = base
        expense.amountCents = amountCents ?? base.amountCents
        expense.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.serviceDate = serviceDay
        expense.personID = personID
        expense.category = category
        expense.paidFrom = paidFromHSA ? .hsa : .outOfPocket
        expense.insuranceNotInvolved = insuranceNotInvolved
        expense.claimedAsDeduction = claimedAsDeduction
        expense.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.attachments = kept
        return expense
    }

    private func save(allowingDuplicate: Bool = false) {
        guard let cents = amountCents else { return }
        focus = nil
        let base = original ?? Expense(serviceDate: serviceDay, provider: "", amountCents: cents)
        let expense = built(from: base)
        if isNew, !allowingDuplicate, let existing = model.ledger.possibleDuplicate(of: expense) {
            duplicate = existing
            Haptics.warning()
            return
        }
        let before = model.ledger.totals.availableCents
        guard model.save(expense, adding: drafts, removing: removed) else { return }
        Haptics.success()
        let gained = model.ledger.totals.availableCents - before
        if isNew, gained > 0 {
            model.show("Filed. \(Format.money(gained)) added to what you can withdraw")
        } else {
            model.show(isNew ? "Expense filed" : "Changes saved")
        }
        dismiss()
    }
}

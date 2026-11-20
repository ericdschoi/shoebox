import SwiftUI
import UniformTypeIdentifiers
import ShoeboxCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var accountLabel = ""
    @State private var share: ShareItem?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            Form {
                Section {
                    LabeledContent("Account name") {
                        TextField("Optional", text: $accountLabel)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit(commitLabel)
                    }
                    NavigationLink(value: SettingsRoute.established) {
                        LabeledContent("Established") {
                            Text(model.ledger.settings.establishedOn.map(Format.day) ?? "Not set")
                                .foregroundStyle(model.ledger.settings.establishedOn == nil ? Color.attention : Color.secondary)
                        }
                    }
                    NavigationLink(value: SettingsRoute.people) {
                        LabeledContent("People") {
                            Text(model.ledger.settings.people.map(\.name).joined(separator: ", "))
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Your HSA")
                } footer: {
                    if model.ledger.settings.establishedOn == nil {
                        Text("Set the date your HSA was established so Shoebox can tell which expenses are eligible.")
                    }
                }

                Section {
                    LabeledContent("On this iPhone") {
                        Text(recordsSummary)
                    }
                    Button {
                        openInFiles()
                    } label: {
                        Label("Show in Files", systemImage: "folder")
                    }
                    NavigationLink(value: SettingsRoute.backup) {
                        LabeledContent {
                            Text(model.mirrorName ?? "Off")
                                .foregroundStyle(model.hasMirror ? Color.secondary : Color.attention)
                        } label: {
                            Label("Backup folder", systemImage: "externaldrive.badge.icloud")
                        }
                    }
                    NavigationLink(value: SettingsRoute.integrity) {
                        Label("Check documents", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("Your archive")
                } footer: {
                    Text("Your records are ordinary files: a ledger, spreadsheets and your original documents. They stay readable without Shoebox.")
                }

                Section("Export") {
                    Button {
                        share = ShareItem(url: model.store.expensesCSVURL)
                    } label: {
                        Label("Expenses spreadsheet", systemImage: "tablecells")
                    }
                    .disabled(model.ledger.expenses.isEmpty)
                    Button {
                        if let url = try? Reports.ledgerReport(model.ledger) {
                            share = ShareItem(url: url)
                        } else {
                            model.show("Couldn't build the report", style: .warning)
                        }
                    } label: {
                        Label("Printable report", systemImage: "doc.richtext")
                    }
                    .disabled(model.ledger.expenses.isEmpty)
                }

                Section {
                    Toggle(isOn: $model.requiresUnlock) {
                        Label("Require Face ID", systemImage: "faceid")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Asks for Face ID, Touch ID or your passcode each time you open Shoebox. Nothing in the app is ever sent anywhere.")
                }

                Section {
                    NavigationLink(value: SettingsRoute.howItWorks) {
                        Label("How HSA reimbursement works", systemImage: "book")
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } footer: {
                    Text("Shoebox keeps records. It doesn't give tax advice; check the rules for your situation with a tax professional.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .established: EstablishedDateView()
                case .people: PeopleView()
                case .backup: BackupFolderView()
                case .integrity: IntegrityView()
                case .howItWorks: HowItWorksView()
                }
            }
            .onAppear { accountLabel = model.ledger.settings.accountLabel }
            .onDisappear(perform: commitLabel)
            .sheet(item: $share) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private var recordsSummary: String {
        let totals = model.ledger.totals
        let expenses = totals.expenseCount == 1 ? "1 expense" : "\(totals.expenseCount) expenses"
        let documents = totals.documentCount == 1 ? "1 document" : "\(totals.documentCount) documents"
        return "\(expenses), \(documents)"
    }

    private func commitLabel() {
        let trimmed = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.ledger.settings.accountLabel else { return }
        model.updateSettings { $0.accountLabel = trimmed }
    }

    private func openInFiles() {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = model.store.root.path
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Established date

struct EstablishedDateView: View {
    @Environment(AppModel.self) private var model
    @State private var isSet = false
    @State private var date = Date()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("I know the date", isOn: $isSet.animation())
                if isSet {
                    DatePicker("Established", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
            } footer: {
                Text("An HSA is usually established on the day it was opened and first funded. Expenses from before that day can't be reimbursed from it. Your HSA provider can confirm the date.")
            }
            if isSet {
                let day = DayDate(date: date)
                let affected = model.ledger.expenses.filter { $0.paidFrom == .outOfPocket && !$0.claimedAsDeduction && $0.serviceDate < day }.count
                if affected > 0 {
                    Section {
                        Label(affected == 1 ? "1 expense is dated before this and won't count toward what you can withdraw."
                              : "\(affected) expenses are dated before this and won't count toward what you can withdraw.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.attention)
                    }
                }
            }
        }
        .navigationTitle("HSA established")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let established = model.ledger.settings.establishedOn {
                isSet = true
                date = established.date()
            }
        }
        .onDisappear {
            let value = isSet ? DayDate(date: date) : nil
            if value != model.ledger.settings.establishedOn {
                model.updateSettings { $0.establishedOn = value }
            }
        }
    }
}

// MARK: - People

struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Person?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                ForEach(model.ledger.settings.people) { person in
                    Button {
                        editing = person
                    } label: {
                        LabeledContent {
                            Text(person.relationship.label)
                        } label: {
                            Text(person.name).foregroundStyle(.primary)
                        }
                    }
                    .swipeActions {
                        if !model.isPersonInUse(person.id), person.relationship != .accountHolder {
                            Button(role: .destructive) {
                                model.updateSettings { $0.people.removeAll { $0.id == person.id } }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    isAdding = true
                } label: {
                    Label("Add person", systemImage: "plus")
                }
            } footer: {
                Text("HSA money can generally be used for you, your spouse and your tax dependents. Someone with expenses on file can't be removed.")
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { person in
            PersonEditor(person: person, isNew: false)
        }
        .sheet(isPresented: $isAdding) {
            PersonEditor(person: Person(name: "", relationship: .dependent), isNew: true)
        }
    }
}

struct PersonEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var person: Person
    var isNew: Bool
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $person.name)
                    .textContentType(.givenName)
                    .focused($focused)
                if person.relationship != .accountHolder {
                    Picker("Relationship", selection: $person.relationship) {
                        ForEach([Person.Relationship.spouse, .dependent, .other], id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add person" : "Edit person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = person
                        saved.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.updateSettings { settings in
                            if let index = settings.people.firstIndex(where: { $0.id == saved.id }) {
                                settings.people[index] = saved
                            } else {
                                settings.people.append(saved)
                            }
                        }
                        dismiss()
                    }
                    .disabled(person.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = isNew }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Backup folder

struct BackupFolderView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.brand)
                    Text("A second copy, kept up to date")
                        .font(.title3.weight(.semibold))
                    Text("Pick a folder in iCloud Drive or another cloud app. Shoebox copies your whole archive there and adds to it whenever something changes. Files are only ever added to the backup, never deleted from it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
            if let name = model.mirrorName {
                Section {
                    LabeledContent("Folder", value: name)
                    LabeledContent("Last backed up") {
                        switch model.mirrorState {
                        case .running:
                            ProgressView()
                        case .failed:
                            Text("Failed").foregroundStyle(Color.attention)
                        case .idle:
                            Text(model.mirrorDate.map(Format.relative) ?? "Not yet")
                        }
                    }
                    Button("Back up now") { model.mirrorNow() }
                        .disabled(model.mirrorState == .running)
                } footer: {
                    if case .failed(let reason) = model.mirrorState {
                        Text(reason).foregroundStyle(Color.attention)
                    } else {
                        Text("Your records are saved in a folder called Shoebox Archive inside \(name).")
                    }
                }
                Section {
                    Button("Choose a different folder") { choosing = true }
                    Button("Turn off backup", role: .destructive) { model.removeMirrorFolder() }
                } footer: {
                    Text("Turning off backup leaves the copies already made where they are.")
                }
            } else {
                Section {
                    Button {
                        choosing = true
                    } label: {
                        Label("Choose a folder", systemImage: "folder.badge.plus")
                    }
                }
            }
        }
        .navigationTitle("Backup folder")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.setMirrorFolder(url)
            }
        }
    }
}

// MARK: - Integrity

struct IntegrityView: View {
    @Environment(AppModel.self) private var model
    @State private var report: ArchiveStore.IntegrityReport?

    var body: some View {
        List {
            if let report {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: report.isClean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(report.isClean ? Color.brand : Color.attention)
                        Text(headline(report))
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(report.isClean
                             ? "Every file matches the fingerprint recorded when it was added."
                             : "These files are missing or have changed since they were added. If you have a backup folder, the originals may still be there.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                if !report.issues.isEmpty {
                    Section("Needs a look") {
                        ForEach(report.issues) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.ledger.expense(issue.expenseID)?.displayProvider ?? "Unknown expense")
                                    .font(.subheadline.weight(.medium))
                                Text("\(issue.attachment.kind.label) · \(issue.kind == .missing ? "File is missing" : "File has changed")")
                                    .font(.caption)
                                    .foregroundStyle(Color.attention)
                                Text(issue.attachment.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                if !report.untrackedPaths.isEmpty {
                    Section {
                        ForEach(report.untrackedPaths, id: \.self) { path in
                            Text(path).font(.caption)
                        }
                    } header: {
                        Text("Files not linked to an expense")
                    } footer: {
                        Text("These are in your Documents folder but no expense refers to them. They're harmless.")
                    }
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking every document…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Check documents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let ledger = model.ledger
            let store = model.store
            report = await Task.detached(priority: .userInitiated) { store.verify(ledger) }.value
        }
    }

    private func headline(_ report: ArchiveStore.IntegrityReport) -> String {
        if report.checkedCount == 0 { return "No documents to check yet" }
        if report.isClean {
            return report.checkedCount == 1 ? "Your document is intact" : "All \(report.checkedCount) documents are intact"
        }
        return report.issues.count == 1 ? "1 document needs a look" : "\(report.issues.count) documents need a look"
    }
}

// MARK: - How it works

struct HowItWorksView: View {
    private let points: [(String, String, String)] = [
        ("1.circle.fill", "Pay medical bills with your own money",
         "Instead of using your HSA card, pay out of pocket and leave the HSA invested."),
        ("2.circle.fill", "Keep the proof",
         "For each expense keep an itemized receipt and, when insurance was involved, the Explanation of Benefits showing what you owed."),
        ("3.circle.fill", "Reimburse yourself whenever you like",
         "There is generally no deadline. Years later you can withdraw the total of your saved expenses tax-free."),
        ("checkmark.circle.fill", "What makes an expense count",
         "It was a qualified medical expense, incurred after your HSA was established, not reimbursed by anyone else, and not taken as a tax deduction.")
    ]

    var body: some View {
        List {
            Section {
                ForEach(points, id: \.1) { point in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: point.0)
                            .font(.title2)
                            .foregroundStyle(Color.brand)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.1).font(.headline)
                            Text(point.2)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("This is a general description of U.S. federal rules, not tax advice. States can treat HSAs differently, and rules change. Confirm the details for your situation with a tax professional or IRS Publication 969.")
                    .padding(.top, 8)
            }
        }
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

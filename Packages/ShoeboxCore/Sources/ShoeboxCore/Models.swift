import Foundation

// MARK: - People

public struct Person: Identifiable, Hashable, Codable, Sendable {
    public enum Relationship: String, Codable, CaseIterable, Sendable {
        case accountHolder = "self"
        case spouse
        case dependent
        case other

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Relationship(rawValue: raw) ?? .other
        }

        public var label: String {
            switch self {
            case .accountHolder: return "Me"
            case .spouse: return "Spouse"
            case .dependent: return "Dependent"
            case .other: return "Other"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var relationship: Relationship

    public init(id: UUID = UUID(), name: String, relationship: Relationship) {
        self.id = id
        self.name = name
        self.relationship = relationship
    }
}

// MARK: - Expenses

public enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case medical
    case dental
    case vision
    case pharmacy
    case mentalHealth
    case labImaging
    case equipment
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExpenseCategory(rawValue: raw) ?? .other
    }

    public var label: String {
        switch self {
        case .medical: return "Medical"
        case .dental: return "Dental"
        case .vision: return "Vision"
        case .pharmacy: return "Pharmacy"
        case .mentalHealth: return "Mental health"
        case .labImaging: return "Lab & imaging"
        case .equipment: return "Equipment & supplies"
        case .other: return "Other"
        }
    }
}

/// Where the money for an expense came from.
public enum PaymentSource: String, Codable, CaseIterable, Sendable {
    /// Paid with personal funds. This is what can be reimbursed from the HSA later.
    case outOfPocket
    /// Paid straight from the HSA (debit card or bill pay). Recorded for completeness; nothing left to reimburse.
    case hsa

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaymentSource(rawValue: raw) ?? .outOfPocket
    }
}

public enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case receipt
    case eob
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AttachmentKind(rawValue: raw) ?? .other
    }

    public var label: String {
        switch self {
        case .receipt: return "Receipt"
        case .eob: return "EOB"
        case .other: return "Other"
        }
    }
}

/// A document stored in the archive folder.
public struct Attachment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: AttachmentKind
    /// Path relative to the archive root, always with forward slashes.
    public var relativePath: String
    public var originalName: String
    public var addedAt: Date
    /// Lowercase hex SHA-256 of the file as stored, used to detect silent corruption later.
    public var sha256: String
    public var byteCount: Int

    public init(id: UUID = UUID(), kind: AttachmentKind, relativePath: String, originalName: String,
                addedAt: Date = Date(), sha256: String, byteCount: Int) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.originalName = originalName
        self.addedAt = addedAt
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public var fileExtension: String {
        (relativePath as NSString).pathExtension.lowercased()
    }
}

public struct Expense: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var serviceDate: DayDate
    public var provider: String
    public var personID: UUID?
    public var category: ExpenseCategory
    /// What was actually paid for this expense, after insurance.
    public var amountCents: Int
    public var paidFrom: PaymentSource
    public var note: String
    public var attachments: [Attachment]
    /// True when insurance never saw this expense (an over-the-counter purchase, say), so no EOB will exist.
    public var insuranceNotInvolved: Bool
    /// True when this expense was taken as an itemized medical deduction. It cannot also be reimbursed tax-free.
    public var claimedAsDeduction: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), serviceDate: DayDate, provider: String, personID: UUID? = nil,
                category: ExpenseCategory = .medical, amountCents: Int, paidFrom: PaymentSource = .outOfPocket,
                note: String = "", attachments: [Attachment] = [], insuranceNotInvolved: Bool = false,
                claimedAsDeduction: Bool = false, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.serviceDate = serviceDate
        self.provider = provider
        self.personID = personID
        self.category = category
        self.amountCents = amountCents
        self.paidFrom = paidFrom
        self.note = note
        self.attachments = attachments
        self.insuranceNotInvolved = insuranceNotInvolved
        self.claimedAsDeduction = claimedAsDeduction
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var displayProvider: String {
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed provider" : trimmed
    }
}

// MARK: - Withdrawals

/// The part of a withdrawal that reimburses one expense.
public struct Allocation: Hashable, Codable, Sendable {
    public var expenseID: UUID
    public var cents: Int

    public init(expenseID: UUID, cents: Int) {
        self.expenseID = expenseID
        self.cents = cents
    }
}

/// Money taken out of the HSA to pay yourself back.
public struct Withdrawal: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var date: DayDate
    public var amountCents: Int
    public var note: String
    public var allocations: [Allocation]
    public var createdAt: Date

    public init(id: UUID = UUID(), date: DayDate, amountCents: Int, note: String = "",
                allocations: [Allocation] = [], createdAt: Date = Date()) {
        self.id = id
        self.date = date
        self.amountCents = amountCents
        self.note = note
        self.allocations = allocations
        self.createdAt = createdAt
    }

    public var allocatedCents: Int { allocations.reduce(0) { $0 + $1.cents } }

    /// Money withdrawn that is not matched to any expense. Unmatched withdrawals are what an audit would question.
    public var unmatchedCents: Int { max(0, amountCents - allocatedCents) }
}

// MARK: - Ledger

public struct LedgerSettings: Hashable, Codable, Sendable {
    /// A label for the account, such as the custodian's name. Never an account number.
    public var accountLabel: String
    /// The day the HSA was established. Expenses before this day can never be reimbursed.
    public var establishedOn: DayDate?
    public var people: [Person]

    public init(accountLabel: String = "", establishedOn: DayDate? = nil, people: [Person] = []) {
        self.accountLabel = accountLabel
        self.establishedOn = establishedOn
        self.people = people
    }
}

public struct Ledger: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var settings: LedgerSettings
    public var expenses: [Expense]
    public var withdrawals: [Withdrawal]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(schemaVersion: Int = Ledger.currentSchemaVersion, settings: LedgerSettings = LedgerSettings(),
                expenses: [Expense] = [], withdrawals: [Withdrawal] = [],
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.expenses = expenses
        self.withdrawals = withdrawals
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        return settings.people.first { $0.id == id }
    }

    public func expense(_ id: UUID) -> Expense? {
        expenses.first { $0.id == id }
    }
}

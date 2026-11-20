import Foundation

/// What the app could work out from the text of a scanned document.
public struct ReceiptGuess: Equatable, Sendable {
    public var provider: String?
    public var date: DayDate?
    public var amountCents: Int?
    /// Other plausible amounts, best first, for one-tap correction. Includes `amountCents`.
    public var amountCandidates: [Int]
    public var looksLikeEOB: Bool

    public static let empty = ReceiptGuess(provider: nil, date: nil, amountCents: nil, amountCandidates: [],
                                           looksLikeEOB: false)

    public var isEmpty: Bool { provider == nil && date == nil && amountCents == nil }
}

/// Pulls a provider, a date of service and an amount paid out of recognised text.
///
/// This is a set of plain heuristics, not a model, so it is fast, private and predictable. It is
/// meant to pre-fill a form that a person then confirms, never to file anything on its own.
public enum ReceiptParser {

    public static func parse(text: String, today: DayDate) -> ReceiptGuess {
        parse(lines: text.components(separatedBy: .newlines), today: today)
    }

    public static func parse(lines rawLines: [String], today: DayDate) -> ReceiptGuess {
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .empty }
        let (best, candidates) = amounts(in: lines)
        let whole = lines.joined(separator: "\n").lowercased()
        let eob = whole.contains("explanation of benefits") || whole.contains("this is not a bill")
            || (whole.contains("claim number") && whole.contains("allowed"))
        return ReceiptGuess(provider: provider(in: lines), date: date(in: lines, today: today),
                            amountCents: best, amountCandidates: candidates, looksLikeEOB: eob)
    }

    // MARK: Amount

    private static let strongAmountWords = [
        "patient responsibility", "your responsibility", "you owe", "you may owe", "what you owe", "you paid",
        "amount paid", "amount due", "balance due", "total due", "total paid", "patient pays", "patient paid",
        "payment received", "your total", "grand total", "amount you owe", "your cost", "you pay"
    ]
    private static let mediumAmountWords = ["total", "copay", "co-pay", "payment", "balance", "amount"]
    private static let negativeAmountWords = [
        "subtotal", "sub total", "sub-total", "tax", "change", "plan paid", "insurance paid", "plan pays",
        "discount", "adjustment", "billed", "charge", "allowed", "savings", "tendered", "cash back",
        "not covered", "you saved", "insurance payment"
    ]

    private static let amountRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.,])\$?\s?((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?![\d])"#)

    static func amountScore(for line: String) -> Double {
        let l = line.lowercased()
        var score = 0.0
        if strongAmountWords.contains(where: l.contains) { score += 100 }
        else if mediumAmountWords.contains(where: l.contains) { score += 60 }
        if negativeAmountWords.contains(where: l.contains) { score -= 80 }
        if l.contains("deductible") { score -= 20 }
        return score
    }

    static func moneyValues(in line: String) -> [Int] {
        let range = NSRange(line.startIndex..., in: line)
        return amountRegex.matches(in: line, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: line) else { return nil }
            return Money.parseCents(String(line[r]))
        }
    }

    static func amounts(in lines: [String]) -> (best: Int?, candidates: [Int]) {
        struct Found { var cents: Int; var score: Double; var order: Int }
        var found: [Found] = []
        var carried = 0.0
        var order = 0
        for line in lines {
            let values = moneyValues(in: line).filter { $0 > 0 }
            let own = amountScore(for: line)
            if values.isEmpty {
                // OCR often splits "Amount due" and "$45.00" onto separate lines.
                carried = own
                continue
            }
            let score = own != 0 ? own : carried
            carried = 0
            // On a line with several amounts the last one is almost always the one that matters.
            for (i, v) in values.enumerated() {
                let position = i == values.count - 1 ? 0.0 : -30.0
                found.append(Found(cents: v, score: score + position, order: order))
                order += 1
            }
        }
        guard !found.isEmpty else { return (nil, []) }
        let anyKeyword = found.contains { $0.score > 0 }
        let ranked: [Found]
        if anyKeyword {
            ranked = found.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.order > $1.order
            }
        } else {
            ranked = found.sorted { $0.cents > $1.cents }
        }
        var candidates: [Int] = []
        for f in ranked where !candidates.contains(f.cents) {
            candidates.append(f.cents)
            if candidates.count == 4 { break }
        }
        return (candidates.first, candidates)
    }

    // MARK: Date

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthPattern = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?"

    private static let isoDateRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#)
    private static let numericDateRegex = try! NSRegularExpression(
        pattern: #"(?<![\d/.-])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?![\d/-])"#)
    private static let monthFirstRegex = try! NSRegularExpression(
        pattern: "\\b\(monthPattern)\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b", options: [.caseInsensitive])
    private static let dayFirstRegex = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+\(monthPattern),?\\s+(\\d{4})\\b", options: [.caseInsensitive])

    private static let strongDateWords = ["date of service", "service date", "dos", "visit date", "date of visit",
                                          "appointment", "date filled", "fill date", "service from", "services on"]
    private static let negativeDateWords = ["birth", "dob", "due", "expire", "exp.", "pay by", "next visit",
                                            "follow up", "follow-up", "refill"]
    private static let weakNegativeDateWords = ["printed", "statement", "processed", "received", "paid on", "issued"]

    static func dateScore(for line: String) -> Double {
        let l = line.lowercased()
        var score = 0.0
        if strongDateWords.contains(where: { containsWord($0, in: l) }) { score += 100 }
        else if l.contains("date") { score += 20 }
        if negativeDateWords.contains(where: l.contains) { score -= 100 }
        if weakNegativeDateWords.contains(where: l.contains) { score -= 30 }
        return score
    }

    /// Whole-word match, so "dos" does not fire on "dose".
    private static func containsWord(_ word: String, in line: String) -> Bool {
        var search = line.startIndex..<line.endIndex
        while let r = line.range(of: word, range: search) {
            let before = r.lowerBound == line.startIndex ? nil : line[line.index(before: r.lowerBound)]
            let after = r.upperBound == line.endIndex ? nil : line[r.upperBound]
            let boundaryBefore = before.map { !$0.isLetter } ?? true
            let boundaryAfter = after.map { !$0.isLetter } ?? true
            if boundaryBefore && boundaryAfter { return true }
            search = r.upperBound..<line.endIndex
        }
        return false
    }

    static func dates(in line: String, today: DayDate) -> [DayDate] {
        var result: [(Int, DayDate)] = []
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        func int(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let r = match.range(at: group)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }
        func monthNumber(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let r = match.range(at: group)
            guard r.location != NSNotFound else { return nil }
            let prefix = String(ns.substring(with: r).lowercased().prefix(3))
            return months.firstIndex(of: prefix).map { $0 + 1 }
        }
        func add(_ match: NSTextCheckingResult, _ y: Int?, _ m: Int?, _ d: Int?) {
            guard var y, let m, let d else { return }
            if y < 100 {
                // Two-digit years: anything up to next year is this century.
                let pivot = (today.year % 100) + 1
                y += y <= pivot ? (today.year / 100) * 100 : (today.year / 100 - 1) * 100
            }
            guard let day = DayDate(year: y, month: m, day: d), day <= today, y >= 1990 else { return }
            result.append((match.range.location, day))
        }
        for match in isoDateRegex.matches(in: line, range: full) {
            add(match, int(match, 1), int(match, 2), int(match, 3))
        }
        for match in numericDateRegex.matches(in: line, range: full) {
            add(match, int(match, 3), int(match, 1), int(match, 2))
        }
        for match in monthFirstRegex.matches(in: line, range: full) {
            add(match, int(match, 3), monthNumber(match, 1), int(match, 2))
        }
        for match in dayFirstRegex.matches(in: line, range: full) {
            add(match, int(match, 3), monthNumber(match, 2), int(match, 1))
        }
        return result.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    static func date(in lines: [String], today: DayDate) -> DayDate? {
        var best: (score: Double, order: Int, day: DayDate)?
        var carried = 0.0
        var order = 0
        for line in lines {
            let found = dates(in: line, today: today)
            let own = dateScore(for: line)
            if found.isEmpty {
                carried = own
                continue
            }
            let score = own != 0 ? own : carried
            carried = 0
            for day in found {
                if best == nil || score > best!.score {
                    best = (score, order, day)
                }
                order += 1
            }
        }
        guard let best, best.score > -100 else { return nil }
        return best.day
    }

    // MARK: Provider

    private static let providerStopWords = [
        "receipt", "invoice", "statement", "explanation of benefits", "thank you", "customer copy",
        "merchant copy", "page ", "date", "total", "patient", "account", "www.", "http", "@", "welcome",
        "member", "claim", "tel", "phone", "fax", "order", "transaction", "visa", "mastercard", "cashier",
        "this is not a bill", "guarantor", "amount"
    ]
    private static let smallWords: Set<String> = ["of", "the", "and", "for", "at", "in", "on", "to", "a"]

    static func provider(in lines: [String]) -> String? {
        for line in lines.prefix(8) {
            let l = line.lowercased()
            let letters = line.filter { $0.isLetter }.count
            let digits = line.filter { $0.isNumber }.count
            guard letters >= 3, line.count <= 48, digits * 2 <= letters else { continue }
            guard !providerStopWords.contains(where: l.contains) else { continue }
            return tidyName(line)
        }
        return nil
    }

    private static let knownAcronyms: Set<String> = ["UCLA", "UCSF", "UCSD", "USC", "CVS", "MD", "DDS", "DO", "PT",
                                                     "ER", "ENT", "MRI", "LLC", "PC", "PA", "NP", "OB", "GYN", "VA"]

    private static func looksLikeAcronym(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        guard !letters.isEmpty, letters.count == word.count, letters.count <= 4 else { return false }
        if knownAcronyms.contains(word) { return true }
        return !letters.lowercased().contains(where: { "aeiouy".contains($0) })
    }

    /// Turns shouting-case OCR output into something that reads like a name, leaving short
    /// all-capital words such as CVS or UCLA alone.
    static func tidyName(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let hasLowercase = raw.contains { $0.isLowercase }
        guard !hasLowercase else { return words.joined(separator: " ") }
        var out: [String] = []
        for (i, word) in words.enumerated() {
            let lower = word.lowercased()
            if i > 0, smallWords.contains(lower) {
                out.append(lower)
            } else if looksLikeAcronym(word) {
                out.append(word)
            } else {
                out.append(lower.prefix(1).uppercased() + lower.dropFirst())
            }
        }
        return out.joined(separator: " ")
    }
}

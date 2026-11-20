import Foundation

/// A piece of recognised text and where it sat on the page. Coordinates are normalised to 0...1
/// with the origin at the top left.
public struct TextFragment: Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var height: Double

    public init(text: String, x: Double, y: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.height = height
    }
}

/// Text recognition returns a label and its value as two separate pieces when they sit in
/// different columns. This puts pieces that share a row back onto one line, in reading order.
public enum LineAssembler {
    public static func lines(from fragments: [TextFragment]) -> [String] {
        let sorted = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.y + $0.height / 2) < ($1.y + $1.height / 2) }
        var rows: [[TextFragment]] = []
        for fragment in sorted {
            let middle = fragment.y + fragment.height / 2
            if let last = rows.last, let anchor = last.first {
                let anchorMiddle = anchor.y + anchor.height / 2
                let tolerance = max(anchor.height, fragment.height) * 0.6
                if abs(middle - anchorMiddle) <= tolerance {
                    rows[rows.count - 1].append(fragment)
                    continue
                }
            }
            rows.append([fragment])
        }
        return rows.map { row in
            row.sorted { $0.x < $1.x }.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
        }
    }
}

import Foundation

/// Money is stored as whole cents so three decades of sums never drift by a rounding error.
public enum Money {
    /// Parses what a person types: `125`, `125.5`, `$1,250.00`. Returns nil for anything else,
    /// including negatives and more than two decimal places.
    public static func parseCents(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        guard s.contains(where: { $0.isNumber }) else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholeText = parts[0].isEmpty ? "0" : String(parts[0])
        guard wholeText.count <= 9, let whole = Int(wholeText) else { return nil }
        var fraction = 0
        if parts.count == 2 {
            let f = String(parts[1])
            guard f.count <= 2 else { return nil }
            if f.isEmpty {
                fraction = 0
            } else if f.count == 1 {
                guard let v = Int(f) else { return nil }
                fraction = v * 10
            } else {
                guard let v = Int(f) else { return nil }
                fraction = v
            }
        }
        return whole * 100 + fraction
    }

    /// `12345` becomes `123.45`. Used for CSV and file names, where no currency symbol is wanted.
    public static func plain(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let magnitude = abs(cents)
        return String(format: "%@%d.%02d", sign, magnitude / 100, magnitude % 100)
    }
}

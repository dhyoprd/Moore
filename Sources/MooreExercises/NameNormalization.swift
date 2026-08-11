// contractId: SC-exercises @1.0.0, BR-001
// Name normalization: lowercase + trim + collapse interior whitespace.

import Foundation

public enum NameNormalization {
    /// BR-001 canonical form.
    /// `lowercase(trim(collapseWhitespace(s)))` — Unicode-aware lowercase.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        // Trim leading/trailing whitespace, then collapse interior runs to one space.
        let parts = lowered
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return parts.joined(separator: " ")
    }

    /// Display form for storage in `name` after user input (keeps casing, trims
    /// leading/trailing and collapses interior whitespace to a single space). BR-005(d)
    /// says "preserving the user's casing" — this function does exactly that.
    public static func displayForm(_ s: String) -> String {
        let parts = s
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return parts.joined(separator: " ")
    }
}

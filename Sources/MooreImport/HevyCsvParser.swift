// contractId: SC-import @1.0.0
// §4 BR-001/BR-002 — the container layer. Pure RFC 4180 reader: UTF-8 text in,
// records-of-fields out. Foundation only (seam-1: no GRDB, no UI); byte-identical
// semantics across platforms per §9.
//
// Grammar (BR-001):
//   - A field beginning with `"` is quoted; `""` inside quotes is a literal quote.
//   - Quoted fields may contain commas and CR/LF newlines.
//   - Records end at CRLF or LF (lone CR tolerated); final record may omit it.
//   - A leading U+FEFF BOM is stripped.
//   - Unterminated quote at EOF is a parse error.

import Foundation

public enum HevyCsvError: Error, Equatable, CustomStringConvertible {
    case unterminatedQuote(record: Int)

    public var description: String {
        switch self {
        case .unterminatedQuote(let record):
            return "unterminatedQuote at record \(record)"
        }
    }
}

public enum HevyCsvParser {

    /// BR-001: split the whole file into records of raw field strings.
    /// No header semantics here — header interpretation is the engine's job
    /// (BR-002). Empty trailing record produced by a final newline is dropped.
    public static func parseRecords(_ text: String) throws -> [[String]] {
        var source = text
        if source.hasPrefix("\u{FEFF}") {           // BOM tolerated, stripped
            source.removeFirst()
        }

        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var recordIndex = 1                          // 1-based, for error reporting
        var sawAnyContentInRecord = false

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")           // escaped quote
                        i += 2
                        continue
                    }
                    inQuotes = false                 // closing quote
                    i += 1
                    continue
                }
                field.append(c)                      // commas/newlines literal inside quotes
                i += 1
                continue
            }
            // Outside quotes. A quote opens a quoted field only at field start
            // (RFC 4180 §2.6); mid-field quotes are literal (lenient).
            if c == "\"" && field.isEmpty {
                inQuotes = true
                sawAnyContentInRecord = true
                i += 1
                continue
            }
            if c == "," {
                record.append(field)
                field = ""
                sawAnyContentInRecord = true
                i += 1
                continue
            }
            if c == "\r" {
                if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                record.append(field)
                records.append(record)
                recordIndex += 1
                record = []
                field = ""
                sawAnyContentInRecord = false
                i += 1
                continue
            }
            if c == "\n" {
                record.append(field)
                records.append(record)
                recordIndex += 1
                record = []
                field = ""
                sawAnyContentInRecord = false
                i += 1
                continue
            }
            field.append(c)
            sawAnyContentInRecord = true
            i += 1
        }
        if inQuotes {
            throw HevyCsvError.unterminatedQuote(record: recordIndex)
        }
        // Final record without trailing newline — keep only if it has content.
        if !field.isEmpty || !record.isEmpty || sawAnyContentInRecord {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// BR-002: header normalization — lowercase, trim, interior whitespace runs
    /// collapse to `_`. `Start Time` and `start_time` denote the same column.
    public static func normalizeHeader(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let parts = lowered.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts.joined(separator: "_")
    }

    /// BR-005: literal two-character `\n` sequences (Hevy's in-field newline
    /// escape) become real newlines. Lone backslashes are preserved.
    public static func unescapeHevyNewlines(_ raw: String) -> String {
        return raw.replacingOccurrences(of: "\\n", with: "\n")
    }
}

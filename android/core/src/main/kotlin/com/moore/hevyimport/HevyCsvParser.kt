// contractId: SC-import @1.0.0
// §4 BR-001/BR-002 — the container layer. Pure RFC 4180 reader: UTF-8 text in,
// records-of-fields out. Pure JVM (seam-1: no persistence, no UI); byte-identical
// semantics across platforms per §9.
// Mechanical Kotlin port of Sources/MooreImport/HevyCsvParser.swift.
package com.moore.hevyimport

sealed class HevyCsvError(message: String) : Exception(message) {
    class UnterminatedQuote(val record: Int) :
        HevyCsvError("unterminatedQuote at record $record")
}

object HevyCsvParser {

    /// BR-001: split the whole file into records of raw field strings.
    /// No header semantics here — header interpretation is the engine's job
    /// (BR-002). Empty trailing record produced by a final newline is dropped.
    /// Grammar: a field beginning with `"` is quoted; `""` inside quotes is a
    /// literal quote; quoted fields may contain commas and CR/LF newlines;
    /// records end at CRLF or LF (lone CR tolerated); final record may omit it;
    /// a leading U+FEFF BOM is stripped; unterminated quote at EOF is an error.
    fun parseRecords(text: String): List<List<String>> {
        var source = text
        if (source.startsWith("\uFEFF")) {           // BOM tolerated, stripped
            source = source.substring(1)
        }

        val records = mutableListOf<List<String>>()
        val record = mutableListOf<String>()
        val field = StringBuilder()
        var inQuotes = false
        var recordIndex = 1                          // 1-based, for error reporting
        var sawAnyContentInRecord = false

        val chars = source.toCharArray()
        var i = 0
        while (i < chars.size) {
            val c = chars[i]
            if (inQuotes) {
                if (c == '"') {
                    if (i + 1 < chars.size && chars[i + 1] == '"') {
                        field.append('"')            // escaped quote
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
            if (c == '"' && field.isEmpty()) {
                inQuotes = true
                sawAnyContentInRecord = true
                i += 1
                continue
            }
            if (c == ',') {
                record.add(field.toString())
                field.setLength(0)
                sawAnyContentInRecord = true
                i += 1
                continue
            }
            if (c == '\r') {
                if (i + 1 < chars.size && chars[i + 1] == '\n') i += 1
                record.add(field.toString())
                records.add(record.toList())
                recordIndex += 1
                record.clear()
                field.setLength(0)
                sawAnyContentInRecord = false
                i += 1
                continue
            }
            if (c == '\n') {
                record.add(field.toString())
                records.add(record.toList())
                recordIndex += 1
                record.clear()
                field.setLength(0)
                sawAnyContentInRecord = false
                i += 1
                continue
            }
            field.append(c)
            sawAnyContentInRecord = true
            i += 1
        }
        if (inQuotes) {
            throw HevyCsvError.UnterminatedQuote(recordIndex)
        }
        // Final record without trailing newline — keep only if it has content.
        if (field.isNotEmpty() || record.isNotEmpty() || sawAnyContentInRecord) {
            record.add(field.toString())
            records.add(record.toList())
        }
        return records
    }

    /// BR-002: header normalization — lowercase, trim, interior whitespace runs
    /// collapse to `_`. `Start Time` and `start_time` denote the same column.
    fun normalizeHeader(raw: String): String {
        val lowered = raw.lowercase()
        val parts = lowered.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        return parts.joinToString("_")
    }

    /// BR-005: literal two-character `\n` sequences (Hevy's in-field newline
    /// escape) become real newlines. Lone backslashes are preserved.
    fun unescapeHevyNewlines(raw: String): String = raw.replace("\\n", "\n")
}

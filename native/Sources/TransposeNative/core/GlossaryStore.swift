import Foundation

/// Pure glossary import/export. AppSettings owns persistence; this type neither
/// writes preferences nor records translation history.
enum GlossaryStore {
    enum Format: String, CaseIterable {
        case json, tsv, csv

        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "json": self = .json
            case "tsv", "txt": self = .tsv
            case "csv": self = .csv
            default: return nil
            }
        }
    }

    static let maximumEntries = 1_000
    static let maximumTotalCharacters = 200_000
    static let maximumImportBytes = 2_097_152

    static func parse(data: Data, format: Format) throws -> [GlossaryEntry] {
        guard data.count <= maximumImportBytes else { throw problem("词库文件不能超过 2 MB。") }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw problem("无法读取文件，请使用 UTF-8 编码。")
        }
        return try parse(text: text, format: format)
    }

    static func parse(text: String, format: Format) throws -> [GlossaryEntry] {
        guard text.utf8.count <= maximumImportBytes else { throw problem("词库文件不能超过 2 MB。") }
        let clean = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        switch format {
        case .json:
            let decoder = JSONDecoder()
            let data = Data(clean.utf8)
            let rows: [ImportEntry]
            if let list = try? decoder.decode([ImportEntry].self, from: data) { rows = list }
            else if let envelope = try? decoder.decode(ImportEnvelope.self, from: data) { rows = envelope.terms }
            else { throw problem("JSON 词库格式有误。请使用包含 source、translation 的数组。") }
            return try normalized(rows.map(\.entry))
        case .tsv, .csv:
            let rows = try delimitedRows(clean, separator: format == .tsv ? "\t" : ",")
            guard let first = rows.first else { return [] }
            let header = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
            let sourceColumn = column(["source", "term", "原文", "源词", "术语"])
            let translationColumn = column(["translation", "target", "译文", "译名", "固定译名"])
            let hasHeader = sourceColumn != nil && translationColumn != nil
            let sourceIndex = hasHeader ? sourceColumn! : 0
            let translationIndex = hasHeader ? translationColumn! : 1
            let noteIndex = hasHeader ? column(["note", "notes", "备注"]) : 2
            let enabledIndex = hasHeader ? column(["enabled", "启用"]) : 3
            let idIndex = hasHeader ? column(["id"]) : 4
            let body = hasHeader ? Array(rows.dropFirst()) : rows
            let entries = try body.enumerated().map { offset, row -> GlossaryEntry in
                let line = offset + (hasHeader ? 2 : 1)
                func cell(_ index: Int?) -> String {
                    guard let index, row.indices.contains(index) else { return "" }
                    return row[index]
                }
                guard row.indices.contains(sourceIndex), row.indices.contains(translationIndex) else {
                    throw problem("第 \(line) 行缺少源词或译名，请用 Tab 分隔两列。")
                }
                let enabledValue = cell(enabledIndex).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let enabled: Bool
                switch enabledValue {
                case "", "true", "1", "yes", "是", "启用": enabled = true
                case "false", "0", "no", "否", "禁用": enabled = false
                default: throw problem("第 \(line) 行的 enabled 应为 true 或 false。")
                }
                let rawID = cell(idIndex).trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawID.isEmpty || UUID(uuidString: rawID) != nil else { throw problem("第 \(line) 行的 id 格式有误。") }
                return GlossaryEntry(id: UUID(uuidString: rawID) ?? UUID(), source: cell(sourceIndex),
                                     translation: cell(translationIndex), note: cell(noteIndex), enabled: enabled)
            }
            return try normalized(entries)
        }
    }

    static func encode(_ entries: [GlossaryEntry], format: Format) throws -> Data {
        let entries = try normalized(entries)
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(entries)
        case .tsv, .csv:
            let separator: Character = format == .tsv ? "\t" : ","
            func escape(_ value: String) -> String {
                guard value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            var rows = ["source\(separator)translation\(separator)note\(separator)enabled\(separator)id"]
            rows += entries.map { entry in
                [entry.source, entry.translation, entry.note, entry.enabled ? "true" : "false", entry.id.uuidString]
                    .map(escape).joined(separator: String(separator))
            }
            return Data((rows.joined(separator: "\n") + "\n").utf8)
        }
    }

    /// Whitespace-only records are ignored. Duplicate source terms use the latest
    /// translation while preserving their original position and identity.
    static func normalized(_ entries: [GlossaryEntry]) throws -> [GlossaryEntry] {
        var result: [GlossaryEntry] = []
        var sourceIndices: [String: Int] = [:]
        var usedIDs = Set<UUID>()
        for (offset, value) in entries.enumerated() {
            let source = value.source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let translation = value.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = value.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty && translation.isEmpty && note.isEmpty { continue }
            guard !source.isEmpty, !translation.isEmpty else { throw problem("第 \(offset + 1) 条需要填写源词和固定译名。") }
            guard source.count <= 160, translation.count <= 360, note.count <= 600 else {
                throw problem("单条源词最多 160 字，译名最多 360 字，备注最多 600 字。")
            }
            guard ![source, translation, note].contains(where: hasDisallowedControls) else {
                throw problem("词条包含无法显示的控制字符。")
            }
            let canonical = canonicalSource(source)
            let existing = sourceIndices[canonical]
            let id = existing.map { result[$0].id } ?? (usedIDs.contains(value.id) ? UUID() : value.id)
            let clean = GlossaryEntry(id: id, source: source, translation: translation, note: note, enabled: value.enabled)
            if let existing { result[existing] = clean }
            else {
                sourceIndices[canonical] = result.count
                result.append(clean)
                usedIDs.insert(id)
            }
            guard result.count <= maximumEntries else { throw problem("词库最多支持 \(maximumEntries) 条。") }
        }
        guard result.reduce(0, { $0 + $1.source.count + $1.translation.count + $1.note.count }) <= maximumTotalCharacters else {
            throw problem("词库内容总计不能超过 \(maximumTotalCharacters) 字。")
        }
        return result
    }

    static func importEntries(existing: [GlossaryEntry], incoming: [GlossaryEntry]) throws -> [GlossaryEntry] {
        try normalized(existing + incoming)
    }

    /// Editing preserves the original position. If a renamed term collides with
    /// another source, the user's just-submitted value wins under the same
    /// canonical-source and earliest-identity rules used by imports.
    static func saving(_ entry: GlossaryEntry, in existing: [GlossaryEntry]) throws -> [GlossaryEntry] {
        guard let index = existing.firstIndex(where: { $0.id == entry.id }) else {
            throw problem("该术语已被删除，请重新添加。")
        }
        var updated = existing
        updated[index] = entry
        return try normalized(updated + [entry])
    }

    private static func canonicalSource(_ source: String) -> String {
        source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func hasDisallowedControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    }

    private static func problem(_ message: String) -> Error { AppError.message(message) }

    private struct ImportEntry: Decodable {
        let id: UUID?
        let source: String
        let translation: String
        let note: String?
        let enabled: Bool?
        var entry: GlossaryEntry {
            GlossaryEntry(id: id ?? UUID(), source: source, translation: translation, note: note ?? "", enabled: enabled ?? true)
        }
    }

    private struct ImportEnvelope: Decodable { let terms: [ImportEntry] }

    private static func delimitedRows(_ text: String, separator: Character) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closedQuote = false
        let characters = Array(text)
        var index = 0
        func finishField() { row.append(field); field = ""; closedQuote = false }
        func finishRow() {
            finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(character) }
            } else if character == separator { finishField() }
            else if character == "\n" || character == "\r" || character == "\r\n" {
                finishRow()
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else if character == "\"", field.isEmpty, !closedQuote { quoted = true }
            else {
                guard !closedQuote else { throw problem("分隔文件的引号后包含多余内容。") }
                guard character != "\"" else { throw problem("分隔文件中的双引号需要成对包围字段。") }
                field.append(character)
            }
            index += 1
        }
        guard !quoted else { throw problem("分隔文件中有未闭合的双引号。") }
        if !field.isEmpty || !row.isEmpty || closedQuote { finishRow() }
        return rows
    }
}

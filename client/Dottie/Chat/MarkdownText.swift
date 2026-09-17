//
//  MarkdownText.swift
//  Dottie
//
//  Lightweight markdown renderer for SwiftUI without external dependencies.
//  Supports: tables, headers, bold, italic, code, lists, blockquotes, task lists, horizontal rules, links.
//

import SwiftUI

/// Renders markdown text with support for tables, headers, bold, italic, code, lists, blockquotes, and more.
/// Streaming-safe: partial/unterminated blocks are stabilized before parsing so tables, code fences,
/// and inline formatting render correctly even while tokens are still arriving.
struct MarkdownText: View {
    let content: String
    let fontSize: CGFloat
    let textColor: Color
    let isErrorLine: ((String) -> Bool)?
    let errorColor: Color
    @Environment(\.colorScheme) private var colorScheme

    init(
        _ content: String,
        fontSize: CGFloat = 14,
        textColor: Color = .primary,
        isErrorLine: ((String) -> Bool)? = nil,
        errorColor: Color = .red
    ) {
        self.content = content
        self.fontSize = fontSize
        self.textColor = textColor
        self.isErrorLine = isErrorLine
        self.errorColor = errorColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Tag Stripping

    /// Strips followup tags and partial tag fragments from text.
    /// Handles complete tags, unclosed tags at end, and partial tag starts/closes.
    private func stripFollowupTags(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<?/?followup>[\\s\\S]*?<?/?followup>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<?/?followup>[\\s\\S]*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<?/?followup>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<?/?follow[a-z]*>?$", with: "", options: .regularExpression)
            // Gemma 4 reasoning/tool blocks (content included) + bare control tokens leaked
            // by a bad GGUF export / tokenizer mismatch (llama.cpp #23252, #21365).
            .replacingOccurrences(of: "<\\|channel>[\\s\\S]*?<channel\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<\\|tool_call>[\\s\\S]*?<tool_call\\|>|<\\|tool_response>[\\s\\S]*?<tool_response\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<\\|turn>(system|user|model)?|<\\|(turn|channel|tool_response|tool_call|tool)>|<(turn|channel|tool_response|tool_call|tool)\\|>|<\\|(think|image|audio|\")\\|>|</?(start_of_turn|end_of_turn|start_of_image|end_of_image|start_of_audio|end_of_audio|bos|eos|pad|unk)>|<unused[0-9]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming Stabilization

    /// Repairs malformed list items that the LLM emits on a single line with
    /// `.**Label:**` or `.***Label:**` as a pseudo-separator instead of real
    /// newlines. Only fires when the content already looks like a list (has
    /// at least one `- ` or `* ` line marker) to avoid touching valid inline
    /// markdown. Inserts a proper `\n* ` between the runs so the block parser
    /// sees multiple list items.
    private func normalizeBrokenListItems(_ text: String) -> String {
        // Guard: only run on content that already looks like a list.
        guard text.contains("\n* ") || text.contains("\n- ") ||
              text.contains("\n*  ") || text.contains("\n-  ") ||
              text.hasPrefix("* ") || text.hasPrefix("- ") ||
              text.hasPrefix("*  ") || text.hasPrefix("-  ") else {
            return text
        }

        // Match: sentence-ending punctuation + 2 or 3 stars + capitalized label
        // ending in `:` + closing `**`. Replace with newline + list marker + proper bold.
        // Examples this fixes:
        //   "weather.***File Management:** Reading"  → "weather.\n* **File Management:** Reading"
        //   "workspace.**Task Management:** Creating" → "workspace.\n* **Task Management:** Creating"
        let pattern = #"([.!?])\*{2,3}([A-Z][^*\n]{1,80}?:)\*\*"#
        return text.replacingOccurrences(
            of: pattern,
            with: "$1\n* **$2**",
            options: .regularExpression
        )
    }

    /// Stabilizes incomplete markdown for streaming by closing unterminated blocks
    /// and stripping dangling fragments. Idempotent on complete content — does nothing
    /// when all blocks are already balanced. Inspired by streamdown's `remend`.
    private func stabilizeForStreaming(_ text: String) -> String {
        var result = text

        // 1. Strip trailing partial HTML-like tag openers ("<", "<fo", "<follow", ...)
        //    Covers any lingering fragments the followup stripper missed.
        result = result.replacingOccurrences(
            of: "<[a-zA-Z][a-zA-Z0-9]*$",
            with: "",
            options: .regularExpression
        )
        if result.hasSuffix("<") {
            result = String(result.dropLast())
        }

        // 2. Close unterminated triple-backtick code fences.
        //    Odd count of ``` → append a closing fence on its own line.
        let fenceCount = result.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1 {
            if !result.hasSuffix("\n") {
                result += "\n"
            }
            result += "```"
        }

        // 3. Strip trailing dangling inline markers that would orphan-format text
        //    mid-stream. Check multi-char markers first so "**" is stripped before
        //    the logic would see two stray "*".
        let dangling: [String] = ["***", "**", "__", "~~", "*", "_", "~", "`"]
        var didStrip = true
        while didStrip {
            didStrip = false
            for marker in dangling where result.hasSuffix(marker) {
                // Don't strip a closing triple fence we just appended
                if marker == "`" && result.hasSuffix("```") { continue }
                let occurrences = result.components(separatedBy: marker).count - 1
                if occurrences % 2 == 1 {
                    result = String(result.dropLast(marker.count))
                    didStrip = true
                    break
                }
            }
        }

        // 4. Strip dangling unmatched `[` (incomplete link text).
        //    Only safe outside code: a `[` inside a code fence (e.g. a Python
        //    slice `arr[i:` or regex `[a-z`) is legitimate code, not partial
        //    link syntax, so truncating from it would silently drop the tail of
        //    a finished message. Skip the strip when the last `[` falls inside a
        //    code fence span (odd number of ``` fences precede it).
        if let lastOpen = result.lastIndex(of: "["),
           !result[lastOpen...].contains("]") {
            let fencesBefore = result[..<lastOpen].components(separatedBy: "```").count - 1
            let insideCodeFence = fencesBefore % 2 == 1
            if !insideCodeFence {
                result = String(result[..<lastOpen])
            }
        }

        return result
    }

    // MARK: - Block Parsing

    private enum Block {
        case paragraph(String)
        case errorLine(String)
        case header(level: Int, text: String)
        case table(headers: [String], rows: [[String]])
        case list(items: [ListItem], ordered: Bool)
        case codeBlock(language: String?, code: String)
        case blockquote(String)
        case horizontalRule
    }

    private struct ListItem {
        let text: String
        let isTask: Bool
        let isChecked: Bool
    }

    /// Parses the raw markdown content into an array of typed blocks (paragraphs, headers, tables, lists, code blocks, blockquotes, and horizontal rules).
    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let stripped = stripFollowupTags(content)
        let normalized = normalizeBrokenListItems(stripped)
        let cleanedContent = stabilizeForStreaming(normalized)
        let lines = cleanedContent.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line - skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Horizontal rule (---, ***, ___). The `charCount >= 3` check below is
            // the real length guard for all three branches; the old outer
            // `trimmed.count >= 3 &&` only bound (via && precedence) to the dash
            // branch and was redundant there (charCount <= count), so it's removed.
            if (trimmed.allSatisfy { $0 == "-" || $0 == " " } && trimmed.contains("-")) ||
               (trimmed.allSatisfy { $0 == "*" || $0 == " " } && trimmed.contains("*")) ||
               (trimmed.allSatisfy { $0 == "_" || $0 == " " } && trimmed.contains("_")) {
                let charCount = trimmed.filter { $0 != " " }.count
                if charCount >= 3 {
                    blocks.append(.horizontalRule)
                    i += 1
                    continue
                }
            }

            // Code block (```)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: codeLines.joined(separator: "\n")))
                i += 1
                continue
            }

            // Blockquote (> text)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix(">") {
                        let content = String(ql.dropFirst()).trimmingCharacters(in: .whitespaces)
                        quoteLines.append(content)
                        i += 1
                    } else if ql.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Header (# ## ### etc)
            if let headerMatch = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let hashes = trimmed[headerMatch].filter { $0 == "#" }.count
                let text = String(trimmed[headerMatch.upperBound...])
                blocks.append(.header(level: hashes, text: text))
                i += 1
                continue
            }

            // Table (starts with |)
            if trimmed.hasPrefix("|") {
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    if tl.hasPrefix("|") {
                        tableLines.append(tl)
                        i += 1
                    } else {
                        break
                    }
                }
                if let table = parseTable(tableLines) {
                    blocks.append(table)
                }
                continue
            }

            // Task list or unordered list (- or *)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [ListItem] = []
                while i < lines.count {
                    let ll = lines[i].trimmingCharacters(in: .whitespaces)
                    if ll.hasPrefix("- ") || ll.hasPrefix("* ") {
                        let content = String(ll.dropFirst(2))
                        let item = parseListItem(content)
                        items.append(item)
                        i += 1
                    } else if ll.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.list(items: items, ordered: false))
                continue
            }

            // Ordered list (1. 2. etc)
            if trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
                var items: [ListItem] = []
                var currentItemLines: [String] = []

                while i < lines.count {
                    let ll = lines[i]
                    let llTrimmed = ll.trimmingCharacters(in: .whitespaces)

                    if let match = llTrimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                        // New numbered item - save previous if exists
                        if !currentItemLines.isEmpty {
                            items.append(ListItem(text: currentItemLines.joined(separator: "\n"), isTask: false, isChecked: false))
                            currentItemLines = []
                        }
                        let content = String(llTrimmed[match.upperBound...])
                        currentItemLines.append(content)
                        i += 1
                    } else if llTrimmed.isEmpty {
                        // Empty line ends the list
                        i += 1
                        break
                    } else if ll.hasPrefix("   ") || ll.hasPrefix("\t") {
                        // Indented continuation line - append to current item
                        currentItemLines.append(llTrimmed)
                        i += 1
                    } else {
                        // Non-indented, non-numbered line ends the list
                        break
                    }
                }
                // Don't forget the last item
                if !currentItemLines.isEmpty {
                    items.append(ListItem(text: currentItemLines.joined(separator: "\n"), isTask: false, isChecked: false))
                }
                blocks.append(.list(items: items, ordered: true))
                continue
            }

            // Regular paragraph - collect consecutive non-special lines.
            // Error lines are emitted as their own blocks so they can be colored red
            // without breaking multi-line markdown constructs above/below.
            var paragraphLines: [String] = []
            while i < lines.count {
                let pl = lines[i].trimmingCharacters(in: .whitespaces)
                if pl.isEmpty || pl.hasPrefix("#") || pl.hasPrefix("|") ||
                   pl.hasPrefix("- ") || pl.hasPrefix("* ") || pl.hasPrefix("```") ||
                   pl.hasPrefix(">") ||
                   pl.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil ||
                   isHorizontalRule(pl) {
                    break
                }
                if let detector = isErrorLine, detector(pl) {
                    if !paragraphLines.isEmpty {
                        blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
                        paragraphLines = []
                    }
                    blocks.append(.errorLine(pl))
                    i += 1
                    continue
                }
                paragraphLines.append(lines[i])
                i += 1
            }
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let chars = trimmed.filter { $0 != " " }
        return chars.count >= 3 && (chars.allSatisfy { $0 == "-" } || chars.allSatisfy { $0 == "*" } || chars.allSatisfy { $0 == "_" })
    }

    private func parseListItem(_ content: String) -> ListItem {
        // Check for task list syntax: [ ] or [x] or [X]
        if content.hasPrefix("[ ] ") {
            return ListItem(text: String(content.dropFirst(4)), isTask: true, isChecked: false)
        } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
            return ListItem(text: String(content.dropFirst(4)), isTask: true, isChecked: true)
        }
        return ListItem(text: content, isTask: false, isChecked: false)
    }

    /// Parses pipe-delimited table lines into a `.table` block with separated headers and data rows.
    /// - Parameter lines: Raw markdown lines starting with `|`.
    /// - Returns: A `.table` block, or `nil` if fewer than 2 lines are provided.
    private func parseTable(_ lines: [String]) -> Block? {
        guard lines.count >= 2 else { return nil }

        func parseCells(_ line: String) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var content = trimmed
            if content.hasPrefix("|") { content = String(content.dropFirst()) }
            if content.hasSuffix("|") { content = String(content.dropLast()) }
            return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let headers = parseCells(lines[0])

        // Determine whether the second line is a markdown separator row (|---|:--:|).
        // It only counts as a separator when EVERY cell matches the separator pattern
        // (optional leading/trailing colon around one-or-more dashes). A line like
        // `| 2026-04-25 | 30 |` contains dashes but is real data — treating it as a
        // separator would silently drop the first data row.
        func isSeparatorRow(_ line: String) -> Bool {
            let cells = parseCells(line)
            guard !cells.isEmpty else { return false }
            return cells.allSatisfy {
                $0.range(of: "^:?-+:?$", options: .regularExpression) != nil
            }
        }

        var dataStartIndex = 1
        if lines.count > 1 && isSeparatorRow(lines[1]) {
            dataStartIndex = 2
        }

        var rows: [[String]] = []
        for i in dataStartIndex..<lines.count {
            let cells = parseCells(lines[i])
            if !cells.isEmpty && !cells.allSatisfy({ $0.isEmpty }) {
                rows.append(cells)
            }
        }

        return .table(headers: headers, rows: rows)
    }

    // MARK: - Block Rendering

    /// Renders a single parsed markdown block as a SwiftUI view.
    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            renderInlineMarkdown(text)

        case .errorLine(let text):
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(errorColor)
                .lineSpacing(4)
                .textSelection(.enabled)

        case .header(let level, let text):
            renderInlineMarkdown(text)
                .font(.system(size: headerSize(level), weight: .semibold))
                .padding(.top, level == 1 ? 8 : 4)

        case .table(let headers, let rows):
            renderTable(headers: headers, rows: rows)

        case .list(let items, let ordered):
            renderList(items: items, ordered: ordered)

        case .codeBlock(let language, let code):
            renderCodeBlock(language: language, code: code)

        case .blockquote(let text):
            renderBlockquote(text)

        case .horizontalRule:
            Rectangle()
                .fill(textColor.opacity(0.2))
                .frame(height: 1)
                .padding(.vertical, 8)
        }
    }

    private func headerSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 10
        case 2: return fontSize + 6
        case 3: return fontSize + 3
        default: return fontSize + 1
        }
    }

    // MARK: - Inline Markdown

    @ViewBuilder
    private func renderInlineMarkdown(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.system(size: fontSize))
                .foregroundColor(textColor)
                .lineSpacing(4)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(textColor)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    // MARK: - Table Rendering

    @ViewBuilder
    private func renderTable(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map { $0.count }.max() ?? 0)

        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { col in
                    Text(col < headers.count ? headers[col] : "")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(textColor)
                        .textSelection(.enabled)
                        .frame(minWidth: 80, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.1))

            // Divider
            Rectangle()
                .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.15))
                .frame(height: 1)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(col < row.count ? row[col] : "")
                            .font(.system(size: fontSize))
                            .foregroundColor(textColor.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(minWidth: 80, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .background(rowIndex % 2 == 0 ? Color.clear : (colorScheme == .dark ? Color.white : Color.black).opacity(0.03))
            }
        }
        .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.05))
        .cornerRadius(8)
        .padding(.vertical, 4)
    }

    // MARK: - List Rendering

    @ViewBuilder
    private func renderList(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    if item.isTask {
                        // Task list checkbox
                        Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                            .font(.system(size: fontSize - 2))
                            .foregroundColor(item.isChecked ? .green : textColor.opacity(0.5))
                            .frame(width: 16, alignment: .center)
                    } else if ordered {
                        Text("\(index + 1).")
                            .font(.system(size: fontSize))
                            .foregroundColor(textColor.opacity(0.7))
                            .frame(width: 20, alignment: .trailing)
                    } else {
                        Text("•")
                            .font(.system(size: fontSize))
                            .foregroundColor(textColor.opacity(0.7))
                            .frame(width: 16, alignment: .center)
                    }
                    renderInlineMarkdown(item.text)
                        .strikethrough(item.isTask && item.isChecked, color: textColor.opacity(0.5))
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Code Block Rendering

    @ViewBuilder
    private func renderCodeBlock(language: String?, code: String) -> some View {
        CodeBlockView(
            language: language,
            code: code,
            highlighted: highlightCode(code, language: language),
            fontSize: fontSize,
            textColor: textColor,
            colorScheme: colorScheme
        )
    }

    /// Basic syntax highlighting for code blocks.
    private func highlightCode(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = textColor.opacity(0.9)

        // Keywords for common languages
        let keywords: Set<String> = [
            // Swift/JS/TS
            "func", "let", "var", "const", "if", "else", "for", "while", "return", "import",
            "class", "struct", "enum", "protocol", "extension", "public", "private", "static",
            "async", "await", "try", "catch", "throw", "new", "this", "self", "true", "false",
            "nil", "null", "undefined", "function", "export", "default", "from", "in", "of",
            // Python
            "def", "class", "import", "from", "as", "if", "elif", "else", "for", "while",
            "return", "try", "except", "finally", "with", "lambda", "yield", "pass", "break",
            "continue", "and", "or", "not", "is", "None", "True", "False", "print"
        ]

        // Apply keyword highlighting
        for keyword in keywords {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result[searchRange].range(of: "\\b\(keyword)\\b", options: .regularExpression) {
                result[range].foregroundColor = Color(red: 0.8, green: 0.5, blue: 0.9) // Purple for keywords
                searchRange = range.upperBound..<result.endIndex
            }
        }

        // Highlight strings (simple approach - "..." or '...')
        highlightStrings(in: &result)

        // Highlight comments (// and #)
        highlightComments(in: &result)

        // Highlight numbers
        highlightNumbers(in: &result)

        return result
    }

    private func highlightStrings(in text: inout AttributedString) {
        let stringColor = Color(red: 0.6, green: 0.8, blue: 0.5) // Green for strings

        // Match double-quoted strings
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: "\"[^\"]*\"", options: .regularExpression) {
            text[range].foregroundColor = stringColor
            searchRange = range.upperBound..<text.endIndex
        }

        // Match single-quoted strings
        searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: "'[^']*'", options: .regularExpression) {
            text[range].foregroundColor = stringColor
            searchRange = range.upperBound..<text.endIndex
        }
    }

    private func highlightComments(in text: inout AttributedString) {
        let commentColor = Color(red: 0.5, green: 0.5, blue: 0.5) // Gray for comments

        // Match // comments
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: "//.*$", options: .regularExpression) {
            text[range].foregroundColor = commentColor
            searchRange = range.upperBound..<text.endIndex
        }

        // Match # comments (Python style)
        searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: "#.*$", options: .regularExpression) {
            text[range].foregroundColor = commentColor
            searchRange = range.upperBound..<text.endIndex
        }
    }

    private func highlightNumbers(in text: inout AttributedString) {
        let numberColor = Color(red: 0.9, green: 0.7, blue: 0.4) // Orange for numbers

        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: "\\b\\d+\\.?\\d*\\b", options: .regularExpression) {
            text[range].foregroundColor = numberColor
            searchRange = range.upperBound..<text.endIndex
        }
    }

    // MARK: - Blockquote Rendering

    @ViewBuilder
    private func renderBlockquote(_ text: String) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.blue.opacity(0.6))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(text.components(separatedBy: "\n"), id: \.self) { line in
                    renderInlineMarkdown(line)
                        .foregroundColor(textColor.opacity(0.8))
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
        }
        .background(Color.blue.opacity(0.05))
        .cornerRadius(4)
        .padding(.vertical, 4)
    }
}

// MARK: - Code Block

/// Fenced code block with hover-revealed copy button. Pressing copy places the
/// raw (un-highlighted) code onto the system pasteboard and transiently flips
/// the button label to "Copied" for 1.5s.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    let highlighted: AttributedString
    let fontSize: CGFloat
    let textColor: Color
    let colorScheme: ColorScheme

    @State private var isHovering = false
    @State private var justCopied = false
    @State private var copyResetTask: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: language label + copy button. Always present so the
            // copy affordance exists even for language-less fences.
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.system(size: fontSize - 3, weight: .medium))
                    .foregroundColor(textColor.opacity(0.5))

                Spacer()

                Button(action: copyToPasteboard) {
                    HStack(spacing: 4) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(justCopied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(textColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .opacity(isHovering || justCopied ? 1 : 0)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.1, green: 0.1, blue: 0.12) : Color(red: 0.94, green: 0.94, blue: 0.96))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.1), lineWidth: 1)
        )
        .padding(.vertical, 4)
        .onHover { isHovering = $0 }
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        justCopied = true
        copyResetTask?.cancel()
        let task = DispatchWorkItem { justCopied = false }
        copyResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }
}

import AppKit
import PyIDECore
import SwiftUI

/// Read-only rendering of a Jupyter notebook: markdown, highlighted code, and outputs.
struct NotebookView: View {
    let documentID: String
    let version: Int
    let text: String
    @State private var parsed: (key: String, notebook: Result<Notebook, Error>)?

    private var key: String { "\(documentID)#\(version)" }

    var body: some View {
        Group {
            switch parsed?.notebook {
            case .success(let notebook):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(notebook.cells) { cell in
                            NotebookCellView(cell: cell, highlight: notebook.language == "python")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failure(let error):
                VStack(spacing: 8) {
                    Text(error.localizedDescription).foregroundStyle(.secondary)
                    Text("Use “Show JSON” to edit the file directly.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: key) {
            let text = text, key = key
            let result = await Task.detached { Result { try Notebook.parse(text) } }.value
            parsed = (key, result)
        }
    }
}

struct NotebookCellView: View {
    let cell: Notebook.Cell
    let highlight: Bool

    var body: some View {
        switch cell.kind {
        case .markdown:
            MarkdownCell(source: cell.source)
                .padding(.horizontal, 4)
        case .raw:
            Text(cell.source)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .code:
            HStack(alignment: .top, spacing: 8) {
                Text(cell.executionCount.map { "[\($0)]" } ?? "[ ]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlight ? Self.highlighted(cell.source) : AttributedString(cell.source))
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in
                        OutputView(output: output)
                    }
                }
            }
        }
    }

    static func highlighted(_ source: String) -> AttributedString {
        let attributed = NSMutableAttributedString(string: source, attributes: [.foregroundColor: NSColor.textColor])
        for token in PythonHighlighter.tokenize(source) {
            attributed.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
        }
        return (try? AttributedString(attributed, including: \.appKit)) ?? AttributedString(source)
    }

    struct OutputView: View {
        let output: Notebook.Output

        var body: some View {
            switch output {
            case .text(let text, let isError):
                Text(text.trimmingCharacters(in: .newlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isError ? .red : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            case .image(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 800), alignment: .leading)
                        .padding(.horizontal, 8)
                }
            case .error(let name, let value, let traceback):
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name): \(value)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if !traceback.isEmpty {
                        Text(traceback).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Block-level markdown good enough for notebooks: headings, bullets, fenced code, paragraphs.
struct MarkdownCell: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .title3.bold())
                        .padding(.top, level == 1 ? 4 : 2)
                case .code(let text):
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.inline(text))
                    }
                case .paragraph(let text):
                    Text(Self.inline(text))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(Int, String), code(String), bullet(String), paragraph(String)
    }

    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
                      trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

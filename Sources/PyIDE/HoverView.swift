import PyIDECore
import SwiftUI

/// Renders language-server hover markdown: Python signatures in monospace, docs as inline markdown.
struct HoverView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .code:
                    Text(block.text)
                        .font(.system(size: 12, design: .monospaced))
                case .text:
                    Text(Self.inlineMarkdown(block.text))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

import AppKit
import PyIDECore

@MainActor
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * 4  // PEP 8: 4-column indents
        return style
    }()

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    // System colors adapt to light and dark mode automatically.
    static func color(for kind: PyTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .builtin: .systemPurple
        case .function: .systemBlue
        case .string: .systemOrange
        case .number: .systemIndigo
        case .comment: .systemGreen
        case .decorator: .systemBrown
        }
    }
}

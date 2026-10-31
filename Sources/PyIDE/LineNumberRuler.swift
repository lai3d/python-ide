import AppKit
import PyIDECore

/// Line-number gutter for the code editor (TextKit 1). Marks lines that have diagnostics
/// and highlights the caret line; clicking a number selects that line.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    /// Worst severity per zero-based line.
    private var lineMarkers: [Int: Diagnostic.Severity] = [:]
    private var breakpointLines: Set<Int> = []
    private var executionLine: Int?
    /// Called with a zero-based line when its number is clicked.
    var onToggleBreakpoint: ((Int) -> Void)?

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        ruleThickness = Self.thickness(forLineCount: 1)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Call after every text change.
    func textDidChange() {
        guard let textView else { return }
        lineStarts = LineIndex(textView.string).lineStarts
        let thickness = Self.thickness(forLineCount: lineStarts.count)
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        var markers: [Int: Diagnostic.Severity] = [:]
        for d in diagnostics {
            if let existing = markers[d.start.line], existing.rawValue <= d.severity.rawValue { continue }
            markers[d.start.line] = d.severity
        }
        if markers != self.lineMarkers {
            self.lineMarkers = markers
            needsDisplay = true
        }
    }

    func setDebugState(breakpoints: Set<Int>, executionLine: Int?) {
        guard breakpoints != breakpointLines || executionLine != self.executionLine else { return }
        breakpointLines = breakpoints
        self.executionLine = executionLine
        needsDisplay = true
    }

    private static func thickness(forLineCount count: Int) -> CGFloat {
        let digits = max(String(count).count, 3)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * digitWidth + 22)
    }

    private func line(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let ns = textView.string as NSString
        let caretLine = line(containing: textView.selectedRange().location)
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin

        func draw(line: Int, fragment: NSRect) {
            let yInText = fragment.minY + origin.y
            let y = convert(NSPoint(x: 0, y: yInText), from: textView).y
            let isCaret = line == caretLine
            let hasBreakpoint = breakpointLines.contains(line)
            if hasBreakpoint {
                // Xcode-style tag: rounded body with a pointed right end.
                let rect = NSRect(x: 2, y: y + 1, width: ruleThickness - 5, height: fragment.height - 2)
                let tip: CGFloat = 5
                let path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX + 3, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX - tip, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                path.line(to: NSPoint(x: rect.maxX - tip, y: rect.maxY))
                path.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY))
                path.appendArc(withCenter: NSPoint(x: rect.minX + 3, y: rect.maxY - 3), radius: 3, startAngle: 90, endAngle: 180)
                path.line(to: NSPoint(x: rect.minX, y: rect.minY + 3))
                path.appendArc(withCenter: NSPoint(x: rect.minX + 3, y: rect.minY + 3), radius: 3, startAngle: 180, endAngle: 270)
                path.close()
                NSColor.systemBlue.setFill()
                path.fill()
            }
            if line == executionLine {
                let size: CGFloat = 8
                let midY = y + fragment.height / 2
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: ruleThickness - 3 - size, y: midY - size / 2 - 1))
                arrow.line(to: NSPoint(x: ruleThickness - 3, y: midY))
                arrow.line(to: NSPoint(x: ruleThickness - 3 - size, y: midY + size / 2 + 1))
                arrow.close()
                NSColor.systemGreen.setFill()
                arrow.fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isCaret || hasBreakpoint ? Self.boldFont : Self.font,
                .foregroundColor: hasBreakpoint ? NSColor.white : isCaret ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            let baselineOffset = (fragment.height - size.height) / 2
            let rightInset: CGFloat = hasBreakpoint || line == executionLine ? 12 : 8
            label.draw(at: NSPoint(x: ruleThickness - size.width - rightInset, y: y + baselineOffset), withAttributes: attributes)

            if !hasBreakpoint, let severity = lineMarkers[line] {
                let color: NSColor = switch severity {
                case .error: .systemRed
                case .warning: .systemYellow
                default: .systemBlue
                }
                color.setFill()
                let d: CGFloat = 6
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (fragment.height - d) / 2, width: d, height: d)).fill()
            }
        }

        guard ns.length > 0 else {
            draw(line: 0, fragment: layoutManager.extraLineFragmentRect.isEmpty
                 ? NSRect(x: 0, y: 0, width: 0, height: Self.font.boundingRectForFont.height + 4)
                 : layoutManager.extraLineFragmentRect)
            return
        }

        let visibleInContainer = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visibleInContainer, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lineNumber = line(containing: chars.location)
        var index = lineStarts[lineNumber]
        while index < ns.length, index <= NSMaxRange(chars) {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(line: lineNumber, fragment: fragment)
            lineNumber += 1
            guard lineNumber < lineStarts.count else { break }
            index = lineStarts[lineNumber]
        }
        // The empty last line after a trailing newline.
        if ns.length > 0, ns.character(at: ns.length - 1) == 0x0A, !layoutManager.extraLineFragmentRect.isEmpty {
            draw(line: lineStarts.count - 1, fragment: layoutManager.extraLineFragmentRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textView.textContainer!)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        let ns = textView.string as NSString
        var lineNumber = line(containing: charIndex)
        // Below the last line of text (after a trailing newline) is the empty last line.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, containerPoint.y >= extra.minY, ns.length > 0 { lineNumber = lineStarts.count - 1 }
        if let onToggleBreakpoint {
            onToggleBreakpoint(lineNumber)
        } else {
            let lineRange = ns.length == 0 ? NSRange(location: 0, length: 0)
                : ns.lineRange(for: NSRange(location: min(charIndex, ns.length), length: 0))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(lineRange)
        }
    }
}

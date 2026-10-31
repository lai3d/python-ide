import AppKit
import PyIDECore
import SwiftUI

/// A small non-activating panel above the caret showing the call's signature,
/// with the parameter being typed highlighted.
@MainActor
final class SignaturePopup {
    private let panel: NSPanel
    private let host = NSHostingView(rootView: SignatureView(info: nil))

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows `info` just above `anchor` (screen rect of the caret line).
    func show(_ info: SignatureInfo, above anchor: NSRect, in window: NSWindow) {
        host.rootView = SignatureView(info: info)
        let size = host.fittingSize
        var origin = NSPoint(x: anchor.minX - 8, y: anchor.maxY + 4)
        if let screen = window.screen?.visibleFrame {
            if origin.y + size.height > screen.maxY { origin.y = anchor.minY - size.height - 4 }  // flip below
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

struct SignatureView: View {
    let info: SignatureInfo?

    var body: some View {
        if let info {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.label(info))
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    if let overload = info.overloadPosition {
                        Text(overload).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let documentation = info.documentation {
                    Text(documentation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 560, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func label(_ info: SignatureInfo) -> AttributedString {
        var text = AttributedString(info.label)
        text.foregroundColor = .secondary
        if let range = info.activeParameterRange, let r = Range(range, in: info.label),
           let lower = AttributedString.Index(r.lowerBound, within: text),
           let upper = AttributedString.Index(r.upperBound, within: text) {
            text[lower..<upper].foregroundColor = .primary
            text[lower..<upper].font = .system(size: 12, weight: .bold, design: .monospaced)
            text[lower..<upper].underlineStyle = .single
        }
        return text
    }
}

import AppKit
import PyIDECore

/// A borderless child window listing completion items under the caret.
/// The editor keeps keyboard focus; it forwards ↑/↓/↩/⇥/Esc here.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let visibleRows = 10
    private static let rowHeight: CGFloat = 22
    private static let width: CGFloat = 480

    var onAccept: ((CompletionItem) -> Void)?
    private(set) var items: [CompletionItem] = []
    private let panel: NSPanel
    private let tableView = NSTableView()

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        panel.contentView = background

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = Self.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView(frame: background.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false
        background.addSubview(scrollView)
    }

    var isVisible: Bool { panel.isVisible }

    var selectedItem: CompletionItem? {
        let row = tableView.selectedRow
        return items.indices.contains(row) ? items[row] : nil
    }

    /// Shows `items` just below `anchor` (screen coordinates of the word start).
    func show(_ items: [CompletionItem], below anchor: NSRect, in window: NSWindow) {
        let previous = selectedItem?.label
        self.items = items
        tableView.reloadData()
        let row = previous.flatMap { label in items.firstIndex { $0.label == label } } ?? 0
        select(row)

        let height = CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight + 8
        var origin = NSPoint(x: anchor.minX - 28, y: anchor.minY - height - 2)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = anchor.maxY + 2 }  // flip above the line
            origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.width)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
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

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        select(min(max(tableView.selectedRow + delta, 0), items.count - 1))
    }

    private func select(_ row: Int) {
        guard items.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowDoubleClicked() {
        if let item = selectedItem { onAccept?(item) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell ?? CompletionCell(identifier: id)
        cell.configure(items[row])
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, label, detail])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: CompletionItem) {
        label.stringValue = item.label
        detail.stringValue = item.detail ?? ""
        let style = Self.style(for: item.kind)
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: "\(item.kind)")
        icon.contentTintColor = style.color
        toolTip = item.documentation
    }

    private static func style(for kind: CompletionItem.Kind) -> (symbol: String, color: NSColor) {
        switch kind {
        case .method: ("m.square.fill", .systemPurple)
        case .function, .constructor: ("f.square.fill", .systemPurple)
        case .field, .property: ("p.square.fill", .systemBlue)
        case .variable: ("v.square.fill", .systemBlue)
        case .structType, .classType: ("s.square.fill", .systemGreen)
        case .interface: ("i.square.fill", .systemGreen)
        case .typeParameter, .enumType: ("t.square.fill", .systemGreen)
        case .module: ("shippingbox.fill", .systemBrown)
        case .constant, .enumMember, .value: ("c.square.fill", .systemOrange)
        case .keyword: ("k.square.fill", .systemPink)
        case .snippet: ("curlybraces.square.fill", .systemGray)
        default: ("circle.fill", .systemGray)
        }
    }
}

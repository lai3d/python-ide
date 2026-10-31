import Foundation
import Observation

/// An open notebook being edited and run. It owns the cells while the notebook is shown, and
/// writes nbformat JSON back to the document (debounced) whenever something changes.
@MainActor
@Observable
public final class NotebookModel {
    public enum CellState: Equatable, Sendable { case idle, queued, running }

    public struct Cell: Identifiable {
        public let id = UUID()
        public var kind: Notebook.Cell.Kind
        public var source: String
        /// nbformat output objects, stored as-is so they round-trip.
        public var outputs: [JSONValue]
        public var executionCount: Int?
        public var state: CellState = .idle
        /// The original cell object (keeps metadata, attachments and the cell id).
        public var raw: [String: JSONValue]
    }

    public enum KernelStatus: Equatable, Sendable { case none, starting, idle, busy, dead(String) }

    public let documentID: String
    public var cells: [Cell]
    public var kernelStatus: KernelStatus = .none
    /// The cell with keyboard focus / selection.
    public var selectedCellID: UUID?
    /// The JSON this model last produced (or was loaded from), to detect outside edits.
    @ObservationIgnored public private(set) var lastSerialized: String
    @ObservationIgnored private var root: [String: JSONValue]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Receives the new JSON text after changes.
    @ObservationIgnored public var onSerialize: (String) -> Void = { _ in }

    public init(documentID: String, text: String) throws {
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .object(let root) = parsed, let rawCells = root["cells"]?.arrayValue else {
            throw Notebook.ParseError.invalid("no cells")
        }
        self.documentID = documentID
        self.root = root
        self.lastSerialized = text
        self.cells = rawCells.map { value in
            let object = value.objectValue ?? [:]
            let kind: Notebook.Cell.Kind = switch object["cell_type"]?.stringValue {
            case "markdown": .markdown
            case "raw": .raw
            default: .code
            }
            return Cell(kind: kind, source: Notebook.joined(value["source"]),
                        outputs: value["outputs"]?.arrayValue ?? [],
                        executionCount: value["execution_count"]?.intValue, raw: object)
        }
        if cells.isEmpty { cells = [Self.newCell(.code, minor: root["nbformat_minor"]?.intValue ?? 5)] }
        selectedCellID = cells.first?.id
    }

    public var language: String {
        root["metadata"]?["kernelspec"]?["language"]?.stringValue
            ?? root["metadata"]?["language_info"]?["name"]?.stringValue ?? "python"
    }

    public func index(of id: UUID) -> Int? { cells.firstIndex { $0.id == id } }

    // MARK: Editing

    public func setSource(_ source: String, of id: UUID) {
        guard let i = index(of: id), cells[i].source != source else { return }
        cells[i].source = source
        changed()
    }

    @discardableResult
    public func insertCell(_ kind: Notebook.Cell.Kind, after id: UUID?) -> UUID {
        let cell = Self.newCell(kind, minor: root["nbformat_minor"]?.intValue ?? 5)
        let position = id.flatMap(index(of:)).map { $0 + 1 } ?? cells.count
        cells.insert(cell, at: position)
        selectedCellID = cell.id
        changed()
        return cell.id
    }

    public func deleteCell(_ id: UUID) {
        guard let i = index(of: id) else { return }
        cells.remove(at: i)
        if cells.isEmpty { cells = [Self.newCell(.code, minor: root["nbformat_minor"]?.intValue ?? 5)] }
        selectedCellID = cells[min(i, cells.count - 1)].id
        changed()
    }

    public func moveCell(_ id: UUID, by delta: Int) {
        guard let i = index(of: id) else { return }
        let j = i + delta
        guard cells.indices.contains(j) else { return }
        cells.swapAt(i, j)
        changed()
    }

    public func setKind(_ kind: Notebook.Cell.Kind, of id: UUID) {
        guard let i = index(of: id), cells[i].kind != kind else { return }
        cells[i].kind = kind
        if kind != .code {
            cells[i].outputs = []
            cells[i].executionCount = nil
        }
        changed()
    }

    public func clearOutputs() {
        for i in cells.indices where cells[i].kind == .code {
            cells[i].outputs = []
            cells[i].executionCount = nil
        }
        changed()
    }

    // MARK: Execution results

    public func markQueued(_ id: UUID) {
        guard let i = index(of: id) else { return }
        cells[i].outputs = []
        cells[i].executionCount = nil
        cells[i].state = .queued
        changed()
    }

    /// Appends an output, merging consecutive stream chunks like Jupyter does.
    public func append(_ output: JSONValue, to id: UUID) {
        guard let i = index(of: id) else { return }
        cells[i].state = .running
        if output["output_type"] == "stream", let name = output["name"], let text = output["text"]?.stringValue,
           let last = cells[i].outputs.last, last["output_type"] == "stream", last["name"] == name,
           case .object(var merged) = last {
            merged["text"] = .string(Notebook.joined(last["text"]) + text)
            cells[i].outputs[cells[i].outputs.count - 1] = .object(merged)
        } else {
            cells[i].outputs.append(output)
        }
        changed()
    }

    public func finish(_ id: UUID, executionCount: Int?) {
        guard let i = index(of: id) else { return }
        cells[i].executionCount = executionCount
        cells[i].state = .idle
        changed()
    }

    public func resetStates() {
        for i in cells.indices { cells[i].state = .idle }
    }

    // MARK: Serialization

    /// Schedules writing JSON back to the document.
    public func changed() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.flush()
        }
    }

    /// Writes JSON back immediately (before saving).
    public func flush() {
        saveTask?.cancel()
        let text = serialized()
        guard text != lastSerialized else { return }
        lastSerialized = text
        onSerialize(text)
    }

    public func serialized() -> String {
        var root = self.root
        root["cells"] = .array(cells.map(Self.serialize))
        return JSONValue.object(root).notebookJSON()
    }

    private static func serialize(_ cell: Cell) -> JSONValue {
        var object = cell.raw
        object["source"] = Notebook.sourceLines(cell.source)
        if object["metadata"] == nil { object["metadata"] = [:] }
        switch cell.kind {
        case .code:
            object["cell_type"] = "code"
            object["outputs"] = .array(cell.outputs.map(Self.normalizedOutput))
            object["execution_count"] = cell.executionCount.map(JSONValue.int) ?? .null
        case .markdown, .raw:
            object["cell_type"] = cell.kind == .markdown ? "markdown" : "raw"
            object.removeValue(forKey: "outputs")
            object.removeValue(forKey: "execution_count")
        }
        return .object(object)
    }

    /// Kernel outputs carry text as one string; nbformat convention is a list of lines.
    private static func normalizedOutput(_ output: JSONValue) -> JSONValue {
        guard case .object(var object) = output else { return output }
        if let text = object["text"]?.stringValue { object["text"] = Notebook.sourceLines(text) }
        if case .object(var data) = object["data"] ?? .null {
            for (mime, value) in data where mime.hasPrefix("text/") {
                if let text = value.stringValue { data[mime] = Notebook.sourceLines(text) }
            }
            object["data"] = .object(data)
        }
        return .object(object)
    }

    private static func newCell(_ kind: Notebook.Cell.Kind, minor: Int) -> Cell {
        var raw: [String: JSONValue] = ["metadata": [:]]
        if minor >= 5 {  // nbformat 4.5 requires cell ids
            raw["id"] = .string(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased())
        }
        return Cell(kind: kind, source: "", outputs: [], executionCount: nil, raw: raw)
    }
}

import Foundation

/// What a breakpoint does: pause (optionally only when `condition` is true), or — with a
/// `logMessage` — print the message (with `{expression}` interpolation) and keep running.
public struct BreakpointSpec: Sendable, Hashable {
    public var condition: String
    public var logMessage: String
    /// Pause only on matching hits: "3" (the 3rd), ">= 3", "% 2" (every 2nd).
    public var hitCondition: String

    public init(condition: String = "", logMessage: String = "", hitCondition: String = "") {
        self.condition = condition
        self.logMessage = logMessage
        self.hitCondition = hitCondition
    }

    public var isLogpoint: Bool { !logMessage.isEmpty }
    public var isConditional: Bool { !condition.isEmpty || !hitCondition.isEmpty }
}

/// A breakpoint as sent to the debug adapter (1-based line).
public struct SourceBreakpoint: Sendable, Hashable {
    public let line: Int
    public let condition: String?
    public let logMessage: String?
    public let hitCondition: String?

    public init(line: Int, condition: String? = nil, logMessage: String? = nil, hitCondition: String? = nil) {
        self.line = line
        self.condition = condition
        self.logMessage = logMessage
        self.hitCondition = hitCondition
    }

    public init(line: Int, spec: BreakpointSpec) {
        self.init(line: line, condition: spec.condition.isEmpty ? nil : spec.condition,
                  logMessage: spec.isLogpoint ? spec.logMessage : nil,
                  hitCondition: spec.hitCondition.isEmpty ? nil : spec.hitCondition)
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["line": .int(line)]
        if let condition, !condition.isEmpty { object["condition"] = .string(condition) }
        if let logMessage, !logMessage.isEmpty { object["logMessage"] = .string(logMessage) }
        if let hitCondition, !hitCondition.isEmpty { object["hitCondition"] = .string(hitCondition) }
        return .object(object)
    }
}

/// Keeps line-anchored things (breakpoints) attached to their code when the text changes.
public enum LineShift {
    /// Returns a function mapping zero-based lines of `old` to lines of `new`, assuming the change
    /// is one contiguous edit (true for typing, paste, delete, and the editor's whole-text replace
    /// when only one region differs). Lines whose text was deleted map to nil.
    public static func mapper(old: String, new: String) -> (Int) -> Int? {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        let maxPrefix = min(a.count, b.count)
        while prefix < maxPrefix, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let newline: UInt16 = 0x0A
        let editLine = a[..<prefix].reduce(0) { $1 == newline ? $0 + 1 : $0 }
        let oldMiddle = a[prefix..<(a.count - suffix)]
        let newMiddle = b[prefix..<(b.count - suffix)]
        let removed = oldMiddle.reduce(0) { $1 == newline ? $0 + 1 : $0 }
        let added = newMiddle.reduce(0) { $1 == newline ? $0 + 1 : $0 }
        let delta = added - removed
        if delta == 0 && removed == 0 { return { $0 } }

        // Whole lines inserted/removed at a line start (e.g. Enter at column 0, or deleting full lines):
        // the line at the edit point moves with its text instead of staying put.
        let atLineStart = prefix == 0 || a[prefix - 1] == newline
        let wholeLines = atLineStart
            && (oldMiddle.isEmpty || oldMiddle.last == newline)
            && (newMiddle.isEmpty || newMiddle.last == newline)

        return { line in
            if wholeLines {
                if line < editLine { return line }
                if line < editLine + removed { return nil }  // a deleted line
                return line + delta
            }
            if line <= editLine { return line }
            if line <= editLine + removed { return nil }  // joined into the edit line
            return line + delta
        }
    }

    /// Re-keys a line-indexed dictionary through `mapper`, dropping entries whose line was deleted.
    public static func remap<V>(_ items: [Int: V], old: String, new: String) -> [Int: V] {
        let map = mapper(old: old, new: new)
        var result: [Int: V] = [:]
        for (line, value) in items.sorted(by: { $0.key < $1.key }) {
            if let target = map(line) { result[target] = value }
        }
        return result
    }
}

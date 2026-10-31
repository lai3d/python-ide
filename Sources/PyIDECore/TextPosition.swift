import Foundation

/// A zero-based line / UTF-16 character position, as used by LSP.
public struct TextPosition: Sendable, Hashable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// Maps LSP positions to UTF-16 offsets (NSRange) and back.
public struct LineIndex: Sendable {
    public let lineStarts: [Int]
    public let utf16Count: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        utf16Count = offset
    }

    public var lineCount: Int { lineStarts.count }

    /// UTF-16 offset of a position, clamped to the line's contents.
    public func offset(of position: TextPosition) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < lineStarts.count else { return utf16Count }
        let start = lineStarts[position.line]
        let end = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] - 1 : utf16Count
        return min(start + max(position.character, 0), end)
    }

    public func position(of offset: Int) -> TextPosition {
        let offset = min(max(offset, 0), utf16Count)
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return TextPosition(line: low, character: offset - lineStarts[low])
    }

    public func range(from start: TextPosition, to end: TextPosition) -> NSRange {
        let a = offset(of: start), b = offset(of: end)
        return NSRange(location: min(a, b), length: abs(b - a))
    }
}

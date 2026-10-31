import Foundation

/// Splits a byte stream into LSP messages framed with `Content-Length` headers.
public struct LSPFramer: Sendable {
    private var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)

    public init() {}

    /// Wraps a JSON body in an LSP header.
    public static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    /// Appends raw bytes and returns every complete message body now available.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let sep = buffer.range(of: Self.separator) {
            let header = String(decoding: buffer[buffer.startIndex..<sep.lowerBound], as: UTF8.self)
            var length: Int?
            for line in header.components(separatedBy: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let length, length >= 0 else {
                // Malformed header: drop it and try to resync.
                buffer = Data(buffer[sep.upperBound...])
                continue
            }
            let bodyStart = sep.upperBound
            guard buffer.endIndex - bodyStart >= length else { break }
            let bodyEnd = bodyStart + length
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer = Data(buffer[bodyEnd...])
        }
        return messages
    }
}

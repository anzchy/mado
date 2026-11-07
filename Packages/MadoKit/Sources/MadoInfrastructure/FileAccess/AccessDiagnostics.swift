import Foundation
import os

/// Public decision fields and private locations travel separately to the log sink.
public struct AccessDiagnostics: Sendable {
    private let sink: @Sendable (String, URL?) -> Void
    public init(sink: @escaping @Sendable (String, URL?) -> Void = { message, url in
        Logger(subsystem: "io.github.anzchy.mado", category: "access").notice("\(message, privacy: .public) path=\(url?.path ?? "none", privacy: .private)")
    }) { self.sink = sink }
    public func emit(_ message: String, path: URL? = nil) { sink(message, path) }
    public static func errorKind(_ error: any Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        // Only stable numeric error evidence is public; localized descriptions and
        // arbitrary domains can contain user locations. Bound malformed chains.
        for _ in 0..<4 {
            guard let value = current else { break }
            let domain = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(value.domain)
                ? value.domain : "other"
            parts.append("\(domain):\(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: ",")
    }
}

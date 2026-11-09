import AppKit

struct ConditionWaitWindowState: Sendable {
    let className: String
    let title: String
    let isVisible: Bool
    let level: Int
    var attachedSheet: String = "nil"
    var alertText: [String] = []
}

/// Quotes bound paths containing spaces. Unquoted paths conservatively consume to a punctuation boundary.
/// Only the last component survives; a home directory by itself becomes [home].
func conditionWaitRedact(_ text: String) -> String {
    let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:file://|~)?/[^\n\r\t\"'“”‘’<>;,|]*"#)
    var result = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let raw = String(result[range]).trimmingCharacters(in: .whitespaces)
        let decoded = (raw.removingPercentEncoding ?? raw).replacingOccurrences(of: "file://", with: "")
        let parts = decoded.split(separator: "/")
        let isHome = parts.count == 2 && ["Users", "home"].contains(String(parts[0]))
        let name = isHome ? "[home]" : (parts.last.map(String.init) ?? "[root]")
        result.replaceSubrange(range, with: name)
    }
    return result.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
}

func conditionWaitFormatState(active: Bool, key: String?, main: String?, windows: [ConditionWaitWindowState]) -> String {
    func quoted(_ value: String) -> String { conditionWaitRedact(value).debugDescription }
    let header = "NSApp.isActive=\(active) keyWindow=\(key.map(quoted) ?? "nil") mainWindow=\(main.map(quoted) ?? "nil")"
    return ([header] + windows.map { w in
        "class=\(w.className) title=\(quoted(w.title)) isVisible=\(w.isVisible) level=\(w.level) attachedSheet=\(quoted(w.attachedSheet))"
            + (w.alertText.isEmpty ? "" : " alertText=\(w.alertText.map(quoted).joined(separator: " | "))")
    }).joined(separator: "\n")
}

@MainActor func conditionWaitAppKitState() -> String {
    guard let app = NSApp else { return "NSApp unavailable keyWindow=nil mainWindow=nil" }
    func identify(_ window: NSWindow) -> String { "\(type(of: window)) \(window.title)" }
    // AppKit exposes no public NSWindow -> NSAlert association. Read the alert panel's visible text fields,
    // which include messageText and informativeText, without KVC, private selectors or runtime mutation.
    func alertText(_ window: NSWindow) -> [String] {
        guard NSStringFromClass(type(of: window)).contains("Alert"), let content = window.contentView else { return [] }
        func fields(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { $0.stringValue.isEmpty ? [] : [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(fields)
        }
        return fields(content)
    }
    let windows = app.windows.map { window in
        ConditionWaitWindowState(className: String(describing: type(of: window)), title: window.title,
            isVisible: window.isVisible, level: window.level.rawValue,
            attachedSheet: window.attachedSheet.map(identify) ?? "nil",
            alertText: alertText(window) + (window.attachedSheet.map(alertText) ?? []))
    }
    return conditionWaitFormatState(active: app.isActive, key: app.keyWindow.map(identify),
        main: app.mainWindow.map(identify), windows: windows)
}

/// Print separately so wrappers that append context retain their exact known-flaky failure signature (#425).
@MainActor func conditionWaitFailure(_ description: String) -> ConditionWaitError {
    print(conditionWaitAppKitState().split(separator: "\n").map { "  appkit: " + $0 }.joined(separator: "\n"))
    return ConditionWaitError(description: description)
}

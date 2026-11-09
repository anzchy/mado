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

/// Bound input before formatting as well as the final line. Prefixes leave the printed line below 1024 characters.
func conditionWaitFormatState(active: Bool, key: String?, main: String?, windows: [ConditionWaitWindowState],
                              totalWindowCount: Int? = nil) -> String {
    func bounded(_ text: String, limit: Int) -> String {
        let prefix = String(text.prefix(limit + 1))
        return prefix.count > limit ? String(prefix.prefix(limit - 1)) + "…" : prefix
    }
    func quoted(_ value: String) -> String {
        bounded(conditionWaitRedact(bounded(value, limit: 4096)), limit: 180).debugDescription
    }
    let header = "NSApp.isActive=\(active) keyWindow=\(key.map(quoted) ?? "nil") mainWindow=\(main.map(quoted) ?? "nil")"
    var lines = [header] + windows.prefix(20).map { w in
        "class=\(w.className) title=\(quoted(w.title)) isVisible=\(w.isVisible) level=\(w.level) attachedSheet=\(quoted(w.attachedSheet))"
            + (w.alertText.isEmpty ? "" : " alertText=\(w.alertText.prefix(2).map(quoted).joined(separator: " | "))")
    }
    let omitted = max(0, (totalWindowCount ?? windows.count) - min(windows.count, 20))
    if omitted > 0 { lines.append("+\(omitted) more windows") }
    return lines.map { bounded($0, limit: 1000) }.joined(separator: "\n")
}

@MainActor func conditionWaitAppKitState() -> String {
    guard let app = NSApp else { return "NSApp unavailable keyWindow=nil mainWindow=nil" }
    func text(_ value: String) -> String { String(value.prefix(4096)) }
    func identify(_ window: NSWindow) -> String { "\(type(of: window)) \(text(window.title))" }
    // There is no public window -> NSAlert association. Read only the first two noneditable labels,
    // never arbitrary editable accessory fields. Stop traversal after a bounded number of views.
    func alertText(_ window: NSWindow) -> [String] {
        guard NSStringFromClass(type(of: window)).contains("Alert"), let content = window.contentView else { return [] }
        var values: [String] = [], visited = 0
        func fields(_ view: NSView) {
            guard values.count < 2, visited < 256 else { return }
            visited += 1
            if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty {
                values.append(text(field.stringValue))
            }
            for child in view.subviews {
                guard values.count < 2, visited < 256 else { break }
                fields(child)
            }
        }
        fields(content)
        return values
    }
    let allWindows = app.windows
    let windows = allWindows.prefix(20).map { window in
        ConditionWaitWindowState(className: String(describing: type(of: window)), title: text(window.title),
            isVisible: window.isVisible, level: window.level.rawValue,
            attachedSheet: window.attachedSheet.map(identify) ?? "nil",
            alertText: window.attachedSheet.map(alertText) ?? alertText(window))
    }
    return conditionWaitFormatState(active: app.isActive, key: app.keyWindow.map(identify),
        main: app.mainWindow.map(identify), windows: windows, totalWindowCount: allWindows.count)
}

/// Never delay a cancelled background wait for MainActor. Async diagnostics may describe a later state.
nonisolated func conditionWaitFailure(_ description: String,
    printSink: @escaping @Sendable (String) -> Void = { print($0) }
) -> ConditionWaitError {
    @MainActor func emit(_ prefix: String) {
        printSink(conditionWaitAppKitState().split(separator: "\n").map { "  \(prefix): " + $0 }.joined(separator: "\n"))
    }
    if Thread.isMainThread {
        MainActor.assumeIsolated { emit("appkit") }
    } else {
        DispatchQueue.main.async { emit("appkit(async)") }
    }
    return ConditionWaitError(description: description)
}

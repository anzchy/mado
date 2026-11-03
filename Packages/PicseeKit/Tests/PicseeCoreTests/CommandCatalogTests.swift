import Testing
import PicseeCore

@Test func commandCatalog() {
    let expected: [(CommandID, String, Bool)] = [
        (.preview, " ", false), (.previous, "\u{f702}", false), (.next, "\u{f703}", false),
        (.escape, "\u{1b}", false), (.enter, "\r", false), (.fit, "0", false),
        (.actualPixels, "1", false), (.zoomIn, "+", false), (.zoomOut, "-", false),
        (.search, "f", true), (.open, "o", true), (.inspector, "i", true)
    ]
    let implemented: Set<CommandID> = [.preview, .enter, .previous, .next, .escape, .fit, .actualPixels, .zoomIn, .zoomOut, .search, .open, .inspector]
    #expect(CommandID.allCases.count == 12)
    #expect(Set(CommandID.allCases.map(\.rawValue)).count == 12)
    #expect(Set(CommandID.menuCommands) == implemented.subtracting([.search]))
    let zoom: Set<CommandID> = [.fit, .actualPixels, .zoomIn, .zoomOut]
    for (id, key, modifier) in expected {
        #expect(id.defaultKey == key)
        #expect(id.usesCommand == modifier)
        #expect(id.isImplemented == implemented.contains(id))
        #expect((id.shortcutHint != nil) == implemented.contains(id))
        #expect(CommandID.matching(key: key, command: modifier) == id)
        // #348: zoom commands gained ⌘ forms; the ⌘ side is asserted below.
        if !zoom.contains(id) { #expect(CommandID.matching(key: key, command: !modifier) == nil) }
        #expect(CommandID.allCases.filter { $0.defaultKey == key && $0.usesCommand == modifier }.count == 1)
    }
    #expect(CommandID.fit.shortcutHint == "0")
    #expect(CommandID.open.shortcutHint == "⌘O")
    #expect(CommandID.matching(key: "=", command: false) == .zoomIn)
    #expect(CommandID.matching(key: "−", command: false) == .zoomOut)
    #expect(CommandID.matching(key: "z", command: false) == nil)
    let matches: [(String, Bool, CommandID?)] = [
        ("0", true, .actualPixels), ("9", true, .fit), ("+", true, .zoomIn), ("=", true, .zoomIn),
        ("-", true, .zoomOut), ("−", true, .zoomOut),
        ("0", false, .fit), ("1", false, .actualPixels), ("+", false, .zoomIn), ("=", false, .zoomIn),
        ("-", false, .zoomOut), ("−", false, .zoomOut),
        ("1", true, nil), ("_", true, nil), ("9", false, nil), ("f", false, nil), ("o", false, nil), ("i", false, nil),
        ("f", true, .search), ("o", true, .open), ("i", true, .inspector),
    ]
    for (key, command, id) in matches {
        #expect(CommandID.matching(key: key, command: command) == id, "\(key) ⌘=\(command)")
    }
    let commandKeys: [CommandID: String] = [.fit: "9", .actualPixels: "0", .zoomIn: "+", .zoomOut: "-"]
    for id in CommandID.allCases { #expect(id.commandKey == commandKeys[id], "\(id)") }
    #expect(CommandID.actualPixels.shortcutHint == "1")
    #expect(CommandID.zoomIn.shortcutHint == "+")
    #expect(CommandID.zoomOut.shortcutHint == "-")
}

/// #348: every binding a command shows or catches resolves back to it, and no key belongs to two commands.
@Test func commandBindingsRoundTripAndAreInjective() {
    func normalised(_ binding: CommandKeyBinding) -> CommandKeyBinding {
        CommandKeyBinding(key: binding.key == "=" ? "+" : (binding.key == "−" ? "-" : binding.key), command: binding.command)
    }
    func bindings(_ id: CommandID) -> [CommandKeyBinding] { [id.menuBinding] + id.alternateMenuBindings }
    for id in CommandID.allCases {
        for binding in bindings(id) {
            #expect(CommandID.matching(key: binding.key, command: binding.command) == id, "\(id) \(binding)")
        }
        #expect(bindings(id).contains(CommandKeyBinding(key: id.defaultKey, command: id.usesCommand)), "\(id) kept its key")
        if let key = id.commandKey {
            #expect(id.menuBinding == CommandKeyBinding(key: key, command: true), "\(id)")
        } else {
            #expect(id.menuBinding == CommandKeyBinding(key: id.defaultKey, command: id.usesCommand), "\(id)")
        }
    }
    // ⌘+ and ⌘= are one normalised binding of zoomIn by design; injectivity is across commands.
    let all = CommandID.allCases.flatMap { Set(bindings($0).map(normalised)) }
    #expect(Set(all).count == all.count)
    let keys = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }
        + ["−", "\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}", "\u{1b}", "\r", "\t", ""]
    for key in keys {
        for command in [true, false] {
            let probe = normalised(CommandKeyBinding(key: key, command: command))
            let owners = CommandID.allCases.filter { bindings($0).map(normalised).contains(probe) }
            #expect(owners.count <= 1, "\(key) ⌘=\(command)")
            #expect(CommandID.matching(key: key, command: command) == owners.first, "\(key) ⌘=\(command)")
        }
    }
    #expect(CommandID.fit.menuBinding == CommandKeyBinding(key: "9", command: true))
    #expect(Set(CommandID.zoomIn.alternateMenuBindings)
        == [CommandKeyBinding(key: "+", command: false), CommandKeyBinding(key: "=", command: true)])
}

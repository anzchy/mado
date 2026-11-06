import PicseeCore

@MainActor
public struct CommandRouter {
    private let implementedCommands: Set<CommandID>
    /// Production keeps the catalog unchanged; state-seam tests can enable future commands.
    public init(implementedCommands: Set<CommandID> = Set(CommandID.allCases.filter(\.isImplemented))) {
        self.implementedCommands = implementedCommands
    }
    @discardableResult
    public func route(_ command: CommandID, from entry: CommandEntry, to session: ViewerSession,
                      commandModified: Bool = false) -> Bool {
        guard implementedCommands.contains(command),
              session.isEnabled(command, commandModified: commandModified) else { return false }
        if entry == .key {
            guard !session.isMenuTracking else { return false }
            if session.inspectorFocus.focus == .textInput && !command.usesCommand && command != .escape { return false }
        }
        if command == .escape && session.isMenuTracking { return false }
        session.perform(command, from: entry)
        return true
    }
}

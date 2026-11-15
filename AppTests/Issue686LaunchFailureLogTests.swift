import AppKit
import Testing

// #686 P7-10 CAP-02 fix round 1 (opus M2): a failed Launch Services open of Mado is logged by the helper, with the
// failure kind only: no file name and no user path in the line, which the public log keeps.

private final class Lines686: @unchecked Sendable { var lines: [String] = [] }

@MainActor @Test(.timeLimit(.minutes(2))) func issue686FailedMadoOpenIsLoggedWithoutPaths() async throws {
    let lines = Lines686()
    let capture = URL(fileURLWithPath: "/Users/someone/Downloads/mado-20261115153012.png")
    let workspaceError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                                 userInfo: [NSFilePathErrorKey: capture.path, NSURLErrorKey: capture])
    let helper = URL(fileURLWithPath: "/Users/someone/Applications/Mado.app/Contents/Library/LoginItems/MadoCaptureHelper.app")
    let failing = CaptureMadoLauncher(helperBundle: helper, openFile: { _, _ in throw workspaceError },
                                      openApp: { _ in throw workspaceError }, log: { lines.lines.append($0) })
    await #expect(throws: NSError.self) { try await failing.openInMado(capture) }
    await #expect(throws: NSError.self) { try await failing.bringMadoForward() }

    let loose = CaptureMadoLauncher(helperBundle: URL(fileURLWithPath: "/Users/someone/MadoCaptureHelper.app"),
                                    openFile: { _, _ in }, openApp: { _ in }, log: { lines.lines.append($0) })
    await #expect(throws: CaptureMadoLauncher.Failure.madoNotFound) { try await loose.openInMado(capture) }
    await #expect(throws: CaptureMadoLauncher.Failure.madoNotFound) { try await loose.bringMadoForward() }

    try #require(lines.lines.count == 4)
    #expect(lines.lines[0].contains("action=file"))
    #expect(lines.lines[1].contains("action=app"))
    #expect(lines.lines[0].contains("error=\(NSCocoaErrorDomain)#\(NSFileReadNoPermissionError)"))
    #expect(lines.lines[2].contains("action=file"))
    #expect(lines.lines[2].contains("error=madoNotFound"))
    #expect(lines.lines[3].contains("error=madoNotFound"))
    for line in lines.lines {
        #expect(line.contains("outcome=failed"))
        #expect(!line.contains("/Users"), "no user path: \(line)")
        #expect(!line.contains("someone"))
        #expect(!line.contains("mado-20261115153012"))
    }

    let working = CaptureMadoLauncher(helperBundle: helper, openFile: { _, _ in }, openApp: { _ in },
                                      log: { lines.lines.append($0) })
    try await working.openInMado(capture)
    try await working.bringMadoForward()
    #expect(lines.lines.count == 4, "a working open logs nothing")
}

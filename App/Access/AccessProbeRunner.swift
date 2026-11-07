#if DEBUG
import AppKit
import Foundation
import PicseeInfrastructure
import os

@MainActor
enum AccessProbeRunner {
    private struct StoredBookmark: Codable {
        let id: UUID
        let bookmarkKind: String
        let originalURL: URL
        let data: Data
    }

    private struct Output: Encodable {
        let id: UUID
        let bookmarkKind: String
        let originalURL: URL
        let report: AccessProbeReport
    }

    private static let logger = Logger(subsystem: "io.github.anzchy.mado", category: "access")

    @discardableResult
    static func runIfRequested(arguments: [String]) -> Bool {
        runIfRequested(arguments: arguments, runProbe: {
            do {
                let container = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("Mado/AccessProbe", isDirectory: true)
                let output = try run(containerURL: container, chooseFolders: chooseFoldersWithPanel)
                logger.notice("\(resultsLogMessage(for: output), privacy: .public)")
            } catch {
                logger.error("AccessProbe failed: \(String(describing: error), privacy: .private)")
            }
        }, terminate: {
            NSApplication.shared.terminate(nil)
        })
    }

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains("-PicseeAccessProbe")
    }

    static func resultsLogMessage(for output: URL) -> String {
        "AccessProbe results ready"
    }

    @discardableResult
    static func runIfRequested(arguments: [String], runProbe: () -> Void, terminate: () -> Void) -> Bool {
        guard isRequested(arguments: arguments) else { return false }
        runProbe()
        terminate()
        return true
    }

    static func run(containerURL: URL, chooseFolders: () -> [URL]) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let storeURL = containerURL.appendingPathComponent("bookmarks.json")
        let outputURL = containerURL.appendingPathComponent("results.jsonl")
        let gatherer = AccessProbeFactGatherer()
        var bookmarks = try loadBookmarks(from: storeURL)
        if bookmarks.isEmpty {
            for folder in chooseFolders() {
                bookmarks.append(try StoredBookmark(
                    id: UUID(),
                    bookmarkKind: "plain",
                    originalURL: folder,
                    data: gatherer.makeBookmark(for: folder, storingVolumeProperties: false)
                ))
                bookmarks.append(try StoredBookmark(
                    id: UUID(),
                    bookmarkKind: "enriched",
                    originalURL: folder,
                    data: gatherer.makeBookmark(for: folder, storingVolumeProperties: true)
                ))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(bookmarks).write(to: storeURL, options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = Data()
        for bookmark in bookmarks {
            let output = Output(
                id: bookmark.id,
                bookmarkKind: bookmark.bookmarkKind,
                originalURL: bookmark.originalURL,
                report: gatherer.gather(bookmarkData: bookmark.data)
            )
            lines.append(try encoder.encode(output))
            lines.append(Data([0x0a]))
        }
        try lines.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func loadBookmarks(from url: URL) throws -> [StoredBookmark] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([StoredBookmark].self, from: Data(contentsOf: url))
    }

    static func collectFolders(chooseOne: () -> URL?) -> [URL] {
        var folders: [URL] = []
        while let folder = chooseOne() {
            folders.append(folder)
        }
        return folders
    }

    private static func chooseFoldersWithPanel() -> [URL] {
        collectFolders {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
}
#endif

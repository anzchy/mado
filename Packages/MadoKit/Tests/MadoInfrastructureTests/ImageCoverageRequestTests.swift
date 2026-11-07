import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@Suite struct ImageCoverageRequestTests {
    // #161: the pipeline reads the header once and chooses the smallest covering edge for the real source.
    // The fixtures are 600×400 and 400×600, so a 212×148 tile keeps both edges below the source size.
    @Test(arguments: [("landscape-3x2.png", 222), ("portrait-2x3.png", 318)])
    func coverageRequestDecodesSmallestCoveringEdge(name: String, edge: Int) async throws {
        let pipeline = ImageIOPipeline(), tile = ThumbnailCoverage(width: 212, height: 148)
        let request = try await pipeline.request(for: fixture(name), covering: tile, identityRoot: nil)
        #expect(request.maximumPixelSize == edge)
        #expect(request.renderKey?.maximumPixelSize == edge)
        let image = try await pipeline.image(for: request).image
        #expect(image.width >= 212 && image.height >= 148)
        #expect(max(image.width, image.height) == edge)
    }

    @Test func coverageRequestUsesOrientedRatio() async throws {
        let pipeline = ImageIOPipeline(), tile = ThumbnailCoverage(width: 64, height: 32)
        // 1 and 3 keep the raw 128×96 ratio; 5 to 8 store 96×128 and rotate it upright.
        for orientation in [1, 3, 5, 6, 7, 8] {
            let request = try await pipeline.request(for: fixture("orientation-\(orientation).tiff"), covering: tile, identityRoot: nil)
            #expect(request.maximumPixelSize == 64, "orientation \(orientation)")
            let image = try await pipeline.image(for: request).image
            #expect(image.width == 64 && image.height == 48, "orientation \(orientation)")
        }
    }

    @Test func coverageRequestThroughAccessSourceReachesTheGrid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("landscape.png")
        try FileManager.default.copyItem(at: fixture("landscape-3x2.png"), to: file)
        let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
            store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p306")
        let root = try await access.grant(folder: folder)
        let pipeline = ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: folder.appendingPathComponent("cache")))
        let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
        let (request, image) = try await source.image(covering: ThumbnailCoverage(width: 424, height: 296), priority: .visible)
        await source.close()
        #expect(request.maximumPixelSize == 444 && request.renderKey?.maximumPixelSize == 444)
        #expect(request.priority == .visible)
        #expect(image.image.width == 444 && image.image.height == 296)
    }
}

// The header read only learns the ratio; the budget is checked against the edge actually chosen.
@Test func coverageRequestChecksBudgetAtTheChosenEdgeNotTheCeiling() async throws {
    let tile = ThumbnailCoverage(width: 16, height: 12)
    let cost = try DecodeBudget.outputCost(width: 1280, height: 960, maximumPixelSize: 16, bytesPerPixel: 4, budget: .max)
    let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: 2 * cost))
    let request = try await pipeline.request(for: fixture("coordinate-grid.png"), covering: tile, identityRoot: nil)
    #expect(request.maximumPixelSize == 16)
    #expect(try await pipeline.image(for: request).image.width == 16)
}

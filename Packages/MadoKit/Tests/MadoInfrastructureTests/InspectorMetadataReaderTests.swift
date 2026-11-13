import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private actor InspectorLease: AccessLeasing {
    var allowed = true
    func deny() { allowed = false }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        guard allowed else { throw FileAccessError.startFailed }
        return AccessLease(url: URL(fileURLWithPath: "/tmp"), rootID: nil)
    }
    func release(_ lease: AccessLease) {}
}

private actor BrokenInspectorLease: AccessLeasing {
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        throw NSError(domain: "InspectorLeaseTest", code: 42)
    }
    func release(_ lease: AccessLease) {}
}

@Test(.timeLimit(.minutes(2))) func issue136CancellationReachesImageIOWorker() async throws {
    let reader = ImageIOInspectorMetadataReader(access: InspectorLease(), workerStarted: {
        // Cancel before handler registration, so onCancel runs even if the worker
        // has already finished. An asynchronous notification can arrive too late.
        withUnsafeCurrentTask { $0?.cancel() }
    })
    let url = fixture("landscape-3x2.png")
    let task = Task { try await reader.read(url, access: .fileGrant(url)) }
    do {
        _ = try await task.value
        Issue.record("Expected the cancelled metadata read to throw")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test(.timeLimit(.minutes(2))) func issue136InspectorReadsRealImageHeaderAndAttributes() async throws {
    let url = fixture("landscape-3x2.png")
    let reader = ImageIOInspectorMetadataReader(access: InspectorLease(), pipeline: ImageIOPipeline())
    let value = try await reader.read(url, access: .fileGrant(url))
    #expect(value.pixelWidth == 600)
    #expect(value.pixelHeight == 400)
    #expect(value.typeIdentifier == "public.png")
    #expect(value.thumbnailData != nil)
    #expect(value.byteSize == Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!))
}

@Test(.timeLimit(.minutes(2))) func issue136InspectorReportsUnreadableAndNoPermissionSeparately() async {
    let lease = InspectorLease(), reader = ImageIOInspectorMetadataReader(access: lease)
    let url = fixture("not-an-image.jpg")
    do { _ = try await reader.read(url, access: .fileGrant(url)); Issue.record("Expected unreadable") }
    catch { #expect(error as? InspectorReadError == .unreadable) }
    await lease.deny()
    do { _ = try await reader.read(url, access: .fileGrant(url)); Issue.record("Expected no permission") }
    catch { #expect(error as? InspectorReadError == .noPermission) }
}

@Test(.timeLimit(.minutes(2))) func issue136InspectorMissingFileAndUnexpectedLeaseErrorAreUnreadable() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        _ = try await ImageIOInspectorMetadataReader(access: InspectorLease()).read(missing, access: .fileGrant(missing))
        Issue.record("Expected missing file to be unreadable")
    } catch { #expect(error as? InspectorReadError == .unreadable) }
    do {
        _ = try await ImageIOInspectorMetadataReader(access: BrokenInspectorLease()).read(missing, access: .fileGrant(missing))
        Issue.record("Expected unexpected lease error to be unreadable")
    } catch { #expect(error as? InspectorReadError == .unreadable) }
}

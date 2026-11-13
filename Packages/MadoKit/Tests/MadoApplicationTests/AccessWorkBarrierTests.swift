import Foundation
import Testing
import MadoCore
import MadoApplication

@MainActor @Test(.timeLimit(.minutes(2))) func t229WorkPermitsRevokeBeforeLossObserversAndNeverRevive() throws {
    let state = AccessState(), a = AccessRootID(), b = AccessRootID()
    state.register(a, volumeUUID: "a"); state.register(b, volumeUUID: "b")
    let old = try #require(state.permit(for: a)), other = try #require(state.permit(for: b))
    var observedRevoked = false
    _ = state.observe { _ in observedRevoked = !old.isCurrent }
    state.diskUnmounted(volumeUUID: "a")
    #expect(observedRevoked)
    #expect(!old.isCurrent && other.isCurrent)
    #expect(throws: CancellationError.self) { try old.check() }
    let attempt = try #require(state.diskMounted(volumeUUID: "a").first)
    #expect(state.completeRecovery(attempt, verified: true))
    #expect(!old.isCurrent)
    let fresh = try #require(state.permit(for: a))
    #expect(fresh.isCurrent)
    state.reauthorize(a, volumeUUID: "a")
    #expect(!fresh.isCurrent)
    let selected = try #require(state.permit(for: a))
    #expect(selected.isCurrent)
    state.forget(a)
    #expect(!selected.isCurrent && other.isCurrent)
    #expect(state.permit(for: a) == nil)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229SourceDiscardsHeldDecodeAndDrainsLeaseAfterIO() async throws {
    let state = AccessState(), id = AccessRootID()
    state.register(id, volumeUUID: "a")
    let permit = try #require(state.permit(for: id))
    let access = AccessProbe(), pipeline = AccessPipelineProbe(access: access)
    await pipeline.configure(blocked: true)
    let source = try await AccessImageSource.open(.root(id, file: URL(fileURLWithPath: "/tmp/t229.png")),
        access: access, pipeline: pipeline, accessPermit: permit)
    let pending = Task { try await source.image(maximumPixelSize: 128) }
    await pipeline.waitUntilDecoding()
    state.diskUnmounted(volumeUUID: "a")
    await source.close()
    #expect(await access.count() == 2)
    await pipeline.resume()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await access.count() == 0)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229IdleSourceRevocationReleasesDisplayLease() async throws {
    let state = AccessState(), id = AccessRootID()
    state.register(id, volumeUUID: "a")
    let access = AccessProbe(), pipeline = AccessPipelineProbe(access: access)
    let permit = try #require(state.permit(for: id))
    let source = try await AccessImageSource.open(.root(id, file: URL(fileURLWithPath: "/tmp/t229-idle.png")),
        access: access, pipeline: pipeline, accessPermit: permit)
    #expect(await access.count() == 1)
    state.diskUnmounted(volumeUUID: "a")
    await #expect(throws: CancellationError.self) { try await source.image(maximumPixelSize: 128) }
    #expect(await access.count() == 0)
    #expect(await pipeline.requests == 0)
}

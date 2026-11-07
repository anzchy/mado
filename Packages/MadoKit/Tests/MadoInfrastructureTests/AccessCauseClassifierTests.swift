import Foundation
import Testing
@testable import MadoInfrastructure

private let probeURL = URL(fileURLWithPath: "/Volumes/Photos/2026", isDirectory: true)

private func probeFacts(
    uuid: String? = "volume-a",
    volumeName: String? = "Photos",
    mountedVolumes: [AccessProbeVolume]? = nil,
    resolution: AccessProbeResolution = .resolved(probeURL, stale: false),
    scopeStarted: Bool? = true,
    listing: AccessProbeDirectoryListing? = .succeeded(entryCount: 3),
    isInTrash: Bool = false
) -> AccessProbeFacts {
    AccessProbeFacts(
        volume: AccessProbeVolume(uuid: uuid, url: URL(fileURLWithPath: "/Volumes/Photos"), name: volumeName),
        mountedVolumes: mountedVolumes ?? [AccessProbeVolume(uuid: "volume-a", url: nil, name: "Photos")],
        resolution: resolution,
        scopeStarted: scopeStarted,
        listing: listing,
        isInTrash: isInTrash
    )
}

@Test func accessCauseMatchesVolumesByUUIDOnly() {
    let sameNameOtherVolume = AccessProbeVolume(uuid: "volume-b", url: nil, name: "Photos")
    let result = AccessCauseClassifier.classify(probeFacts(mountedVolumes: [sameNameOtherVolume]))
    #expect(result.cause == .diskNotConnected)
    #expect(!result.isInTrash)
}

@Test func accessCauseRejectsNilUUIDForDiskCase() {
    let result = AccessCauseClassifier.classify(probeFacts(
        uuid: nil,
        mountedVolumes: [],
        resolution: .failed(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
        scopeStarted: nil,
        listing: nil
    ))
    #expect(result.cause == .unknown)
}

@Test func accessCauseMountedVolumeWithFailedResolutionIsNotFound() {
    let result = AccessCauseClassifier.classify(probeFacts(
        resolution: .failed(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
        scopeStarted: nil,
        listing: nil
    ))
    #expect(result.cause == .notFound)
}

@Test(arguments: [
    AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
    AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
    AccessProbeError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
])
func accessCausePermissionRefusalIsAccessExpired(error: AccessProbeError) {
    let result = AccessCauseClassifier.classify(probeFacts(listing: .failed(error)))
    #expect(result.cause == .accessExpired)
}

@Test(arguments: [Int(EPERM), Int(EACCES)])
func accessCauseUnderlyingPermissionRefusalIsAccessExpired(code: Int) {
    let error = AccessProbeError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadUnknownError,
        underlyingErrors: [AccessProbeError(domain: NSPOSIXErrorDomain, code: code)]
    )
    let result = AccessCauseClassifier.classify(probeFacts(listing: .failed(error)))

    #expect(result.cause == .accessExpired)
}

@Test func accessCauseOtherListingFailureIsUnknown() {
    let result = AccessCauseClassifier.classify(probeFacts(
        listing: .failed(AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
    ))
    #expect(result.cause == .unknown)
}

@Test func accessCauseStaleResolvedAndListedBookmarkIsReadable() {
    let result = AccessCauseClassifier.classify(probeFacts(resolution: .resolved(probeURL, stale: true)))
    #expect(result.cause == .readable)
}

@Test func accessCauseTrashIsSeparateAndNeverReadable() {
    let result = AccessCauseClassifier.classify(probeFacts(
        resolution: .resolved(probeURL, stale: true),
        isInTrash: true
    ))
    // #231: T1 proves actual Trash is Not Found, irrespective of resolution.
    #expect(result.cause == .notFound)
    #expect(result.isInTrash)
}

@Test func accessCauseDoesNotUseScopeAloneAsReadabilityEvidence() {
    let startedWithoutListing = AccessCauseClassifier.classify(probeFacts(listing: nil))
    let listedWithoutStartedScope = AccessCauseClassifier.classify(probeFacts(scopeStarted: false))
    #expect(startedWithoutListing.cause == .unknown)
    #expect(listedWithoutStartedScope.cause == .readable)
}


// #230: only actual refusal on a resolved root supports the specific cause.
@Test(.timeLimit(.minutes(2))) func t230ResolvableRootRefusalClassifiesWithoutGuessing() {
    let refusals = [
        AccessProbeError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
        AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
        AccessProbeError(domain: "wrapper", code: 8, underlyingErrors: [
            AccessProbeError(domain: "nested", code: 9, underlyingErrors: [
                AccessProbeError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)])]),
        AccessProbeError(domain: "wrapper", code: 8, underlyingErrors: [
            AccessProbeError(domain: "nested", code: 9, underlyingErrors: [
                AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])])
    ]
    for refusal in refusals {
        #expect(AccessCauseClassifier.classify(probeFacts(listing: .failed(refusal))) ==
            AccessProbeClassification(cause: .accessExpired, isInTrash: false))
        #expect(AccessCauseClassifier.classify(probeFacts(
            resolution: AccessProbeResolution(url: nil, stale: nil, error: nil), listing: .failed(refusal))).cause == .unknown)
        #expect(AccessCauseClassifier.classify(probeFacts(
            resolution: .failed(domain: "bookmark", code: 1), listing: .failed(refusal))).cause == .notFound)
        #expect(AccessCauseClassifier.classify(probeFacts(listing: .failed(refusal), isInTrash: true)) ==
            AccessProbeClassification(cause: .notFound, isInTrash: true))
    }
    for code in [Int(EIO), Int(ENOENT)] {
        #expect(AccessCauseClassifier.classify(probeFacts(listing: .failed(
            AccessProbeError(domain: NSPOSIXErrorDomain, code: code)))).cause == .unknown)
    }
    #expect(AccessCauseClassifier.classify(probeFacts(listing: nil)).cause == .unknown)
    #expect(AccessCauseClassifier.classify(probeFacts()).cause == .readable)
}

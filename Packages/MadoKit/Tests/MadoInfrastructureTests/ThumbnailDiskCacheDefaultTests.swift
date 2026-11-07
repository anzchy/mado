import Testing
@testable import MadoInfrastructure

@Test func p304DefaultCacheCapMatchesArchitecture() {
    #expect(ThumbnailDiskCache.defaultHighWaterBytes == 2 * 1024 * 1024 * 1024)
    #expect(ThumbnailDiskCache.defaultLowWaterBytes == ThumbnailDiskCache.defaultHighWaterBytes * 3 / 4)
}

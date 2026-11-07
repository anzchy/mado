---
status: proposed
date: 2026-10-24
---

# ADR-009: P3-03 needs a lease-bound thumbnail cache seam

## WI-0 evidence

`P303DurabilityProbeTests` uses real TIFF bytes and an atomic replacement with the same byte count and restored modification date. The two `FileRevisionReader` values differ only by their session resource tokens, and both `RenderKey.persistentEncoding` values are nil. Streaming SHA-256 distinguishes the bytes. It also confirms that `AccessImageSource` holds a `FileAccess` lease before requesting and decoding through a real `ImageIOPipeline`.

The same probe calls the public `ImageIOPipeline.request(for:maximumPixelSize:identityRoot:)` and `image(for:)` directly, with a caller-supplied root, and obtains pixels without any `AccessLeasing` instance. `ImageDecodeRequest` and `ItemIdentityRoot` are publicly constructible. A disk lookup added to that public pipeline route would have no enforceable proof that authorization was obtained or remains valid. Adding the store there would violate issue #107's access condition even if the normal App caller uses `AccessImageSource`.

## Proposed decision and r2 scope amendment

1. Add a narrow cache port to `Packages/PicseeKit/Sources/PicseeCore/Ports/` and call it only within `AccessImageSource.image`'s existing `access.withLease` closure. Inject its Infrastructure implementation from `App/PicseeApp.swift`. The public `ImageIOPipeline` APIs continue to decode but have no disk-cache lookup. The r2 amendment explicitly authorizes `Packages/PicseeKit/Sources/PicseeApplication/Access/AccessImageSource.swift` and one new Core port file.
2. The cache port accepts only requested thumbnail renders with a root-relative `ItemID`. Its implementation hashes the source with streaming SHA-256 on an off-main executor while the lease is live. Start with a 32 MiB source-file eligibility ceiling, 1 MiB chunks, a cancellation check per chunk, and a post-hash path revision check. A file over the ceiling, an unreadable file, an unverifiable root identity, or a cancelled request skips persistence and follows normal decode. Hashing occurs for requested eligible thumbnails only, never during a folder scan. The ceiling is an initial policy to test, not a measured optimal value.
3. Include the content digest, stable root-relative item encoding, frame/page, edge, preview mode, purpose, orientation/color/alpha/HDR policy, decoder version, encoder version, and a key-format version in a new length-delimited persistent encoding; SHA-256 of that encoding names the payload. Keep the SQLite schema version separate. Never hash `RenderKey.stableEncoding` or drop its resource token. The content digest replaces the session token as durable revision evidence; the token remains useful for same-session source-change checks.
4. On a hit, validate a current access lease and source identity/revision, compute the digest, and recheck the source after payload read before delivery. On a miss, decode under the same lease; verify the decoded image revision and source evidence before publishing a payload. A source replacement during hash/decode must fail or retry as a normal miss; no old-key write may publish new pixels. A same-inode, same-size, same-time in-place rewrite during hashing needs a stronger snapshot strategy or a documented skip condition before implementation can claim this case.

## Measured key cost and limits

Mac16,10, 16 GiB RAM, macOS 26.4, Xcode 26.6. A local Swift CryptoKit probe streamed 1 MiB chunks from local files, five sequential runs per file; timings exclude Swift compilation and image decode. The first run may include filesystem cache effects. These are single-machine observations, not a 5,000-item benchmark.

| Asset | Bytes | Five hash times (ms) | Median (ms) | Initial eligibility |
|---|---:|---|---:|---|
| Synthetic coordinate PNG | 15,599 | 0.293, 0.031, 0.025, 0.020, 0.021 | 0.025 | yes |
| Real HEIC SDR photo | 4,479,456 | 2.828, 1.689, 1.613, 1.623, 1.627 | 1.627 | yes |
| Real JPEG SDR photo | 10,500,045 | 5.390, 4.065, 3.903, 3.952, 4.018 | 4.018 | yes |
| Generated noisy 48 MP PNG | 48,020,708 | not hashed | — | no, over 32 MiB |
| Generated noisy 100 MP PNG | 100,040,573 | not hashed | — | no, over 32 MiB |

The probe did not run in a signed sandbox, under concurrent decode, on a cold storage device, or across 5,000 items. It does not establish a full-cache speedup. P3-08 must measure those conditions and may change the eligibility ceiling.

## P3-03 round 2 implementation evidence

`DurableThumbnailKey` uses `rkt1` and SHA-256 of a field-complete encoding. It includes root-relative item identity, a 64-hex content SHA-256, byte count, frame, edge, preview mode, render policy, decoder version, purpose, encoder version, and PNG payload policy. It excludes the session resource token and modification date. The separate `ThumbnailDiskCache` actor accepts only root-relative, frame-zero, oriented SDR requests at most 1024 pixels along the requested edge, 8-bit decoded output, a source of at most 32 MiB, and an encoded PNG of at most 8 MiB. It streams 1 MiB chunks with cancellation checks. The default directory is `Library/Caches/Picsee/Thumbnails` inside the App container.

On a hit, source revision/content are checked before the SQLite/payload read and again before delivery. The PNG bytes are checked against an index SHA-256 before ImageIO decoding, so a valid but unrelated same-size PNG is a miss. SQLite cache-version-2 rows also carry a checksum over their delivery metadata, including source dimensions; old rows without it miss and can be replaced. `AccessImageSource` independently checks cached item identity, session revision, pixel bounds, and source-size validity before delivery. On a miss, the existing pipeline decodes and reports its session revision; the cache compares source content again after encoding and after atomic payload publication, then inserts one SQLite row. A failed insert can leave an orphan payload; a missing or damaged index/payload causes a miss. The public pipeline image methods contain no disk-cache lookup. The `ThumbnailCacheProviding` bridge has package visibility; `AccessImageSource` alone invokes it under `access.withLease`.

Swift RED receipts `P3-03-WI-1`, `P3-03-WI-1-STORAGE`, `P3-03-WI-2`, `P3-03-WI-1-FIX1`, and `P3-03-WI-2-FIX1` preceded the corresponding behavior. Focused tests use real `FileRevisionReader`, `FileAccess` with injected test security scope, ImageIO, fresh cache/pipeline instances, same-size/same-mtime replacement, access denial and failed reacquisition, bad/missing payload and index, corrupted index dimensions, exact size boundary, and cancellation. This is not signed-sandbox or live revocation evidence. Concurrent in-place writes that occur and revert after the final content check cannot be ruled out by path-based hashing; the cache does not claim that stronger snapshot guarantee.

## Consequences

The r2 amendment authorizes the lease-bound seam. Keep this ADR proposed pending independent review and device evidence. End-to-end unit evidence supports `CACHE-02` Partial with explicit limits; `ACCESS-04` remains Absent. P3-04 still owns repair, eviction, and read/write leases; P3-05 owns clear generation; P3-08 owns scale and device evidence.

## Audit fix round `p303-fix-r1`

The independent audit found that a same-inode, equal-byte-count, restored-mtime in-place rewrite could keep the session `RenderKey` while changing the durable content digest. A disk miss for B then reused memory or in-flight pixels A and could persist A under B's digest. Eligible disk misses now request a fresh decode through the existing bounded admission queue, bypassing session memory lookup and keyed in-flight reuse. The store still verifies the source digest before and after payload publication. The cache's encoder key version is 2, so entries written before this correction cannot be read under the corrected key. A disk hit continues to use digest and payload checks under the access lease.

If store verification observes a changed or unreadable source, it throws typed `ImageLoadError.sourceChanged`; `AccessImageSource` propagates that result to the existing `ViewerImageLoader` retry path. Ordinary cache write errors continue to fall back to source decoding. A mutation detected after atomic payload write removes that payload before returning the source-change error; a failed index insert may still leave an unindexed orphan as in the initial design.

Unit tests cover same-pipeline in-place A→B pixels and a fresh cache/pipeline reopen, replacement at the post-write hook through access and loader, a benign index failure fallback, an independently decoded equal-byte-length foreign PNG, and eligible in-flight cancellation with a held decoder and real FileAccess lease accounting. They do not establish an atomic snapshot against a concurrent writer that changes and restores the source after the final check. Separate-process, signed-sandbox revocation, cold/warm scale, and device behavior remain unverified. Fresh decoding on a disk miss trades extra decode work for source correspondence; P3-08 must measure this path.

P3-04 update: next-access repair, approximate LRU eviction, process-local read/write leases, owned-temp sweeping, and the 2 GiB default high-water cap now have unit evidence; signed-device and P3-08 scale evidence remain open.

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。

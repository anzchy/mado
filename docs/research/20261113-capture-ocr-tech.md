Report-Task: capture-ocr-tech-research-r1
# capture-ocr-tech research: can Mado (sandboxed, Developer ID, macOS 14 floor) ship an embedded screenshot Minibar, open/annotate captures, save to ~/Downloads, and do cloud OCR (Baidu first) with an on-device fallback?

Researched 2026-11-13. Labels: CONFIRMED = official doc / release note / Apple-staff forum answer read today; INFERRED = reasoned from evidence; UNCONFIRMED = could not verify from a primary source. Static evidence only; nothing here was run on a device.

## Answer (overall)
- Capture is feasible inside the sandbox with ScreenCaptureKit (SCScreenshotManager, macOS 14+). No entitlement is needed, but the user must grant Screen & System Audio Recording. On macOS 15+, a capture that does not go through SCContentSharingPicker triggers an extra system alert ("bypass the system private window picker"). Apple staff name only two ways around it: the restricted persistent-content-capture entitlement (meant for screen-sharing products) or the system picker. Region capture of an arbitrary rectangle cannot use the picker, so a FastStone-style Minibar should expect the periodic alert. The cadence (monthly) comes from press reports, not Apple.
- `screencapture` CLI: a child process inherits Mado's sandbox. Interactive mode is known to hit a sandbox denial, and Apple DTS advises using the API instead. Don't build on it.
- Helper: a login item (SMAppService, Contents/Library/LoginItems) is supported. Whether its TCC entry is separate from Mado's and what name it shows are UNCONFIRMED; this needs a device test. Floating over other apps' full-screen Spaces needs an accessory-policy (LSUIElement) process plus a non-activating NSPanel at .screenSaver level (Apple DTS, tested on macOS 26). That is the strongest technical reason for a separate helper.
- File hand-off: NSWorkspace.open gives the receiving app a read/write sandbox extension for that one file only, not its folder (Apple DTS). To browse sibling captures, Mado needs a Downloads entitlement or a user-granted Access Root on the save folder.
- Annotation write-back: overwriting needs a read/write grant on the file. Safe-save (temp file + atomic replace) also needs directory access. ADR-007 currently rules out overwrite in v1.
- Baidu OCR: OAuth client-credentials token valid 30 days. Free quota is 1,000/month (individual) for standard and accurate, and 500/month for accurate-with-location. Real-name verification is required for both the free quota and paid use, and the personal path documents only a mainland ID card. Image retention specific to OCR is UNCONFIRMED. Cloud OCR conflicts with ADR-015 ("no other network requests, no image upload").
- On-device: Vision VNRecognizeTextRequest (macOS 10.15+; Chinese in .accurate only) returns bounding boxes and works on macOS 14. The Swift RecognizeTextRequest is macOS 15+. VisionKit on macOS is ImageAnalysisOverlayView (macOS 13+), which gives Live Text selection and a plain `text` string, but its documented API has no public per-line positions.

---

## A. Screen capture on macOS 14 / 15 / 26

**Answer:** Use ScreenCaptureKit. The sandbox does not block it, but TCC Screen Recording consent is required. Since macOS 15, non-picker capture adds a recurring "private window picker" alert. Apple says only "fewer dialogs" in 15.1. The monthly cadence is from the press.

Evidence:
- A1. macOS 14 release notes: "Use of legacy CGDisplayStream APIs to capture screen content will result in additional consent alerts. (110529324)". Source: https://developer.apple.com/documentation/macos-release-notes/macos-14-release-notes (ScreenSharing > Deprecations). macOS 14. CONFIRMED.
- A2. macOS 15 release notes: "Applications utilizing deprecated APIs for content capture such as CGDisplayStream & CGWindowListCreateImage can trigger system alerts indicating they might be able to collect detailed information about the user. Developers need to migrate to ScreenCaptureKit and SCContentSharingPicker. (120910350)". Source: https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes (ScreenCaptureKit > Deprecations). macOS 15.0. CONFIRMED.
- A3. macOS 15.1 release notes: "Applications using our deprecated content capture technologies now have enhanced user awareness policies. Users will see fewer dialogs if they regularly use apps in which they have already acknowledged and accepted the risks. (133431080)". The same notes add the MDM key `forceBypassScreenCaptureAlert` (131327961). Source: https://developer.apple.com/documentation/macos-release-notes/macos-15_1-release-notes. macOS 15.1. CONFIRMED. The wording covers "deprecated" technologies only; whether it also relaxes alerts for ScreenCaptureKit is UNCONFIRMED.
- A4. Apple DTS (Quinn), Oct 2024, forum thread 765103. A minimal ScreenCaptureKit screenshot shows the normal "would like to record this computer's screen and audio" prompt on both 14.6.1 and 15.0. On 15.0 the second capture shows the "bypass the private window picker" alert. "AFAIK there are two ways to avoid that alert: Via the Persistent Content Capture (com.apple.developer.persistent-content-capture) entitlement ... specifically intended for screen sharing products. Present the system picker UI, SCContentSharingPicker." Source: https://developer.apple.com/forums/thread/765103. macOS 15.0. CONFIRMED (Apple staff; he hedges with "AFAIK").
- A5. A non-Apple developer reported that `SCScreenshotManager.captureImage()` still triggered the "Continue to Allow" warning on Sequoia beta 2 (24A5279h). No staff reply. Source: https://developer.apple.com/forums/thread/756908 (Jun 2024). INFERRED (user report, consistent with A4).
- A6. Cadence: early betas prompted weekly; from 15.0 beta 6 it is monthly, and prompts after restart/logout were dropped. Sources: https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/ and https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly (Aug 2024). Press only; no Apple doc states "monthly". UNCONFIRMED from a primary source.
- A7. macOS 26 behaviour of this alert (cadence and triggers): no Apple release note or staff post found. UNCONFIRMED.
- A8. A user-initiated capture (hotkey or button) avoids the alert: no Apple source says so. A4 names only the entitlement and the picker. UNCONFIRMED; treat as "does not avoid".
- A9. The persistent-content-capture entitlement is restricted and granted by Apple on request, intended for screen sharing / remote desktop. Sources: A4; forum threads https://developer.apple.com/forums/thread/761641 and /thread/770675. CONFIRMED that it targets screen-sharing products; whether a screenshot tool would be approved is UNCONFIRMED (INFERRED unlikely).
- A10. SCContentSharingPicker is available from macOS 14.0 and is "a picker presented by the operating system". It selects displays, windows or apps; the app receives an SCContentFilter (WWDC23 10136). Sources: https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker and https://developer.apple.com/videos/play/wwdc2023/10136/. CONFIRMED. It offers no arbitrary-rectangle mode (INFERRED from the API list: display/window/application styles only).
- A11. SCScreenshotManager, per its doc page:
  - The class is available from macOS 14.0.
  - `captureImage(contentFilter:configuration:)` and `captureSampleBuffer(contentFilter:configuration:)` take an SCContentFilter (display, window, or display minus windows) and an SCStreamConfiguration (output size, `sourceRect`).
  - `captureImage(in: CGRect)` captures a rect in points across displays, but is macOS 15.2+.
  - `captureScreenshot(contentFilter:configuration: SCScreenshotConfiguration)` and `captureScreenshot(rect:configuration:)` are macOS 26.0+.

  Sources: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager and the per-method pages. CONFIRMED. On macOS 14 a region needs a display filter plus a crop (configuration `sourceRect` or a post-capture crop). INFERRED.
- A12. Output size follows SCStreamConfiguration width/height in pixels. SCDisplay sizes are in points, so blurry results come from not scaling. Source: https://developer.apple.com/forums/thread/739593 (developer report). INFERRED.
- A13. Sandboxed apps can use ScreenCaptureKit. No Apple doc names a screen-capture sandbox entitlement. DTS answers point only to TCC (`CGRequestScreenCaptureAccess`, `CGPreflightScreenCaptureAccess`) and to ScreenCaptureKit (https://developer.apple.com/forums/thread/683860, 2021/2025). App Sandbox entitlement lists contain no screen-capture key. INFERRED (strong). A device check of a sandboxed Mado build is still needed.
- A14. TCC needs a stable signature. Ad hoc / "Sign to Run Locally" builds break TCC; use a stable identity (DTS, Aug 2024). Source: https://developer.apple.com/forums/thread/760112. CONFIRMED.
- A15. `screencapture` CLI:
  - Non-apps launched by a sandboxed app inherit its sandbox (DTS Quinn, https://developer.apple.com/forums/thread/123873). CONFIRMED.
  - `screencapture -i` from a sandboxed NSTask failed with "deny mach-register com.apple.screencapture.interactive". The community workaround was the temporary exception `com.apple.security.temporary-exception.mach-register.global-name`. Source: https://developer.apple.com/forums/thread/51236 (2016, no Apple reply). INFERRED.
  - DTS says using a tool instead of an API exposes you to compatibility problems and that "the path forward here is ScreenCaptureKit"; on 15 betas a `screencapture`-based XPC service was repeatedly prompted (https://developer.apple.com/forums/thread/760112, Jul 2024). CONFIRMED (staff).

## B. Embedded helper

**Answer:**
- A login-item helper app is supported (SMAppService, macOS 13+).
- Its TCC identity and System Settings name are UNCONFIRMED; test on a device.
- Sharing between helper and Mado:
  - App Group container: works for a notarized app if the group ID is in the provisioning profile or has the team prefix.
  - NSWorkspace.open: gives a per-file read/write extension.
  - Bookmark data passed over IPC: also works.
- Sibling browsing needs a folder grant.
- RegisterEventHotKey works without Accessibility per long-standing practice. Apple staff confirm the API is maintained, but no doc says "no Accessibility". INFERRED.
- Floating over full-screen apps on all Spaces needs an accessory/LSUIElement process plus a non-activating NSPanel at .screenSaver level. CONFIRMED by Apple DTS on macOS 26.

Evidence:
- B1. SMAppService (macOS 13.0+) registers LoginItems, LaunchAgents and LaunchDaemons. `loginItem(identifier:)` takes the helper's bundle identifier, and the helper must be in "the calling app's Contents/Library/LoginItems directory". `register()` launches "subject to user approval"; `openSystemSettingsLoginItems()` exists. Sources: https://developer.apple.com/documentation/servicemanagement/smappservice and .../loginitem(identifier:). CONFIRMED.
- B2. TCC "responsible code" (Quinn, "On File System Permissions", 2023-02-10 revision): for an app's helper tool, Apple wants "the app's name and usage description to appear in the alert", "the user's decision to be recorded for the whole app", and the decision to show "under the app's name". This relies on heuristics that can break, most often when a child daemonises. For launchd agents not attributed correctly, add `AssociatedBundleIdentifiers` to the launchd plist. Source: https://developer.apple.com/forums/thread/678819. CONFIRMED for helper tools; not stated for a separate login-item .app.
- B3. Whether a SMAppService login-item app (own bundle ID, launched by launchd, LSUIElement) gets its own Screen Recording entry, and under which name (its CFBundleDisplayName/CFBundleName or Mado's): UNCONFIRMED. INFERRED likely its own entry under its own bundle name, because launchd, not Mado, is the parent, and a daemon "generally cannot inherit its enclosing app's TCC privileges" (DTS, https://developer.apple.com/forums/thread/853725, seen in search summary only). Needs a device test on 14, 15 and 26.
- B4. App Group container (doc "Accessing files from the macOS App Sandbox"):
  - Apps in the same group can share containers via `containerURL(forSecurityApplicationGroupIdentifier:)` with the `com.apple.security.application-groups` entitlement.
  - Conditions: the app is notarized or from the Mac App Store, and "If your app is notarized, the app group's identifier is contained in your app's provisioning profile or prefixed with your Apple Developer team identifier". Otherwise the system shows a consent request.
  - On macOS 14+ the system ties containers to the code signature, also for launch agents.

  Source: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox. CONFIRMED.
- B5. NSWorkspace hand-off. DTS Quinn (thread 852014, ~Oct/Nov 2026): "When you open a document using NSWorkspace, the system issues a sandbox extension to the receiving process. That grants the receiving process the ability to read and write that file. But only that file. It doesn't grant access to the surrounding directory." The sender must itself have access to the file (thread 751810, May 2024: the system adds the extension, "It won't be able to do that if your app doesn't have access to the file in the first place"). Sandboxed apps must use NSWorkspace, not raw 'odoc' Apple events. Sources: https://developer.apple.com/forums/thread/852014 and https://developer.apple.com/forums/thread/751810. CONFIRMED.
- B6. Safe-save inside a single-file extension can fail. Preview's safe-save could not update a container PNG opened via NSWorkspace, but did when the file sat in a user-chosen folder with a security-scoped bookmark (macOS 26.6.2 report; DTS calls it a Preview bug). Source: thread 852014. CONFIRMED (staff diagnosis).
- B7. Bookmarks between processes: a bookmark created with options `[]` "refers to a security-scoped URL that grants access to the resource to a process that resolves the bookmark". You can pass it to a launch agent or XPC service, and the receiver's sandbox is extended when it uses the URL. Source: accessing-files doc (B4). CONFIRMED. Mado could grant the Settings-chosen save folder to the helper this way (INFERRED). The helper would then need its own app-scope bookmark to persist it (INFERRED).
- B8. Folder-level grants from open panels and Dock drops extend recursively to the folder contents. Persisted access uses app-scope security-scoped bookmarks with start/stop. Source: accessing-files doc. CONFIRMED.
- B9. Global hotkeys:
  - Apple Frameworks Engineer (thread 763878): macOS 15.0 intentionally required a modifier other than Shift/Option for RegisterEventHotKey, giving error -9868. This was lifted in 15.2 beta 2 (Option-only and Option-Shift allowed again). Source: https://developer.apple.com/forums/thread/763878 (Sep and Nov 2024). CONFIRMED.
  - A commenter claims the 15.0 restriction applied only to sandboxed apps; staff did not confirm (INFERRED).
  - RegisterEventHotKey needing no Accessibility permission, including in the sandbox, rests on practice reports (e.g. https://mjtsai.com/blog/2012/05/17/hotkeys-and-the-mac-app-store/). No Apple doc says so: INFERRED.
  - CGEvent taps / NSEvent global monitors for keys need Accessibility / Input Monitoring. INFERRED; not verified here.
- B10. Floating toolbar. DTS (thread 826308, May 2026, tested on macOS 26):
  - "macOS doesn't layer regular foreground apps above other apps' full-screen Spaces". Use `NSApp.setActivationPolicy(.accessory)` (the OP confirmed `LSUIElement` works too).
  - Use an NSPanel with `.nonactivatingPanel`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `level = .screenSaver`, and `collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]`, then `orderFrontRegardless()`.
  - ".floating (3) and .statusBar (25) both sit below full-screen content."

  Source: https://developer.apple.com/forums/thread/826308. CONFIRMED on macOS 26; macOS 14/15 behaviour is UNCONFIRMED. The collection-behavior semantics are documented at https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct. CONFIRMED.
- B11. Mado.app is a regular (Dock) app, so its own windows cannot float over other apps' full-screen Spaces unless Mado changes activation policy (INFERRED from B10). This is what motivates an LSUIElement helper.

## C. Entitlements

**Answer:**
- Saving captures to ~/Downloads with no prompt needs `com.apple.security.files.downloads.read-write` on whichever process writes, and on Mado too if Mado should list the folder without a grant.
- A Settings-chosen folder needs `files.user-selected.read-write` plus app-scope bookmarks (already present) on the process that writes.
- Annotation write-back:
  - "Save a copy" through a save panel needs `files.user-selected.read-write`.
  - "Overwrite" also needs write access to the containing folder for atomic replace, and is blocked by ADR-007 in v1.

Evidence:
- C1. `com.apple.security.files.downloads.read-write`: "whether the app may have read-write access to the Downloads folder", macOS 10.7+. Source: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.downloads.read-write. CONFIRMED. A read-only variant is UNCONFIRMED here (not fetched).
- C2. Mado's current entitlements are app-sandbox, files.user-selected.read-only, files.bookmarks.app-scope, network.client, and a mach-lookup temporary exception for Sparkle. Source: App/Resources/Mado.entitlements:5-17. CONFIRMED.
- C3. ADR-006 plans `files.user-selected.read-write` for P5-04, and all user-file writes (export, tags, trash) come after it. Source: docs/adr/0006-sandbox-from-p0-direct-distribution.md (Consequences). CONFIRMED. ADR-008 bookmarks are created without `.securityScopeAllowOnlyReadAccess`, and whether old read-only-era roots become writable must be tested in P5-04. Source: docs/adr/0008-folder-access-read-only-app-scoped-bookmarks.md. CONFIRMED.
- C4. ADR-007 rules (docs/adr/0007-save-as-by-default-no-overwrite-in-v1.md). CONFIRMED.
  - v1 has no overwrite of the source; the default is save-as.
  - Replacing another existing file goes through `itemReplacementDirectory` + `replaceItemAt`.
  - This includes the case where only the save panel authorised that one file.
- C5. Bookmarks: use `.withSecurityScope` for persistence, and `.securityScopeAllowOnlyReadAccess` only if no write is needed. Resolve, check staleness, then start and stop access. Source: accessing-files doc. CONFIRMED.
- C6. Overwriting a capture in place is plausible only with directory write access. Mado would hold that if it owns ~/Downloads (C1) or an Access Root on the save folder. A single-file extension from NSWorkspace (B5) is not enough for safe-save (B6). INFERRED.
- C7. ADR-008 rejects temporary exceptions for folder access. A `screencapture -i` mach-register exception (A15) would run against that spirit. INFERRED.

## D. Baidu OCR and alternatives

**Answer:**
- API Key + Secret Key are exchanged for an `access_token` valid 30 days.
- The REST endpoints are on `aip.baidubce.com`.
- Standard endpoints: 8 MB encoded, 4096 px longest side. Accurate endpoints: 10 MB, 8192 px.
- CHN_ENG is the default language.
- Each account gets 1,000 free calls a month (individual) on most general endpoints, and real-name verification is required.
- Paid tier guarantees 10 QPS; free tier "not guaranteed".
- Retention specific to OCR, and access from outside mainland China, are UNCONFIRMED.

Evidence:
- D1. Token: POST `https://aip.baidubce.com/oauth/2.0/token` with `grant_type=client_credentials`, `client_id`=API Key, `client_secret`=Secret Key. `expires_in` is in seconds, "有效期30天"; "Access token默认有效期为30天". The page also lists newer methods: a platform API Key (plain or short-term) and IAM AK/SK; use one per request. Source: https://ai.baidu.com/ai-doc/REFERENCE/Ck3dwjhhu (updated 2025-01-20). CONFIRMED.
- D2. general_basic (standard): `https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic`. Source: https://ai.baidu.com/ai-doc/OCR/zk3h7xz52 (updated 2024-07-31). CONFIRMED.
  - Size: base64 + urlencode ≤ 8 MB; shortest side ≥ 15 px, longest ≤ 4096 px; jpg/jpeg/png/bmp.
  - Also accepts url, pdf_file, ofd_file.
  - `language_type` default CHN_ENG; also ENG, JAP, KOR, FRE, SPA, POR, GER, ITA, RUS.
  - Optional `detect_direction`.
- D3. accurate_basic: `.../ocr/v1/accurate_basic`. Limits ≤ 10 MB, 15–8192 px, jpg/png/bmp. `language_type` includes auto_detect, CHN_ENG (default) and 25 languages. No location returned. Source: https://ai.baidu.com/ai-doc/OCR/1k3h7y3db (2024-07-31). CONFIRMED.
- D4. general (standard with location): `.../ocr/v1/general`, same limits as general_basic. Returns `location {left, top, width, height}` with origin top-left. Source: https://ai.baidu.com/ai-doc/OCR/vk3h7y58v (2024-07-31). CONFIRMED.
- D5. accurate (accurate with location): `.../ocr/v1/accurate`, 10 MB / 8192 px. Source: https://ai.baidu.com/ai-doc/OCR/tk3h7y2aq (2024-07-31). CONFIRMED.
  - Line `location`.
  - Optional `vertexes_location` quadrilaterals.
  - `recognize_granularity=small` gives per-character `chars[].location`.
- D6. webimage: `.../ocr/v1/webimage`, 8 MB / 4096 px, languages zh/en/ja/ko. A with-location variant exists. Source: https://ai.baidu.com/ai-doc/OCR/Sk3h7xyad (2024-07-31). CONFIRMED.
- D7. Other general-text APIs listed: handwriting, office document, table V2, seal, numbers, QR code, smart structuring. Separately there is a "大模型文档解析" (LLM document parsing) category. No multilingual-v2 or accurate-v2 endpoint is listed. Source: https://ai.baidu.com/ai-doc/OCR/Ek3h7xypm (2026-03-31). CONFIRMED.
- D8. Free quota per month, individual / enterprise. Source: https://ai.baidu.com/ai-doc/OCR/fk3h7xu7h (updated 2026-11-05). CONFIRMED.

  | Service | Individual | Enterprise |
  |---|---|---|
  | 标准版 (standard) | 1,000 | 2,000 |
  | 高精度版 (accurate) | 1,000 | 2,000 |
  | 标准含位置版 (standard with location) | 1,000 | 2,000 |
  | 高精度含位置版 (accurate with location) | 500 | 1,000 |
  | 网络图片 (webimage) | 1,000 | 2,000 |
  | 网络图片含位置版 (webimage with location) | 500 | 1,000 (period not stated) |

  - Failed calls also consume free quota.
  - Unused quota does not roll over.
- D9. Pay-as-you-go prices in CNY per successful call, first tier (≤50k calls/month) → top tier (>1M calls/month). Failed calls are not billed. Source: https://cloud.baidu.com/product-price/ocr.html (no date on page; fetched 2026-11-13). CONFIRMED for the numbers. The mapping of tables to products follows page order: INFERRED.

  | Service | ≤50k/month | >1M/month |
  |---|---|---|
  | standard | 0.0050 | 0.0025 |
  | standard with location | 0.0100 | 0.0047 |
  | accurate | 0.030 | 0.010 |
  | accurate with location | 0.040 | 0.020 |
  | webimage | 0.0100 | 0.0047 |

  Shared point packs: standard = 5 points, accurate = 10 points; 100k points cost CNY 330. Source: https://ai.baidu.com/ai-doc/OCR/Altmpe6ah (2026-10-22). CONFIRMED.
- D10. QPS: paid billing "保证单账户 10 QPS"; free status "不保证并发". Source: https://ai.baidu.com/ai-doc/OCR/Jk3h7xtsd (2026-06-05). CONFIRMED. A numeric free-tier QPS is UNCONFIRMED.
- D11. Real-name verification:
  - Free quota is auto-claimed "在您完成实名认证后".
  - Paid use requires "个人/企业实名认证" and no arrears (D10 source). CONFIRMED.
  - Personal verification documents list only a mainland ID card (name, ID number, ID photos; advanced = live check in app). Source: https://cloud.baidu.com/doc/UserGuide/s/Vjwvy3cya-en (2020-10-22). CONFIRMED that only the ID card is documented. Passports / HK-Macau-Taiwan / foreign IDs are UNCONFIRMED.
- D12. Data terms: the AI Open Platform Service Agreement (updated 2022-08-09) says the user owns "用户业务数据". Baidu may use it to "定位…问题，维护、改进为您提供的服务", and after termination Baidu deletes data after a buffer period. It has no OCR- or image-specific retention period and no training clause. Source: https://ai.baidu.com/ai-doc/REFERENCE/kk3dwjg7d. CONFIRMED for the general terms. OCR image retention period is UNCONFIRMED.
- D13. Use from outside mainland China (network reachability, terms, latency): no official statement found. The agreement forbids exporting platform services without approval (D12). UNCONFIRMED.
- D14. Other OCR APIs (one line each; auth / free quota / Chinese):
  - Tencent Cloud OCR: SecretId/SecretKey request signing (UNCONFIRMED, not fetched). 1,000 calls/month free on general OCR and others, issued monthly and shared within a pack (https://cloud.tencent.com/document/product/866/17619, updated 2026-11-11; CONFIRMED). Chinese yes (INFERRED, China-native product).
  - Alibaba Cloud OCR: AccessKey signing (UNCONFIRMED). Free quota exists in its deduction order "免费额度 > 资源包 > 后付费" but the amount is UNCONFIRMED (https://help.aliyun.com/document_detail/295347.html). An official FAQ says public-cloud OCR does not persist images or results (search summary of https://help.aliyun.com/zh/ocr/support/faq-about-alibaba-cloud-marketplace; INFERRED, not fetched). Chinese yes (INFERRED).
  - Google Cloud Vision (TEXT_DETECTION / DOCUMENT_TEXT_DETECTION): API key or service account (INFERRED). First 1,000 units/month free, then USD 1.50 per 1,000 up to 5M (https://cloud.google.com/vision/pricing, fetched 2026-11-13; CONFIRMED). Chinese zh Hans/Hant supported (https://cloud.google.com/vision/docs/languages; CONFIRMED).
  - Azure AI Vision Read: subscription key or Entra ID (INFERRED). F0 gives 5,000 transactions/month at 20 per minute; the S1 Read price was not shown (https://azure.microsoft.com/en-us/pricing/details/computer-vision/; CONFIRMED for F0). Chinese Simplified and Traditional supported (https://learn.microsoft.com/en-us/azure/ai-services/computer-vision/language-support; CONFIRMED).
  - OpenAI vision models: API key bearer (INFERRED). Free quota UNCONFIRMED. Chinese text reading INFERRED. It returns no native bounding boxes (INFERRED), so it is not a drop-in for positioned OCR.

## E. On-device fallback

**Answer:** Vision `VNRecognizeTextRequest` covers macOS 14. It supports Chinese only at `.accurate` (Chinese must be first in `recognitionLanguages`) and returns per-observation bounding boxes. The Swift `RecognizeTextRequest` and `RecognizedTextObservation` (bounding region, quadrilateral) need macOS 15. VisionKit on macOS is `ImageAnalyzer` + `ImageAnalysisOverlayView` (macOS 13+). It gives Live Text selection, copy, and a full `text` string. Its documented API exposes hit-testing (`hasText(at:)`) but no per-line rectangles. `ImageAnalysisInteraction` is the iOS class.

Evidence:
- E1. `VNRecognizeTextRequest`: macOS 10.15+. It returns `VNRecognizedTextObservation`, has `recognitionLevel` (fast/accurate), `recognitionLanguages`, `automaticallyDetectsLanguage`, `customWords` and `supportedRecognitionLanguages(for:revision:)`, and revisions 1–3. Source: https://developer.apple.com/documentation/vision/vnrecognizetextrequest. CONFIRMED.
- E2. `VNRecognizeTextRequestRevision3` is macOS 13.0+. WWDC22 10024: "This is the text recognizer that powers the amazing Live Text feature". It adds Korean and Japanese. `automaticallyDetectsLanguage` works "only for accurate recognition mode". Sources: https://developer.apple.com/documentation/vision/vnrecognizetextrequestrevision3 and https://developer.apple.com/videos/play/wwdc2022/10024/. CONFIRMED.
- E3. Chinese: WWDC21 10041 says "I don't have support in the Fast path for Chinese. In the Accurate path, I can now pick Chinese". If reading Chinese, "it is important that Chinese is the primary language in the request"; "the first language decides which recognition model gets used". Source: https://developer.apple.com/videos/play/wwdc2021/10041/. CONFIRMED. The exact identifiers on macOS 14 (zh-Hans, zh-Hant) should be read at runtime via `supportedRecognitionLanguages`. Listing them here would be INFERRED.
- E4. Swift `RecognizeTextRequest` and `RecognizedTextObservation` are macOS 15.0+. The observation has `boundingRegion`, `transcript`, `topCandidates(_:)` and `recognitionLanguages`, and conforms to `BoundingBoxProviding` / `QuadrilateralProviding`. Sources: https://developer.apple.com/documentation/vision/recognizetextrequest and https://developer.apple.com/documentation/vision/recognizedtextobservation. CONFIRMED. On a macOS 14 floor, use the VN API, or gate the Swift API with `if #available(macOS 15, *)`. INFERRED.
- E5. VisionKit on macOS. Sources: https://developer.apple.com/documentation/visionkit/imageanalyzer and https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview. CONFIRMED.
  - Classes: `ImageAnalyzer` (macOS 13+) and `ImageAnalysisOverlayView` (macOS 13+, NSView). "For macOS apps, add an ImageAnalysisOverlayView object above the view that contains the image". `ImageAnalysisInteraction` is the iOS path.
  - Overlay API: `text`, `selectedText`, `selectedRanges`, `hasText(at:)` and `analysisHasText(at:)`.
  - Analyzer API: `isSupported` and `supportedTextRecognitionLanguages`.
  - No documented per-line bounding-box accessor on the overlay. INFERRED from the topic list; UNCONFIRMED that none exists elsewhere on ImageAnalysis.
- E6. Both Vision and VisionKit run on device and need no network or entitlement. INFERRED (no entitlement listed on the doc pages). This makes them compatible with ADR-015 as it stands.

---

## Constraints
- Sandbox stays on with no Full Disk Access (AGENTS.md "必须遵守的规则"; ADR-006). Temporary exceptions are rejected for file access (ADR-008).
- The macOS 14 floor rules out several APIs as baseline: `SCScreenshotManager.captureImage(in:)` (15.2), `captureScreenshot` (26), Swift `RecognizeTextRequest` (15). Baseline on 14: `captureImage(contentFilter:configuration:)`, SCContentSharingPicker, VNRecognizeTextRequest, and VisionKit ImageAnalysisOverlayView.
- ADR-015 (accepted 2026-10-28) says `network.client` exists only for Sparkle, and "picsee 的其他代码不发起网络请求，不上传图片或元数据". Cloud OCR (decision 5) contradicts this and needs a new ADR plus user consent wording.
- ADR-007: no overwrite of the source in v1; save-as via save panel with atomic replace for other files.
- ADR-006 / ADR-008: write entitlement arrives in P5-04 and is not present today. Bookmarks were already made without read-only scope.
- ADR-017 renames the app to Mado with a new identity. A helper bundle ID should sit under the new prefix. The App Group prefix rule (B4) applies to Developer ID.
- Rule 10-spec-before-implementation: the Minibar, capture, annotation and OCR are new features and need /grill-with-docs → /to-spec → /to-tickets before any implementation.
- Ledger rows touched: none exist yet for capture/OCR (grep of docs/feature-ledger.md found none). New rows will be needed (CAPTURE-*, OCR-*: names are the planner's call).

## Open questions (default I would choose in brackets)
1. Helper process or main app for the Minibar? [LSUIElement login-item helper. It is the only DTS-confirmed way to float over other apps' full-screen Spaces (B10). Accept a possible second TCC entry and verify on device first.]
2. Region capture on macOS 14 without `captureImage(in:)`? [Display filter + `sourceRect` crop; switch to `captureImage(in:)` behind `#available(macOS 15.2, *)`.]
3. Accept the macOS 15+ periodic "private window picker" alert for region capture, or offer picker-based window/display capture? [Accept it for region capture and explain it in onboarding. Use SCContentSharingPicker for window/display modes.]
4. Who writes the capture file? [The helper writes to ~/Downloads with `files.downloads.read-write`, then calls NSWorkspace.open on Mado. Mado gets the per-file extension; folder browsing needs Mado's own Downloads entitlement or an Access Root.]
5. Should Mado get `files.downloads.read-write` too? [Yes if "captures open with siblings" is required. Otherwise ask the user once to grant ~/Downloads as an Access Root via the existing ADR-008 flow.]
6. Annotation save mode for captures? [Save a copy by default per ADR-007. Overwrite only for files Mado itself created, with a separate ADR.]
7. Cloud OCR vs ADR-015? [Write a new ADR: off by default, explicit per-use or per-setting consent, user-supplied Baidu keys stored in Keychain, and on-device Vision as the default engine.]
8. Baidu account for non-mainland users? [Document that Baidu requires mainland real-name verification. Offer Google/Azure as the next provider.]

## Implications for Mado's decisions
1. **Embedded helper with a FastStone-style Minibar.**
   - Requires:
     - a sandboxed LSUIElement login-item app in Contents/Library/LoginItems, registered via SMAppService (B1);
     - an NSPanel that is non-activating, at `.screenSaver` level, with canJoinAllSpaces + canJoinAllApplications + fullScreenAuxiliary + stationary (B10);
     - its own entitlements (sandbox, downloads read-write, possibly user-selected read-write and bookmarks);
     - signing and notarisation with the app, and a stable identity for TCC (A14).
   - Risks:
     - a separate Screen Recording entry under the helper's name (B3, UNCONFIRMED);
     - the macOS 15+ recurring alert for non-picker capture (A4, A6);
     - hotkey modifier limits on 15.0–15.1 (B9);
     - a login-item approval prompt.
2. **Captures open in Mado.**
   - Requires: NSWorkspace.open from the helper (B5). Mado receives a read/write extension for that single file only.
   - Risks:
     - no sibling browsing without a folder grant (C6);
     - App Group sharing needs the group ID in the profile or with the team prefix (B4);
     - the helper must already have access to the file it hands over (B5).
3. **Annotation editing in Mado.**
   - Requires: `files.user-selected.read-write` (planned P5-04) for save-a-copy.
   - Risks:
     - overwrite conflicts with ADR-007;
     - safe-save into a file held only via a single-file extension can fail (B6), so overwrite needs folder access (C6);
     - ADR-007's save-panel and atomic-replace rules apply to captures as well.
4. **Save to ~/Downloads by default, changeable in Settings.**
   - Requires:
     - `com.apple.security.files.downloads.read-write` on the writing process (C1);
     - for a custom folder, an open-panel grant persisted as an app-scope bookmark. If Mado's Settings chooses it, pass the bookmark data to the helper (B7) and have the helper keep its own bookmark.
   - Risks:
     - two sandbox containers mean two bookmark stores;
     - read-only-era bookmarks may not become writable (ADR-006 P5-04 test).
5. **Cloud OCR, Baidu first.**
   - Requires:
     - a new ADR superseding ADR-015's "no image upload" clause;
     - Keychain storage of API Key/Secret Key and token refresh (30 days, D1);
     - downscaling to ≤4096 px / 8 MB (standard) or ≤8192 px / 10 MB (accurate) (D2, D3);
     - the `general` or `accurate` endpoints if text positions are needed (D4, D5).
   - Risks:
     - mainland real-name verification is required, with only an ID-card path documented (D11);
     - OCR-specific retention is unknown (D12);
     - overseas access is unconfirmed (D13);
     - the free tier has no guaranteed QPS (D10).
   - Mitigation: on-device Vision gives Chinese OCR with boxes on macOS 14 (E1–E4) and is a natural default or fallback.

# WI-2 tests prepared during user-requested heavy-job pause

Created only `Packages/PicseeKit/Tests/PicseeApplicationTests/Issue344LoopSessionTests.swift` (seven test functions). No WI-2 production code or old tests changed; no heavy command, compiler, receipt or test run started.

Cases drive public CommandRouter/session next/previous with real InMemoryDisplayPreferencesStore and existing controlled scanner/host fixture: off/on/off both ends; two shared sessions; incomplete completion transition; empty/singleton no reload; filtered ordered cycles in both directions for sizes2/3/5 and ascending/descending; latest global setting across cancel/restore/new folder; unchanged Preview Set/Finder endpoints for #345 scope.

Static review corrected argument ordering against ViewerSession's public initializer and converted reversed names to Array for concatenation. This is uncompiled, unrun test preparation. A RED receipt is still required after explicit resumption. Suggested receipt filter `issue344SessionLoop`, ID `I344-WI-2`, fingerprint the entire new test file. New tests use existing `setFolderLoopEnabled` API and expect it to update the shared preference; current implementation should fail that behavioral contract.

Before valid RED, any old coordinator tests requiring obsolete removed APIs need the separately documented specification migration. Tests here may be corrected for compilation before recording; once RED is recorded their assertions must remain fixed.

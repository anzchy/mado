/** Exact signatures from the CI failure audits (#424 and #587).
 * Remove each entry when its tracking issue is resolved. A2/A3 were fixed in #379.
 */
export const knownFlaky = [
  {
    name: 'issue140DisplayedFileGrantTrashClearsWithoutReconnectSheet',
    signature: /^Issue140NativeTrashTests\.swift:56:5: Expectation failed: \(window\.attachedSheet → <_NSAlertPanel: 0x[0-9a-f]+>\) == nil$/,
    issue: 520,
    // Same assertion on unrelated main SHAs; PR run 41964260444 passed attempt 2.
  },
  {
    name: 'issue521NativePanPassesInIsolatedProcess',
    signature: /^Issue521NativePanRunner\.swift:(?:110:5: Expectation failed: \(status → 1\) == 0|111:5: Expectation failed: nativePassed|112:5: Expectation failed: nativeRootCompleted)$/,
    issue: 564,
    // Parent runner assertions alone cannot distinguish unrelated child bugs.
    // Successful probes share this prefix; validate every present child lifecycle.
    childPrefix: '[issue521-child] ',
    childTests: [
      { name: 'issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount:)', failed: true,
        cases: ['tabCount → 0', 'tabCount → 1', 'tabCount → 2'],
        metadata: /^↳ native mouse dispatch requires the fixture window to be key$/ },
      { name: 'issue527NonCanvasPressPreservesFocusAndImage(target:)', failed: false,
        cases: ['target → "inspector"', 'target → "sidebar"', 'target → "chromeGap"', 'target → "overlay"'],
        metadata: /^\[issue527-hit\] target=(?:inspector|sidebar|chromeGap|overlay) point=\(.+\) class=.+ id=.* expectedClass=.+ expectedID=.* canvas=(?:true|false) key=(?:true|false)$/ },
      { name: 'issue527InactiveFirstClickKeepsFocusConsistent()', failed: false, cases: [],
        metadata: /^\[issue527-inactive\] phase=(?:before|afterDown|afterUp|activated|afterTab) key=(?:true|false) otherKey=(?:true|false) focus=\S+ responder=.+ id=\S* canvas=(?:true|false)$/ },
      { name: 'issue527InspectorCloseCanvasPressPans()', failed: false, cases: [] },
    ],
    childFailureSignatures: [
      /^✘ Test issue521WindowDragPansFromCanvasAndTabFocusedTools\(tabCount:\) recorded an issue with 1 argument tabCount → 0 at Issue521CanvasToolFocusTests\.swift:79:9: Expectation failed: \(window → <MadoAppTests\.CommandWindow: 0x[0-9a-f]+>\)\.isKeyWindow → false$/,
      /^✘ Test issue521WindowDragPansFromCanvasAndTabFocusedTools\(tabCount:\) with 3 test cases failed after \d+\.\d+ seconds with 1 issue\.$/,
      /^✘ Test run with 1 test in 0 suites failed after \d+\.\d+ seconds with 1 issue\.$/,
    ],
  },
  {
    name: 't231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves',
    signature: /^LostAccessRecoveryTests\.swift:1315:13: Time limit was exceeded: 180\.000 seconds$/,
    issue: 379,
    // TODO(#379 follow-up): fix the remaining A1 overlapping-inactive-moves timeout, then remove.
  },
  {
    name: 'sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild',
    signature: /^SidebarTreeControllerTests\.swift:305:2: Caught error: wait timed out after 100\.0 seconds at MadoAppTests\/SidebarTreeControllerTests\.swift:389 \(sidebar stage: restore A tree\); state: rows=.+$/,
    issue: 425,
    // The A4 180-second test-time-limit variant is not covered.
  },
  {
    name: 't229Fix2RecoveryFollowsRootMovedWhileReadable',
    signature: /^LostAccessRecoveryTests\.swift:459:13: Time limit was exceeded: 180\.000 seconds$/,
    issue: 379,
    // TODO(#379 follow-up): fix the remaining A5 root-moved recovery timeout, then remove.
  },
];

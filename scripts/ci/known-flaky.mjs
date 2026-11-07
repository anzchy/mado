/** Transitional exact signatures from the CI failure audit's A1, A4 and A5 rows.
 * Remove each entry when its tracking issue is resolved. A2/A3 were fixed in #379.
 */
export const knownFlaky = [
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

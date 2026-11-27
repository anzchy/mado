// Stub for #861 WI-1: the release-contents path filter. Signatures only.
export const RELEASE_FILES = [];
export const RELEASE_PREFIXES = [];
export function releaseContent(file) { throw new Error('release-contents: not implemented'); }
export function classifyRelease({ event, changedFiles, pages } = {}) { throw new Error('release-contents: not implemented'); }

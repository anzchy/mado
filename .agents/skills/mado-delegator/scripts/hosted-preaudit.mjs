#!/usr/bin/env node
// #912 hosted App evidence before audit. Compile stub (Stub-For: i912-WI-1): signatures only, no behaviour.
export const EXIT = Object.freeze({ green: 0, red: 1, usage: 2, notCounted: 3 });
export function parseCounts(_log) { return null; }
export function evaluateRun(_run, _head, _options = {}) { return { verdict: '', line: '', exit: -1, fields: {} }; }
export function appFacingPattern(_script) { return /$^/; }
export const isAppFacing = (_files, _pattern) => false;
export function dispatchAndEvaluate(_options) { return { verdict: '', line: '', exit: -1, fields: {} }; }
export function evaluateFiles(_options) { return { verdict: '', line: '', exit: -1, fields: {} }; }
export function main(_argv, _io = {}) { return -1; }

import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runAppRepeat} from './app-repeat.mjs';
import {runAppWorker} from './app-repeat-worker.mjs';
import {runAppCompare} from './app-compare.mjs';

test('removed legacy mode is rejected before native work at each entry point', () => {
  let launched=0;
  const env={APP_COMPARE_MODE:'legacy',APP_COMPARE_SCOPE:'focus',PICSEE_HEAVY_LOCK_HELD:'1'};
  assert.notEqual(runAppRepeat({env,spawn:()=>{launched++;return {status:0};},stdout:()=>{}}),0);
  assert.notEqual(runAppRepeat({env,validateOnly:true,spawn:()=>{launched++;return {status:0};},stdout:()=>{}}),0);
  assert.notEqual(runAppWorker({env,expectedMode:'legacy',spawn:()=>{launched++;return {status:0};},stderr:()=>{}}),0);
  assert.notEqual(runAppCompare({env,spawn:()=>{launched++;return {status:0};},stdout:()=>{}}),0);
  assert.equal(launched,0);
});

test('required CI script tests need no historical object fetch', () => {
  const yaml=readFileSync(new URL('../../.github/workflows/ci.yml',import.meta.url),'utf8');
  const required=yaml.split('  package-tests:')[1].split('  package-macui-tests:')[0];
  assert.match(required,/node --test scripts\/ci\/\*\.test\.mjs/);
  assert.doesNotMatch(required,/git fetch|c5a087f5949e0f087b96f19d0f4c58a8310a8960/);
});

test('removed dispatch inputs and one-shot job are unavailable', () => {
  const yaml=readFileSync(new URL('../../.github/workflows/ci.yml',import.meta.url),'utf8');
  assert.match(yaml,/options: \[none, hosted\]/);
  assert.doesNotMatch(yaml,/hosted_focus_only:|native_red_receipt:|hosted-focus-diagnostic:/);
  assert.match(yaml,/inputs\.app_compare_mode == 'hosted'/);
  assert.match(yaml,/run: node scripts\/ci\/hosted-build\.mjs/);
});

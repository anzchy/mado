import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const rawCatalog = readFileSync(new URL('../../App/Resources/Localizable.xcstrings', import.meta.url), 'utf8');
const catalog = JSON.parse(rawCatalog);
const entries = Object.entries(catalog.strings);

test('issue 882 uses one British Recognise Text key and consistent Cloud Recognition copy', () => {
  assert.ok(catalog.strings['Recognise Text']);
  assert.ok(!catalog.strings['Recognize Text']);
  assert.equal((rawCatalog.match(/^    "Recognise Text":/gm) ?? []).length, 1);
  for (const [key, entry] of entries) {
    const english = `${key} ${entry.localizations?.en?.stringUnit?.value ?? ''}`;
    assert.doesNotMatch(english, /recognize|recognized|authorize/i, key);
    const chinese = entry.localizations?.['zh-Hans']?.stringUnit?.value ?? '';
    assert.doesNotMatch(chinese, /云端识别|云端服务/, key);
  }
  assert.equal(catalog.strings['Allow Cloud Recognition (Recognise Text, Recognise Table)'].localizations['zh-Hans'].stringUnit.value,
    '允许云识别（识别文字、识别表格）');
});

test('issue 882 state page has current app and display copy', () => {
  const page = readFileSync(new URL('../../design/prototypes/picsee-browser/states/settings.html', import.meta.url), 'utf8');
  const visibleCopy = page.replace(/data-stitch-inlined="[^"]*"/g, '');
  assert.doesNotMatch(visibleCopy, /pic\s*see|（15）|不上传图片/i);
  for (const token of ['globals', 'light', 'dark']) {
    assert.match(page, new RegExp(`data-stitch-inlined="_ds/picsee-ui-system/tokens/${token}\\.css"`));
  }
  assert.match(page, /与网格底栏的「显示」设置同步，任一处修改立即生效。/);
});

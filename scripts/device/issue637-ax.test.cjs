const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'issue637-ax.js'), 'utf8');

function fixture({ sliderStuck = false, directAssignmentIgnored = false, wrongLabel = false,
                   renameOnPress = false, invalidateOnSliderSet = false,
                   throwAfterPress = false, staleReadAfterStep = false } = {}) {
  let windowName = 'Display';
  let generation = 0;
  let staleNextRead = false;
  const values = new Map([
    ['settings.section.general', 0],
    ['settings.section.display', 1],
    ['settings.display.tool-opacity', 50],
  ]);
  const element = (id) => {
    const boundGeneration = generation;
    return new Proxy({
    attributes: { byName(name) {
      assert.equal(name, 'AXIdentifier');
      return { value: () => id };
    } },
    actions: { byName(name) {
      assert.ok(['AXPress', 'AXIncrement', 'AXDecrement'].includes(name));
      return { exists: () => true, perform: () => {
        if (name !== 'AXPress') {
          if (!sliderStuck) values.set(id, values.get(id) + (name === 'AXIncrement' ? 1 : -1));
          if (staleReadAfterStep) staleNextRead = true;
          return;
        }
        values.set(id, values.get(id) ? 0 : 1);
        if (renameOnPress && id === 'settings.section.general') {
          windowName = 'General';
          generation += 1;
        }
        if (throwAfterPress) throw Error("Can't get object (-1728)");
      } };
    } },
  }, {
    get(target, key) {
      if (key === 'value') return () => {
        if (staleNextRead && id === 'settings.display.tool-opacity') {
          staleNextRead = false;
          throw Error("Can't get object (-1728)");
        }
        if (boundGeneration !== generation) throw Error("Can't get object (-1728)");
        if (id === 'settings.display.tool-opacity.value') {
          return wrongLabel ? '50%' : values.get('settings.display.tool-opacity') + '%';
        }
        return values.get(id);
      };
      return target[key];
    },
    set(_target, key, value) {
      if (key === 'value' && !sliderStuck && !directAssignmentIgnored) {
        values.set(id, value);
        if (invalidateOnSliderSet) generation += 1;
      }
      return true;
    },
  });
  };
  const settings = {
    name: () => windowName, size: () => [760, 514],
    entireContents: () => [...values.keys(), 'settings.display.tool-opacity.value'].map(element),
  };
  const viewer = {
    name: () => 'Mado', size: () => [960, 640],
    entireContents: () => { throw Error('viewer tree must not be traversed'); },
  };
  const process = {
    exists: () => true,
    windows: Object.assign(() => [settings, viewer], { byName: (name) => {
      assert.equal(name, windowName);
      return settings;
    } }),
    frontmost: false,
  };
  const se = { processes: { whose: ({ unixId }) => {
    assert.equal(unixId, 123);
    return [process];
  } } };
  const context = { Application: () => se, delay: () => {} };
  vm.runInNewContext(source, context, { filename: 'issue637-ax.js' });
  return { run: (operation, id, value) => context.run(
    ['123', operation, id, ...(value === undefined ? [] : [String(value)])]),
    values };
}

test('JXA finds Settings identifiers without traversing the viewer window', () => {
  const ax = fixture();
  assert.match(ax.run('settings-window', 'window'), /Display 760x514/);
  assert.equal(ax.run('value', 'settings.section.general'), '0');
  assert.equal(ax.run('window-list', 'window'), 'Display 760x514; Mado 960x640');
});

test('JXA AXPress changes the Settings sidebar checkbox', () => {
  const ax = fixture();
  assert.equal(ax.run('press', 'settings.section.general'), 'PASS press settings.section.general=1');
  assert.equal(ax.values.get('settings.section.general'), 1);
});

test('JXA re-resolves the checkbox after its press renames Settings', () => {
  const ax = fixture({ renameOnPress: true });
  assert.equal(ax.run('press', 'settings.section.general'), 'PASS press settings.section.general=1');
  assert.equal(ax.run('window-list', 'window'), 'General 760x514; Mado 960x640');
});

test('JXA accepts a completed press even if the old action specifier errors on rename', () => {
  const ax = fixture({ renameOnPress: true, throwAfterPress: true });
  assert.equal(ax.run('press', 'settings.section.general'), 'PASS press settings.section.general=1');
});

test('JXA sets slider value and verifies readback', () => {
  const ax = fixture();
  assert.equal(ax.run('set-slider', 'settings.display.tool-opacity', 30),
    'PASS slider settings.display.tool-opacity=30');
  assert.equal(ax.values.get('settings.display.tool-opacity'), 30);
  const stuck = fixture({ sliderStuck: true });
  assert.throws(() => stuck.run('set-slider', 'settings.display.tool-opacity', 30),
    /no progress|did not reach/);
  const rebuilt = fixture({ invalidateOnSliderSet: true });
  assert.equal(rebuilt.run('set-slider', 'settings.display.tool-opacity', 30),
    'PASS slider settings.display.tool-opacity=30');
});

test('JXA steps a slider when direct assignment is ignored, then checks the label', () => {
  const ax = fixture({ directAssignmentIgnored: true });
  assert.equal(ax.run('set-slider', 'settings.display.tool-opacity', 30),
    'PASS slider settings.display.tool-opacity=30');
  assert.equal(ax.values.get('settings.display.tool-opacity'), 30);
  const badLabel = fixture({ directAssignmentIgnored: true, wrongLabel: true });
  assert.throws(() => badLabel.run('set-slider', 'settings.display.tool-opacity', 30),
    /opacity label did not reach 30/);
});

test('JXA re-resolves after transient stale slider read during a long step sequence', () => {
  const ax = fixture({ directAssignmentIgnored: true, staleReadAfterStep: true });
  assert.equal(ax.run('set-slider', 'settings.display.tool-opacity', 30),
    'PASS slider settings.display.tool-opacity=30');
});

test('JXA missing identifier names the scoped Settings window', () => {
  const ax = fixture();
  assert.throws(() => ax.run('value', 'settings.missing'),
    /AXIdentifier not found in Settings window: settings.missing; window=Display 760x514/);
});

// PID-bound, window-scoped JXA for the #637 desktop harness.
// The desktop AX dump established that System Events JXA exposes these identifiers.
function run(argv) {
    if (argv.length < 3) throw Error('usage: PID press|value|set-slider|settings-window|window-list|window-title IDENTIFIER [NUMBER]');
    var pid = Number(argv[0]), operation = String(argv[1]), identifier = String(argv[2]);
    if (!Number.isInteger(pid) || pid <= 1) throw Error('invalid PID');
    var se = Application('System Events');
    var matches = se.processes.whose({unixId: pid});
    var proc = matches[0];
    if (!proc || !proc.exists()) throw Error('AX process not found for PID ' + pid);
    proc.frontmost = true;

    function windows() { return proc.windows(); }
    function description(w) {
        try { return String(w.name()) + ' ' + w.size().join('x'); }
        catch (_error) { return '<unreadable window>'; }
    }
    function windowList() { return windows().map(description).join('; '); }
    function settingsWindow() {
        var candidates = windows().filter(function (w) {
            try {
                var size = w.size();
                return size[0] >= 730 && size[0] <= 790 && size[1] >= 460 && size[1] <= 550;
            } catch (_error) { return false; }
        });
        if (candidates.length !== 1) {
            throw Error('Settings window not uniquely present; windows=[' + windowList() + ']');
        }
        return candidates[0];
    }
    if (operation === 'window-list') return windowList();
    if (operation === 'window-title') {
        var all = windows();
        if (!all.length) throw Error('viewer window absent');
        return String(all[0].name());
    }
    var window = settingsWindow();
    if (operation === 'settings-window') return 'PASS settings-window ' + description(window);
    var allElements = window.entireContents();
    var element = null;
    for (var i = 0; i < allElements.length; i++) {
        try {
            if (allElements[i].attributes.byName('AXIdentifier').value() === identifier) {
                element = allElements[i];
                break;
            }
        } catch (_error) {}
    }
    if (!element) throw Error('AXIdentifier not found in Settings window: ' + identifier +
                             '; window=' + description(window));
    if (operation === 'value') return String(element.value());
    if (operation === 'press') {
        var before = String(element.value());
        var action = element.actions.byName('AXPress');
        if (!action.exists()) throw Error('AXPress unavailable: ' + identifier);
        try { action.perform(); }
        catch (_error) { se.perform(action); }
        delay(0.15);
        var after = String(element.value());
        if (after === before && before !== '1' && before !== 'true') {
            throw Error('AXPress made no progress: ' + identifier + ' value=' + after);
        }
        return 'PASS press ' + identifier + '=' + after;
    }
    if (operation === 'set-slider') {
        if (argv.length !== 4) throw Error('set-slider requires a number');
        var desired = Number(argv[3]);
        if (!Number.isInteger(desired) || desired < 30 || desired > 100) {
            throw Error('opacity outside 30...100');
        }
        element.value = desired;
        delay(0.6);
        var current = Number(element.value());
        if (current !== desired) throw Error('slider did not reach ' + desired + ': ' + current);
        return 'PASS slider ' + identifier + '=' + current;
    }
    throw Error('unknown operation: ' + operation);
}

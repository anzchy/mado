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
        // The working desktop helper used a window-by-name specifier for
        // writable AXSlider.value, rather than the index-bound list element.
        return proc.windows.byName(String(candidates[0].name()));
    }
    if (operation === 'window-list') return windowList();
    if (operation === 'window-title') {
        var all = windows();
        if (!all.length) throw Error('viewer window absent');
        return String(all[0].name());
    }
    if (operation === 'settings-window') return 'PASS settings-window ' + description(settingsWindow());
    function findElement(targetIdentifier) {
        // A sidebar press renames Settings (Display -> General), invalidating
        // every element specifier captured from the old window name.
        var window = settingsWindow();
        var allElements = window.entireContents();
        for (var i = 0; i < allElements.length; i++) {
            try {
                if (allElements[i].attributes.byName('AXIdentifier').value() === targetIdentifier) {
                    return allElements[i];
                }
            } catch (_error) {}
        }
        throw Error('AXIdentifier not found in Settings window: ' + targetIdentifier +
                    '; window=' + description(window));
    }
    var element = findElement(identifier);
    if (operation === 'value') return String(element.value());
    if (operation === 'press') {
        var before = String(element.value());
        var action = element.actions.byName('AXPress');
        if (!action.exists()) throw Error('AXPress unavailable: ' + identifier);
        var pressError = null;
        try { action.perform(); }
        catch (error) { pressError = error; }
        delay(0.15);
        var after = String(findElement(identifier).value());
        if (pressError && after === before) throw pressError;
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
        var assignmentError = null;
        try { element.value = desired; }
        catch (error) { assignmentError = error; }
        delay(0.6);
        var current = Number(findElement(identifier).value());
        if (!Number.isFinite(current)) throw Error('slider has nonnumeric value: ' + current);
        for (var step = 0; current !== desired && step < 71; step++) {
            var direction = current < desired ? 'AXIncrement' : 'AXDecrement';
            var action = findElement(identifier).actions.byName(direction);
            if (!action.exists()) throw Error(direction + ' unavailable: ' + identifier);
            var actionError = null;
            try { action.perform(); }
            catch (error) { actionError = error; }
            delay(0.1);
            var next = Number(findElement(identifier).value());
            if (next === current) {
                delay(0.2);
                next = Number(findElement(identifier).value());
            }
            if (!Number.isFinite(next) || next === current) {
                if (actionError) throw actionError;
                throw Error(direction + ' made no progress at ' + current);
            }
            if ((current < desired && next > desired) || (current > desired && next < desired)) {
                throw Error(direction + ' overshot ' + desired + ': ' + next);
            }
            current = next;
        }
        if (current !== desired) throw Error('slider did not reach ' + desired + ': ' + current +
                                             (assignmentError ? ' assignment=' + assignmentError : ''));
        delay(0.6);
        current = Number(findElement(identifier).value());
        var label = String(findElement('settings.display.tool-opacity.value').value());
        var percentage = label.match(/([0-9]{2,3})\s*%/);
        if (current !== desired) throw Error('slider did not settle at ' + desired + ': ' + current);
        if (!percentage || Number(percentage[1]) !== desired) {
            throw Error('opacity label did not reach ' + desired + ': ' + label);
        }
        return 'PASS slider ' + identifier + '=' + current;
    }
    throw Error('unknown operation: ' + operation);
}

// osascript -l JavaScript issue637-drive.js PID X Y W H ITERATIONS
// Synthetic keyboard zoom and mouse pan, addressed to the newly launched Mado PID.
// This is a device-only driver: the caller has acquired the shared desktop GUI lock.
ObjC.import('CoreGraphics');
ObjC.import('Foundation');

function run(argv) {
  var pid = Number(argv[0]), x = Number(argv[1]), y = Number(argv[2]);
  var width = Number(argv[3]), height = Number(argv[4]), iterations = Number(argv[5]);
  if (!(pid > 1 && width > 400 && height > 300 && iterations >= 30)) throw Error('invalid driver input');
  var app = Application('System Events');
  var process = app.processes.whose({ unixId: pid })[0];
  if (!process || !process.exists()) throw Error('target PID is not an Accessibility process');
  process.frontmost = true;
  var centreX = x + width / 2, centreY = y + height / 2 + 8;
  function post(type, px, py) {
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, type, { x: px, y: py }, 0));
  }
  function key(code) {
    var down = $.CGEventCreateKeyboardEvent(null, code, true);
    var up = $.CGEventCreateKeyboardEvent(null, code, false);
    $.CGEventSetFlags(down, $.kCGEventFlagMaskCommand);
    $.CGEventSetFlags(up, $.kCGEventFlagMaskCommand);
    $.CGEventPost($.kCGHIDEventTap, down);
    $.CGEventPost($.kCGHIDEventTap, up);
  }
  // Zoom in first so the 48 MP image is larger than the viewport and pan is meaningful.
  for (var z = 0; z < 5; z++) { key(24); $.NSThread.sleepForTimeInterval(0.08); }
  var sent = 0;
  for (var i = 0; i < iterations; i++) {
    key(i % 2 === 0 ? 24 : 27);
    var dx = i % 2 === 0 ? 28 : -28;
    post($.kCGEventLeftMouseDown, centreX, centreY);
    $.NSThread.sleepForTimeInterval(0.02);
    for (var s = 1; s <= 4; s++) {
      post($.kCGEventLeftMouseDragged, centreX + dx * s / 4, centreY + s);
      $.NSThread.sleepForTimeInterval(0.02);
    }
    post($.kCGEventLeftMouseUp, centreX + dx, centreY + 4);
    $.NSThread.sleepForTimeInterval(0.08);
    sent += 1;
  }
  return 'sent=' + sent;
}

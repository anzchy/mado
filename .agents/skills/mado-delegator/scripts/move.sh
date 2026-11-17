#!/bin/zsh
# move.sh X Y — post a synthetic mouseMoved to screen point (top-left origin). Disclosed substitute for a real pointer.
osascript -l JavaScript - "$1" "$2" <<'JXA'
ObjC.import('CoreGraphics');
function run(a){ var e=$.CGEventCreateMouseEvent(null, 5, {x:+a[0], y:+a[1]}, 0); $.CGEventPost(0, e); return 'moved '+a[0]+','+a[1]; }
JXA

#!/bin/zsh
# click.sh X Y — synthetic left click (down/up) at a screen point. Disclosed substitute for a real click.
osascript -l JavaScript - "$1" "$2" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
function run(a){ var p={x:+a[0],y:+a[1]};
 $.CGEventPost(0,$.CGEventCreateMouseEvent(null,5,p,0)); $.NSThread.sleepForTimeInterval(0.05);
 $.CGEventPost(0,$.CGEventCreateMouseEvent(null,1,p,0)); $.NSThread.sleepForTimeInterval(0.06);
 $.CGEventPost(0,$.CGEventCreateMouseEvent(null,2,p,0)); return 'clicked'; }
JXA

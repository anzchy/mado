#!/bin/zsh
# drag2.sh X0 Y0 X1 Y1 — CGEvent left-drag with a press-hold and slow path (screen points). Substitute for a real drag.
osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
function run(a){ var x0=+a[0],y0=+a[1],x1=+a[2],y1=+a[3],n=60;
 function post(t,x,y){ $.CGEventPost(0,$.CGEventCreateMouseEvent(null,t,{x:x,y:y},0)); }
 post(5,x0,y0); $.NSThread.sleepForTimeInterval(0.2);
 post(1,x0,y0); $.NSThread.sleepForTimeInterval(0.4);
 for (var i=1;i<=6;i++){ post(6,x0+i*2,y0+i); $.NSThread.sleepForTimeInterval(0.05); }
 for (var i=1;i<=n;i++){ post(6,x0+(x1-x0)*i/n,y0+(y1-y0)*i/n); $.NSThread.sleepForTimeInterval(0.03); }
 $.NSThread.sleepForTimeInterval(0.6); post(6,x1,y1); $.NSThread.sleepForTimeInterval(0.3);
 post(2,x1,y1); return 'dragged'; }
JXA

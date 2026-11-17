#!/bin/zsh
# menus.sh PID — print every top-level menu with item:enabled
osascript - "$1" <<'OSA'
on run argv
  set p to (item 1 of argv) as integer
  tell application "System Events" to tell (first process whose unix id is p)
    set out to ""
    repeat with mb in (menu bar items of menu bar 1)
      set nm to name of mb
      if nm is not "Apple" then
        set out to out & "[" & nm & "] "
        try
          repeat with mi in (menu items of menu 1 of mb)
            set t to name of mi
            if t is not missing value then set out to out & t & ":" & (enabled of mi as text) & ", "
          end repeat
        end try
        set out to out & linefeed
      end if
    end repeat
    return out
  end tell
end run
OSA

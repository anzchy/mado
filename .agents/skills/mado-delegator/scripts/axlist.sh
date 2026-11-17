#!/bin/zsh
# axlist.sh PID — one line per AX element of window 1: role|subrole|description/title|value
osascript <<OSA
tell application "System Events" to tell (first process whose unix id is $1)
  set lst to entire contents of window 1
  set out to ""
  repeat with e in lst
    try
      set r to value of attribute "AXRole" of e
      set sr to ""
      try
        set sr to value of attribute "AXSubrole" of e
      end try
      set d to ""
      try
        set d to description of e
      end try
      set v to ""
      try
        set v to (value of e) as text
      end try
      if r is in {"AXButton", "AXStaticText", "AXImage", "AXCheckBox"} then set out to out & r & "|" & sr & "|" & d & "|" & v & linefeed
    end try
  end repeat
  return out
end tell
OSA

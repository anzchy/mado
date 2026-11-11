-- PID-bound Accessibility actions for issue637-desktop.py. No UI element is chosen by screen coordinate.
on findElement(proc, identifier)
    tell application "System Events"
        repeat with elementRef in (entire contents of proc)
            try
                if (value of attribute "AXIdentifier" of elementRef as text) is identifier then return elementRef
            end try
        end repeat
    end tell
    error "AXIdentifier not found: " & identifier
end findElement

on run argv
    if (count of argv) < 3 then error "usage: PID press|value|set-slider IDENTIFIER [NUMBER]"
    set targetPID to item 1 of argv as integer
    set operation to item 2 of argv as text
    set identifier to item 3 of argv as text
    tell application "System Events"
        set proc to first application process whose unix id is targetPID
        set frontmost of proc to true
        if operation is "window-title" then return name of window 1 of proc
        set targetElement to my findElement(proc, identifier)
        if operation is "press" then
            perform action "AXPress" of targetElement
            return "PASS press " & identifier
        else if operation is "value" then
            return value of targetElement as text
        else if operation is "set-slider" then
            if (count of argv) is not 4 then error "set-slider requires a number"
            set desired to item 4 of argv as integer
            set current to value of targetElement as integer
            if desired < 30 or desired > 100 then error "opacity outside 30...100"
            set steps to 0
            repeat while current is less than desired
                perform action "AXIncrement" of targetElement
                set current to value of targetElement as integer
                set steps to steps + 1
                if steps > 71 then error "slider increment made no progress"
            end repeat
            repeat while current is greater than desired
                perform action "AXDecrement" of targetElement
                set current to value of targetElement as integer
                set steps to steps + 1
                if steps > 71 then error "slider decrement made no progress"
            end repeat
            if current is not desired then error "slider did not reach requested value"
            return "PASS slider " & identifier & "=" & current
        else
            error "unknown operation"
        end if
    end tell
end run

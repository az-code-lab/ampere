#!/bin/bash
# Sourced by run.sh and release.sh:
#
#     swift build ... 2>&1 | build_progress
#
# Shows SwiftPM's build progress while a build runs and leaves none of it
# on screen afterwards.
#
# The Swift Build engine (SwiftPM's default since Xcode 27) prints lines
# such as "[108 / 109] Ampere-product". They are not done over total: the
# first number is the tasks started, the second the tasks run so far plus
# those still being checked, and it moves in both directions as the build
# goes. The engine sends at most one update every 100 ms and never sends
# the final state again, so a build whose last steps (signing the binary)
# finish inside that window ends on a count short of its own total, with
# "Build complete!" under it. What stays on screen is then a snapshot from
# just before the end, not a result. Measured on Swift 6.4.2: ten identical
# rebuilds ended on "37 / 38" nine times and on "38 / 38" once.
#
# So the progress lines are drawn in place on a terminal and cleared as
# soon as anything else is printed and when the build ends. What remains is
# SwiftPM's own verdict ("Build complete!" or its errors) and its
# diagnostics, which pass through untouched, colors included. Where the
# output is not a terminal (a pipe, a log file) the progress lines are left
# out. Give it build output only: a line a test prints could have the same
# shape as a progress line.
build_progress() {
    # A whole line of the form "[message]" or "[message] target".
    local progress='^\[[^][]*\]( [A-Za-z0-9_.+-]+)?$'
    local line shown=0 columns=0
    if [ -t 1 ]; then
        # The terminal's width ("rows columns"). stty reads it from its
        # input, and inside $( ) the output is the capture, so the terminal
        # is handed over as descriptor 3.
        { columns=$(stty size <&3 2>/dev/null) || columns=; } 3>&1
        columns=${columns##* }
        [[ $columns =~ ^[1-9][0-9]*$ ]] || columns=80
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $progress ]]; then
            if [ "$columns" -gt 0 ]; then
                # The engine pads its slash with thin spaces (U+2009): plain
                # ones here, so the cut below counts the same in any locale.
                line=${line//$'\xe2\x80\x89'/ }
                # One row at most: a line that wrapped could not be cleared.
                printf '\r\033[2K%s' "${line:0:$((columns - 1))}"
                shown=1
            fi
            continue
        fi
        if [ "$shown" = 1 ]; then
            printf '\r\033[2K'
            shown=0
        fi
        printf '%s\n' "$line"
    done
    if [ "$shown" = 1 ]; then
        printf '\r\033[2K'
    fi
}

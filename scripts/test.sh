#!/bin/sh
# Runs the unit tests. With only the Command Line Tools installed, the Swift
# Testing framework is present but not on the default search paths, so we add
# them here. With full Xcode selected (xcode-select), plain `swift test` works.
set -e
DEV="$(xcode-select -p)"
case "$DEV" in
  *CommandLineTools*)
    F="$DEV/Library/Developer/Frameworks"
    L="$DEV/Library/Developer/usr/lib"
    exec swift test -Xswiftc -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
    ;;
  *) exec swift test "$@" ;;
esac

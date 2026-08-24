#!/bin/bash
# Restart SwiftBar so its retained menu images are released.
#
# SwiftBar 2.0.1 never frees the bitmaps a plugin hands it -- every refresh's
# images are held for the life of the process. At a 60s cadence that pile grows
# until WindowServer's compositing cost climbs and the whole display starts to
# stutter: measured, WindowServer CPU rose from 48% to 68% over 360 refreshes
# with these images present and stayed flat when they were removed. Quitting
# SwiftBar drops the pile at once, which is the only lever we have from outside
# the app. Run every 4 hours by io.claude-usage.swiftbar-restart, which keeps the
# pile under ~2.5MB.
#
# The plugin's own images are palette-quantized (see png_quantize in
# claude-usage.60s.sh), which halves what accumulates between restarts; this
# script bounds it.

# A SwiftBar that is not running was quit deliberately -- leave it alone rather
# than resurrecting it on a timer.
pgrep -qx SwiftBar || exit 0

osascript -e 'quit app "SwiftBar"' >/dev/null 2>&1

# Wait for the process to actually go away before relaunching; a relaunch that
# races the quit leaves no SwiftBar at all.
for _ in $(seq 1 20); do
  pgrep -qx SwiftBar || break
  sleep 0.5
done
pkill -x SwiftBar 2>/dev/null    # only reached if the graceful quit hung
sleep 1

# -g keeps focus where it is: this fires on a timer, in the middle of whatever
# the user is doing.
open -g -a SwiftBar

#!/bin/bash
# Tells any running Chromium-based browser to reload only the exact pages the
# extension scrapes — the Claude usage settings page and the API cost page.
# We re-set the tab's URL to itself rather than calling `reload`, because
# some browsers (notably Dia) don't expose a reload command on tabs but do
# accept URL assignment, which triggers the same effect.
#
# After firing the reload, we poll the local server for a fresh updatedAt
# timestamp so SwiftBar re-renders as soon as new data arrives.

# Tabs we will reload. Match on prefix so query strings / trailing slashes
# don't break the check, but reject unrelated claude.ai pages (chats, etc.)
# so we don't reload work the user has open.
USAGE_URL="https://claude.ai/settings/usage"
COST_URL="https://platform.claude.com/workspaces/default/cost"

reload_in() {
  local app="$1"
  /usr/bin/osascript 2>/dev/null <<APPLESCRIPT
    tell application "System Events"
      if not (exists process "$app") then return
    end tell
    tell application "$app"
      repeat with w in windows
        repeat with t in tabs of w
          try
            set u to URL of t
            if (u starts with "$USAGE_URL") or (u starts with "$COST_URL") then
              set URL of t to u
            end if
          end try
        end repeat
      end repeat
    end tell
APPLESCRIPT
}

NOW_MS=$(($(date +%s) * 1000))

reload_in "Google Chrome"
reload_in "Dia"
reload_in "Arc"
reload_in "Brave Browser"

# Poll up to ~4 s for fresh data, then exit.
for _ in 1 2 3 4 5 6 7 8; do
  sleep 0.5
  TS=$(curl -fsS --max-time 1 http://localhost:7823/usage 2>/dev/null \
    | python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(d.get('updatedAt', 0))" 2>/dev/null)
  [ -n "$TS" ] && [ "$TS" -gt "$NOW_MS" ] && exit 0
done
exit 0

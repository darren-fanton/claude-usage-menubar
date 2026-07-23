#!/bin/bash
# Tells any running Chromium-based browser to reload only the exact pages the
# extension scrapes — the Claude usage settings page and the API cost page.
# We re-set the tab's URL to itself rather than calling `reload`, because
# some browsers (notably Dia) don't expose a reload command on tabs but do
# accept URL assignment, which triggers the same effect.
#
# After firing the reload, we poll the local server for a fresh updatedAt
# timestamp so SwiftBar re-renders as soon as new data arrives.

# Which page group to reload, passed by the menu:
#   usage   -> just the Claude.ai session/weekly page
#   apicost -> the three provider billing pages
#   (empty) -> everything (used by the 60s LaunchAgent)
GROUP="${1:-all}"

# Tabs we may reload. Match on prefix so query strings / trailing slashes
# don't break the check, but reject unrelated pages so we don't reload work
# the user has open.
USAGE_URL="https://claude.ai/settings/usage"
CLAUDE_BILLING_URL="https://platform.claude.com/settings/billing"
OPENAI_URL="https://platform.openai.com/settings/proj_vxOhdwuqhmqTXXVDefWUzMRY/limits"
GOOGLE_URL="https://aistudio.google.com/u/2/spend?project=gen-lang-client-0546438527"

# Build the list of URL prefixes to match for this group.
PREFIXES=()
case "$GROUP" in
  usage)   PREFIXES=("$USAGE_URL") ;;
  apicost) PREFIXES=("$CLAUDE_BILLING_URL" "$OPENAI_URL" "$GOOGLE_URL") ;;
  *)       PREFIXES=("$USAGE_URL" "$CLAUDE_BILLING_URL" "$OPENAI_URL" "$GOOGLE_URL") ;;
esac

# AppleScript `if` condition testing the tab URL against every prefix.
COND=""
for p in "${PREFIXES[@]}"; do
  # Compare only the scheme+host+path, ignoring query strings, so the
  # Google URL (which carries a ?project=... query) still matches.
  base="${p%%\?*}"
  [ -n "$COND" ] && COND="$COND or "
  COND="$COND(u starts with \"$base\")"
done

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
            if $COND then
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

# Poll up to ~4 s for fresh data, then exit as soon as anything new arrives.
for _ in 1 2 3 4 5 6 7 8; do
  sleep 0.5
  TS=$(curl -fsS --max-time 1 http://localhost:7823/usage 2>/dev/null \
    | python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(d.get('updatedAt', 0))" 2>/dev/null)
  [ -n "$TS" ] && [ "$TS" -gt "$NOW_MS" ] && exit 0
done
exit 0

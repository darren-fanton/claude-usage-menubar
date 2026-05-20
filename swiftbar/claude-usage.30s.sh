#!/bin/bash
# <xbar.title>Claude Usage</xbar.title>
# <xbar.version>v1.2</xbar.version>
# <xbar.author>local</xbar.author>
# <xbar.desc>Shows Claude.ai session and weekly usage limits.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

# SwiftBar runs plugins with a minimal PATH; add Homebrew so `magick`, `jq`,
# and other tools installed via brew are discoverable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ENDPOINT="http://localhost:7823/usage"

JSON=$(curl -fsS --max-time 2 "$ENDPOINT" 2>/dev/null)

parse() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$JSON" | jq -r "$path // empty" 2>/dev/null
  else
    echo "$JSON" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read() or '{}')
    p = '$path'.strip().lstrip('.')
    cur = d
    for part in [x for x in p.split('.') if x]:
        cur = cur.get(part) if isinstance(cur, dict) else None
        if cur is None: break
    print('' if cur is None else cur)
except Exception:
    print('')
" 2>/dev/null
  fi
}

SESSION_PCT=$(parse '.session.pct')
SESSION_RESET=$(parse '.session.reset')
WEEKLY_ALL_PCT=$(parse '.weekly.allModels.pct')
WEEKLY_ALL_RESET=$(parse '.weekly.allModels.reset')
WEEKLY_SONNET_PCT=$(parse '.weekly.sonnet.pct')
WEEKLY_SONNET_RESET=$(parse '.weekly.sonnet.reset')
WEEKLY_DESIGN_PCT=$(parse '.weekly.design.pct')
WEEKLY_DESIGN_RESET=$(parse '.weekly.design.reset')
WEEKLY_OPUS_PCT=$(parse '.weekly.opus.pct')
WEEKLY_OPUS_RESET=$(parse '.weekly.opus.reset')
COST_TOTAL=$(parse '.cost.totalUSD')
COST_OPUS=$(parse '.cost.perModel.opus')
COST_SONNET=$(parse '.cost.perModel.sonnet')
COST_HAIKU=$(parse '.cost.perModel.haiku')
UPDATED_AT=$(parse '.updatedAt')

# Format a number as $XX.XX (or "-" if empty).
fmt_usd() {
  local n="$1"
  [ -z "$n" ] && { echo "-"; return; }
  awk -v n="$n" 'BEGIN { printf "$%.2f", n }'
}

# --- Time-elapsed calculation for the pie chart ---
# Claude sessions are 5-hour rolling windows, so 300 minutes total.
SESSION_TOTAL_MIN=300

# Parse "Resets in 1 hr 45 min" / "Resets in 45 min" / "Resets in 2 hr" -> minutes.
parse_remaining_min() {
  local s="$1"
  local hr min
  hr=$(echo "$s" | grep -oE '[0-9]+ hr' | head -1 | grep -oE '[0-9]+')
  min=$(echo "$s" | grep -oE '[0-9]+ min' | head -1 | grep -oE '[0-9]+')
  hr=${hr:-0}
  min=${min:-0}
  echo $((hr * 60 + min))
}

PIE_PCT=""
SESSION_RESET_AT=""
if [ -n "$SESSION_RESET" ]; then
  REMAINING=$(parse_remaining_min "$SESSION_RESET")
  if [ "$REMAINING" -gt 0 ] 2>/dev/null; then
    PIE_PCT=$(( (SESSION_TOTAL_MIN - REMAINING) * 100 / SESSION_TOTAL_MIN ))
    [ "$PIE_PCT" -lt 0 ]   && PIE_PCT=0
    [ "$PIE_PCT" -gt 100 ] && PIE_PCT=100
    # Build "Resets at H:MM AM/PM" anchored to when the data was scraped,
    # so the time stays correct regardless of when SwiftBar reads it.
    if [ -n "$UPDATED_AT" ]; then
      RESET_EPOCH=$(( UPDATED_AT/1000 + REMAINING*60 ))
      RESET_TIME=$(date -r "$RESET_EPOCH" +"%-I:%M %p" 2>/dev/null)
      [ -n "$RESET_TIME" ] && SESSION_RESET_AT="Resets at ${RESET_TIME}"
    fi
  fi
fi

# Render the pie chart from SVG (vector) and downsample to 11x11 with
# high-quality anti-aliasing. Rasterizing at high resolution first and then
# resizing produces much cleaner edges than rasterizing directly at 11x11.
generate_pie_b64() {
  # $1 is the percent of session time CONSUMED. The pie shows time REMAINING:
  # full circle at session start, empties clockwise as time passes, ends as
  # an empty ring. Outline always visible; inner pie sits inside it with a gap.
  #
  # Output is a vector PDF (via rsvg-convert) with a 16.5x16.5 pt MediaBox.
  # NSImage rasterizes PDF natively at full retina resolution -- the same
  # technique macOS apps like Focus use for crisp menu bar icons.
  local pct=$1 svg
  if [ "$pct" -le 0 ]; then
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="42" fill="none" stroke="black" stroke-width="6"/>
      <circle cx="50" cy="50" r="30" fill="black"/>
    </svg>'
  elif [ "$pct" -ge 100 ]; then
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="42" fill="none" stroke="black" stroke-width="6"/>
    </svg>'
  else
    local bx by large
    bx=$(awk -v p="$pct" 'BEGIN { printf "%.3f", 50 + sin(p/100 * 6.2831853) * 30 }')
    by=$(awk -v p="$pct" 'BEGIN { printf "%.3f", 50 - cos(p/100 * 6.2831853) * 30 }')
    [ "$pct" -lt 50 ] && large=1 || large=0
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="42" fill="none" stroke="black" stroke-width="6"/>
      <path d="M '$bx','$by' A 30,30 0 '$large',1 50,20 L 50,50 Z" fill="black"/>
    </svg>'
  fi
  if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    # Fallback: rasterize at 14x14 if librsvg isn't installed.
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize 14x14 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi
}

# Dash icon shown when the session has reset since the last data scrape,
# signalling that the displayed numbers are stale and the user should click
# to refresh.
generate_dash_b64() {
  local svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
    <rect x="20" y="45" width="60" height="10" rx="3" fill="black"/>
  </svg>'
  if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize 14x14 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi
}

# Has the session reset time passed since we last scraped? If so, the cached
# numbers no longer reflect reality and we surface a dash to prompt a refresh.
SESSION_EXPIRED=0
if [ -n "$RESET_EPOCH" ]; then
  NOW_EPOCH=$(date +%s)
  [ "$NOW_EPOCH" -gt "$RESET_EPOCH" ] && SESSION_EXPIRED=1
fi

# Choose icon: dash if stale, pie chart based on session time, or empty ring
# if we have no session data (e.g. before the extension has reported anything).
ICON_B64=""
if [ "$SESSION_EXPIRED" = "1" ]; then
  ICON_B64="$(generate_dash_b64)"
elif [ -n "$PIE_PCT" ]; then
  ICON_B64="$(generate_pie_b64 "$PIE_PCT")"
else
  # No session data yet -> render an empty 100% ring as a placeholder.
  ICON_B64="$(generate_pie_b64 100)"
fi

# --- Menu bar title ---
TITLE_TEXT="--"
if [ "$SESSION_EXPIRED" = "1" ]; then
  TITLE_TEXT="–"
elif [ -n "$JSON" ] && [ -n "$SESSION_PCT" ]; then
  TITLE_TEXT="${SESSION_PCT}%"
fi

if [ -n "$ICON_B64" ]; then
  echo " ${TITLE_TEXT} | templateImage=${ICON_B64}"
else
  echo "☁ ${TITLE_TEXT}"
fi
echo "---"

# Action shortcuts:
#   $C — clickable row that opens the usage page (renders white in dark mode).
#   $G — clickable row that triggers a refresh (rendered grey).
#   No suffix means no action -> macOS renders the row dimmed/grey automatically.
USAGE_URL="https://claude.ai/settings/usage"
COST_URL="https://platform.claude.com/workspaces/default/cost"
REFRESH_HELPER="$HOME/.local/bin/claude-usage-refresh"
C="href=$USAGE_URL"
CC="href=$COST_URL"
G="bash=$REFRESH_HELPER terminal=false refresh=true color=#888888,#888888"

if [ -z "$JSON" ]; then
  echo "No data — is the local server running? | color=red"
  echo "Open Claude.ai | $C"
  exit 0
fi

# --- Session block ---
# Grey header line (no action). Prefer the absolute reset time we computed
# above; fall back to whatever the page said ("Resets in 1 hr 50 min").
SESSION_HEADER_RESET="$SESSION_RESET_AT"
[ -z "$SESSION_HEADER_RESET" ] && SESSION_HEADER_RESET="$SESSION_RESET"
if [ -n "$SESSION_HEADER_RESET" ]; then
  echo "Session – ${SESSION_HEADER_RESET}"
else
  echo "Session"
fi
# White data row.
if [ -n "$SESSION_PCT" ]; then
  echo "All Models: ${SESSION_PCT}% Used | $C"
fi

echo "---"

# --- Weekly block ---
WEEKLY_RESET="$WEEKLY_ALL_RESET"
[ -z "$WEEKLY_RESET" ] && WEEKLY_RESET="$WEEKLY_SONNET_RESET"
[ -z "$WEEKLY_RESET" ] && WEEKLY_RESET="$WEEKLY_OPUS_RESET"
[ -z "$WEEKLY_RESET" ] && WEEKLY_RESET="$WEEKLY_DESIGN_RESET"

if [ -n "$WEEKLY_RESET" ]; then
  echo "Weekly – ${WEEKLY_RESET}"
else
  echo "Weekly"
fi

row() {
  local label="$1" pct="$2"
  if [ -n "$pct" ]; then
    echo "${label}: ${pct}% Used | $C"
  fi
}

row "All Models" "$WEEKLY_ALL_PCT"
row "Sonnet"     "$WEEKLY_SONNET_PCT"
row "Opus"       "$WEEKLY_OPUS_PCT"
row "Design"     "$WEEKLY_DESIGN_PCT"

# --- API Cost block ---
# Show only if we have any cost data (otherwise the section is hidden).
if [ -n "$COST_TOTAL$COST_OPUS$COST_SONNET$COST_HAIKU" ]; then
  echo "---"
  echo "API Cost – Month to Date"
  [ -n "$COST_TOTAL"  ] && echo "All Models: $(fmt_usd "$COST_TOTAL") | $CC"
  [ -n "$COST_OPUS"   ] && echo "Opus: $(fmt_usd "$COST_OPUS") | $CC"
  [ -n "$COST_SONNET" ] && echo "Sonnet: $(fmt_usd "$COST_SONNET") | $CC"
  [ -n "$COST_HAIKU"  ] && echo "Haiku: $(fmt_usd "$COST_HAIKU") | $CC"
fi

echo "---"

if [ -n "$UPDATED_AT" ]; then
  NOW_MS=$(($(date +%s) * 1000))
  DELTA_MIN=$(( (NOW_MS - UPDATED_AT) / 60000 ))
  if [ "$DELTA_MIN" -le 0 ]; then
    echo "Last updated: just now | $G"
  elif [ "$DELTA_MIN" -eq 1 ]; then
    echo "Last updated: 1 min ago | $G"
  else
    echo "Last updated: ${DELTA_MIN} min ago | $G"
  fi
else
  echo "Last updated: unknown | $G"
fi

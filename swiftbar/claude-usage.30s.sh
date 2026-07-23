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
UPDATED_AT=$(parse '.updatedAt')
USAGE_TS=$(parse '.usageTs')

# API Usage (percent of budget + dollars spent) per provider.
API_CLAUDE_PCT=$(parse '.apiCostClaude.pct')
API_CLAUDE_USD=$(parse '.apiCostClaude.usd')
API_CLAUDE_TS=$(parse '.apiCostClaude.ts')
API_OPENAI_PCT=$(parse '.apiCostOpenai.pct')
API_OPENAI_USD=$(parse '.apiCostOpenai.usd')
API_OPENAI_TS=$(parse '.apiCostOpenai.ts')
API_GOOGLE_PCT=$(parse '.apiCostGoogle.pct')
API_GOOGLE_USD=$(parse '.apiCostGoogle.usd')
API_GOOGLE_TS=$(parse '.apiCostGoogle.ts')

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

# Action shortcuts. SwiftBar rows: `href=` opens a URL; `bash=... param1=...`
# runs an executable (default text color = white in dark mode); no suffix ->
# macOS dims the row grey automatically.
USAGE_URL="https://claude.ai/settings/usage"
CLAUDE_BILLING_URL="https://platform.claude.com/settings/billing"
OPENAI_URL="https://platform.openai.com/settings/proj_vxOhdwuqhmqTXXVDefWUzMRY/limits"
GOOGLE_URL="https://aistudio.google.com/u/2/spend?project=gen-lang-client-0546438527"
REFRESH_HELPER="$HOME/.local/bin/claude-usage-refresh"

# Header rows that trigger a scoped refresh (reload just that tab group).
REFRESH_USAGE="bash=$REFRESH_HELPER param1=usage terminal=false refresh=true"
REFRESH_APICOST="bash=$REFRESH_HELPER param1=apicost terminal=false refresh=true"
# Grey footer row that refreshes everything.
G="bash=$REFRESH_HELPER terminal=false refresh=true color=#888888,#888888"

if [ -z "$JSON" ]; then
  echo "No data — is the local server running? | color=red"
  echo "Open Claude.ai | href=$USAGE_URL"
  exit 0
fi

# --- Short reset-time formatting ---------------------------------------------
# Render an epoch (seconds) as "9:20p" / "1:05a" — full time, no rounding.
short_time_from_epoch() {
  local epoch="$1"
  [ -z "$epoch" ] && return
  local hm p letter
  hm=$(date -r "$epoch" +"%-I:%M" 2>/dev/null)
  p=$(date -r "$epoch" +"%p" 2>/dev/null)
  [ -z "$hm" ] && return
  letter="a"; [ "$p" = "PM" ] && letter="p"
  echo "${hm}${letter}"
}

# Turn "Resets Tue 12:59 AM" into just the day ("Tues").
weekly_short() {
  local s="$1"
  local day
  day=$(echo "$s" | grep -oE '(Mon|Tue|Wed|Thu|Fri|Sat|Sun)' | head -1)
  [ -z "$day" ] && return
  case "$day" in
    Tue) day="Tues" ;;
    Thu) day="Thurs" ;;
  esac
  echo "${day}"
}

# Format a number as "$X.XX" (empty stays empty).
fmt_usd() {
  local n="$1"
  [ -z "$n" ] && return
  awk -v n="$n" 'BEGIN { printf "$%.2f", n }'
}

# --- API Usage row: "Claude: 25% / $12.34" in the provider's brand color ------
# Falls back to just the percent or just the dollars if one is missing, or to
# "— (no data)" if both are. Freshness is conveyed by the "Last update" footer,
# not per-row, so rows never change color or say "stale".
api_cost_row() {
  local label="$1" pct="$2" usd="$3" color="$4"
  local money val
  money=$(fmt_usd "$usd")
  if [ -z "$pct" ] && [ -z "$money" ]; then
    echo "${label}: — (no data)"
    return
  fi
  if [ -n "$pct" ] && [ -n "$money" ]; then val="${pct}% · ${money}"
  elif [ -n "$pct" ]; then val="${pct}%"
  else val="${money}"; fi
  echo "${label}: ${val} | color=${color},${color}"
}

# --- Claude Usage block ------------------------------------------------------
echo "Claude Usage | $REFRESH_USAGE"

# Claude's brand orange (used for the Claude API Usage row).
CLAUDE_ORANGE="#D97757"
# Session and Weekly share their own accent (red).
USAGE_ACCENT="#F97171"
SESSION_SHORT=$(short_time_from_epoch "$RESET_EPOCH")
if [ -n "$SESSION_PCT" ]; then
  if [ -n "$SESSION_SHORT" ]; then
    echo "Session: ${SESSION_PCT}% · ${SESSION_SHORT} | color=${USAGE_ACCENT},${USAGE_ACCENT}"
  else
    echo "Session: ${SESSION_PCT}% | color=${USAGE_ACCENT},${USAGE_ACCENT}"
  fi
fi

WEEKLY_SHORT=$(weekly_short "$WEEKLY_ALL_RESET")
if [ -n "$WEEKLY_ALL_PCT" ]; then
  if [ -n "$WEEKLY_SHORT" ]; then
    echo "Weekly: ${WEEKLY_ALL_PCT}% · ${WEEKLY_SHORT} | color=${USAGE_ACCENT},${USAGE_ACCENT}"
  else
    echo "Weekly: ${WEEKLY_ALL_PCT}% | color=${USAGE_ACCENT},${USAGE_ACCENT}"
  fi
fi

echo "---"

# --- API Usage block (percent of budget + spend) -----------------------------
# Always list all three providers so a missing one is obviously flagged.
# The header refreshes; the provider rows are non-clickable, brand-colored labels.
echo "API Usage | $REFRESH_APICOST"
api_cost_row "Claude" "$API_CLAUDE_PCT" "$API_CLAUDE_USD" "$CLAUDE_ORANGE"
api_cost_row "OpenAI" "$API_OPENAI_PCT" "$API_OPENAI_USD" "#0080F7"
api_cost_row "Google" "$API_GOOGLE_PCT" "$API_GOOGLE_USD" "#11B55E"

echo "---"

# "Last update" reflects when everything was last current — i.e. the OLDEST of
# the per-source timestamps (usage scrape + the three provider scrapes). That
# way the footer alone tells you how stale the whole panel is.
LAST_ALL=""
for t in "$USAGE_TS" "$API_CLAUDE_TS" "$API_OPENAI_TS" "$API_GOOGLE_TS"; do
  [ -z "$t" ] && continue
  if [ -z "$LAST_ALL" ] || { [ "$t" -lt "$LAST_ALL" ] 2>/dev/null; }; then
    LAST_ALL="$t"
  fi
done
[ -z "$LAST_ALL" ] && LAST_ALL="$UPDATED_AT"

if [ -n "$LAST_ALL" ]; then
  NOW_MS=$(($(date +%s) * 1000))
  DELTA_MIN=$(( (NOW_MS - LAST_ALL) / 60000 ))
  if [ "$DELTA_MIN" -le 0 ]; then
    echo "Last update: just now | $G"
  elif [ "$DELTA_MIN" -eq 1 ]; then
    echo "Last update: 1 min ago | $G"
  else
    echo "Last update: ${DELTA_MIN} min ago | $G"
  fi
else
  echo "Last update: unknown | $G"
fi

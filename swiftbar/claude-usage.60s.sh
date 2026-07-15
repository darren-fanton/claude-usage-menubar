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
# refreshOnOpen intentionally omitted: it makes SwiftBar re-run this whole script
# (curl + ~19 image builds) synchronously before drawing the dropdown, causing a
# multi-second lag on every click. Without it the menu opens instantly from the
# last background refresh (data is at most one 60s cycle stale). The extension
# only POSTs fresh data every 60s, so refreshing faster than that is wasted work
# -- hence the 60s filename interval.

# SwiftBar runs plugins with a minimal PATH; add Homebrew so `magick`, `jq`,
# and other tools installed via brew are discoverable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --- Fast-open cache ---
# SwiftBar re-runs this script when the dropdown is opened, and a full render
# (curl + vector-image builds) takes a fraction of a second, so the menu lagged
# on every click. Fix: render at most once per CACHE_MAX_AGE seconds. A run whose
# cache is still fresh just replays the cached output (~5ms => instant open); only
# the periodic 60s SwiftBar refresh (whose cache has aged out) pays for a real
# render. AGE is just under the 60s refresh interval so a dropdown-open between
# background refreshes always replays instantly. All output is captured to the
# cache via an fd redirect + EXIT trap, so every exit path (including the early
# "no data" exits below) finalizes the cache and still writes the menu to SwiftBar
# on the saved stdout (fd 3).
CACHE="$HOME/.cache/claude-usage/menu.txt"
CACHE_MAX_AGE=55
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_MAX_AGE" ]; then
    cat "$CACHE"
    exit 0
  fi
fi
mkdir -p "$(dirname "$CACHE")"
CACHE_TMP="$CACHE.$$"
exec 3>&1 >"$CACHE_TMP"
trap 'mv -f "$CACHE_TMP" "$CACHE" 2>/dev/null; cat "$CACHE" >&3 2>/dev/null' EXIT

# --- Image memoization ---
# Every render used to rebuild ~19 vector images from scratch (each an
# `rsvg-convert | base64` pipeline), even though the section pills and most bars
# are byte-for-byte identical cycle to cycle. Memoize each generated image on
# disk keyed by the inputs that determine it, so a steady state spawns ~0
# rsvg-convert processes instead of 19. The dir is versioned so a change to the
# image-drawing code (bump IMG_V) invalidates every stale cached image at once.
IMG_V=1
IMGCACHE="$HOME/.cache/claude-usage/img/v$IMG_V"
mkdir -p "$IMGCACHE"
# Reset-countdown strings change each minute, so their images accumulate; evict
# anything older than a day. One find per real render is negligible next to the
# ~19 rsvg-convert calls the cache removes.
find "$IMGCACHE" -type f -mtime +1 -delete 2>/dev/null

ENDPOINT="http://localhost:7823/usage"

JSON=$(curl -fsS --max-time 2 "$ENDPOINT" 2>/dev/null)

# Extract every field we need in ONE pass. Previously each field shelled out to
# its own `jq` (16 subprocesses per render); now a single jq (or python fallback)
# emits all values, one per line in a fixed order, with a blank line for any
# missing/null field so the read block below stays aligned.
read_fields() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$JSON" | jq -r '
      [ .session.pct, .session.reset,
        .weekly.allModels.pct, .weekly.allModels.reset,
        .weekly.sonnet.pct, .weekly.sonnet.reset,
        .weekly.design.pct, .weekly.design.reset,
        .weekly.opus.pct, .weekly.opus.reset,
        .weekly.fable.pct,
        .cost.totalUSD, .cost.perModel.opus, .cost.perModel.sonnet, .cost.perModel.haiku,
        .updatedAt
      ] | map(if . == null then "" else . end) | .[]' 2>/dev/null
  else
    printf '%s' "$JSON" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read() or '{}')
except Exception:
    d = {}
def g(*ks):
    cur = d
    for k in ks:
        cur = cur.get(k) if isinstance(cur, dict) else None
        if cur is None: return ''
    return cur
rows = [
    g('session','pct'), g('session','reset'),
    g('weekly','allModels','pct'), g('weekly','allModels','reset'),
    g('weekly','sonnet','pct'), g('weekly','sonnet','reset'),
    g('weekly','design','pct'), g('weekly','design','reset'),
    g('weekly','opus','pct'), g('weekly','opus','reset'),
    g('weekly','fable','pct'),
    g('cost','totalUSD'), g('cost','perModel','opus'), g('cost','perModel','sonnet'), g('cost','perModel','haiku'),
    g('updatedAt'),
]
for r in rows:
    print('' if r is None else r)
" 2>/dev/null
  fi
}

{
  IFS= read -r SESSION_PCT
  IFS= read -r SESSION_RESET
  IFS= read -r WEEKLY_ALL_PCT
  IFS= read -r WEEKLY_ALL_RESET
  IFS= read -r WEEKLY_SONNET_PCT
  IFS= read -r WEEKLY_SONNET_RESET
  IFS= read -r WEEKLY_DESIGN_PCT
  IFS= read -r WEEKLY_DESIGN_RESET
  IFS= read -r WEEKLY_OPUS_PCT
  IFS= read -r WEEKLY_OPUS_RESET
  IFS= read -r WEEKLY_FABLE_PCT
  IFS= read -r COST_TOTAL
  IFS= read -r COST_OPUS
  IFS= read -r COST_SONNET
  IFS= read -r COST_HAIKU
  IFS= read -r UPDATED_AT
} < <(read_fields)

# Format a number as $XX.XX (or "-" if empty).
fmt_usd() {
  local n="$1"
  [ -z "$n" ] && { echo "-"; return; }
  awk -v n="$n" 'BEGIN { printf "$%.2f", n }'
}

# Format time remaining until an epoch as "1h 32m" / "47m" (live countdown).
# Echoes nothing if the target is empty, non-numeric, or already past.
fmt_remaining() {
  local target="$1" now diff h m
  [ -n "$target" ] || return
  case "$target" in *[!0-9]*) return;; esac
  now=$(date +%s)
  diff=$(( target - now ))
  [ "$diff" -le 0 ] && return
  h=$(( diff / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then echo "${h}h ${m}m"; else echo "${m}m"; fi
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
    # Build the bare reset time "H:MM AM/PM" anchored to when the data was scraped,
    # so the time stays correct regardless of when SwiftBar reads it.
    if [ -n "$UPDATED_AT" ]; then
      RESET_EPOCH=$(( UPDATED_AT/1000 + REMAINING*60 ))
      RESET_TIME=$(date -r "$RESET_EPOCH" +"%-I:%M %p" 2>/dev/null)
      [ -n "$RESET_TIME" ] && SESSION_RESET_AT="${RESET_TIME}"
    fi
  fi
fi

# --- Codex usage (read from the local Codex CLI session logs) ---
# The OpenAI Codex CLI appends `rate_limits` events to its session rollout files
# under ~/.codex/sessions/. Each event carries up to two windows -- a short
# rolling "session" window (~300 min) and a long "weekly" window (10080 min).
# IMPORTANT: do NOT key off the `primary`/`secondary` slot names. Older builds put
# the 5h window in `primary` and the weekly in `secondary`; newer builds report
# ONLY the weekly window, and put it in `primary`. Keying off the slot made the
# weekly reading (e.g. "2%, resets in 162h") render in the 5h row. Instead we
# classify each window by its `window_minutes` (< 1 day = session, else weekly)
# and fill the session/weekly buckets independently. Any given build may report
# one bucket or both; a missing bucket simply doesn't render. `capped` is detected
# from the genuinely most recent event (an explicit rate_limit_reached_type, or a
# premium limit with no credits left).
CODEX_PCT=""
CODEX_RESET_AT=""
CODEX_RESET_EPOCH=""
CODEX_CAPPED=0
CODEX_WEEKLY_PCT=""
CODEX_WEEKLY_RESET_EPOCH=""
CODEX_SESSIONS="$HOME/.codex/sessions"
if [ -d "$CODEX_SESSIONS" ]; then
  # Newest-first list of recent rollout files (capped for speed).
  CODEX_FILES=$(find "$CODEX_SESSIONS" -name 'rollout-*.jsonl' -type f 2>/dev/null \
    | xargs ls -t 2>/dev/null | head -20)
  # Emits five lines: session used_percent, session resets_at, capped flag (0/1),
  # weekly used_percent, weekly resets_at. Any field may be blank. Windows are
  # classified by `window_minutes` (< 1 day = session, else weekly), NOT by slot,
  # so a build that reports the weekly window in `primary` still lands in the
  # weekly bucket. For each bucket we keep the most recent populated reading found
  # walking the files newest-first.
  CODEX_INFO=$(python3 - $CODEX_FILES <<'PY' 2>/dev/null
import json, sys

# Classify a rate-limit window by its length. The rolling session window is short
# (~300 min); the weekly window is long (10080 min). Fall back to the slot name
# only for the pre-window_minutes schema.
def kind_of(w, slot):
    if not w:
        return None
    wm = w.get("window_minutes")
    if isinstance(wm, (int, float)):
        return "session" if wm < 1440 else "weekly"
    return "session" if slot == "primary" else "weekly"

session_pct = session_reset = None
weekly_pct = weekly_reset = None
latest = None                        # most recent rate_limits event overall
for path in sys.argv[1:]:            # files already newest-first
    events = []
    try:
        with open(path) as fh:
            for line in fh:          # lines oldest->newest within a file
                if '"rate_limits"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                rl = (d.get("payload") or {}).get("rate_limits")
                if rl is not None:
                    events.append(rl)
    except Exception:
        continue
    if not events:
        continue
    if latest is None:               # newest file's last event = global latest
        latest = events[-1]
    for rl in reversed(events):      # newest-first within this file
        for slot in ("primary", "secondary"):
            w = rl.get(slot)
            if not w:
                continue
            if w.get("used_percent") is None and w.get("resets_at") is None:
                continue
            k = kind_of(w, slot)
            if k == "session" and session_pct is None and session_reset is None:
                session_pct, session_reset = w.get("used_percent"), w.get("resets_at")
            elif k == "weekly" and weekly_pct is None and weekly_reset is None:
                weekly_pct, weekly_reset = w.get("used_percent"), w.get("resets_at")
    if (session_pct is not None or session_reset is not None) and \
       (weekly_pct is not None or weekly_reset is not None):
        break

capped = 0
if latest is not None:
    creds = latest.get("credits") or {}
    if latest.get("rate_limit_reached_type"):
        capped = 1
    elif latest.get("limit_id") == "premium" and creds.get("has_credits") is False:
        capped = 1

print("" if session_pct is None else session_pct)
print("" if session_reset in (None, "null") else session_reset)
print(capped)
print("" if weekly_pct is None else weekly_pct)
print("" if weekly_reset in (None, "null") else weekly_reset)
PY
)
  { read -r CODEX_PCT_RAW; read -r CODEX_RESET_EPOCH; read -r CODEX_CAPPED; read -r CODEX_WEEKLY_PCT_RAW; read -r CODEX_WEEKLY_RESET_EPOCH; } <<EOF
$CODEX_INFO
EOF
  CODEX_CAPPED=${CODEX_CAPPED:-0}
  # used_percent comes through as a float (e.g. 31.0) -> round to int.
  [ -n "$CODEX_PCT_RAW" ] && CODEX_PCT=$(awk -v p="$CODEX_PCT_RAW" 'BEGIN { printf "%.0f", p }')
  [ -n "$CODEX_WEEKLY_PCT_RAW" ] && CODEX_WEEKLY_PCT=$(awk -v p="$CODEX_WEEKLY_PCT_RAW" 'BEGIN { printf "%.0f", p }')

  # A session (5h) reading is only valid while its window is still open.
  NOW_EPOCH=$(date +%s)
  if [ -n "$CODEX_RESET_EPOCH" ] && [ "$CODEX_RESET_EPOCH" != "null" ] \
     && [ "$CODEX_RESET_EPOCH" -gt "$NOW_EPOCH" ] 2>/dev/null; then
    CODEX_RESET_TIME=$(date -r "$CODEX_RESET_EPOCH" +"%-I:%M %p" 2>/dev/null)
    [ -n "$CODEX_RESET_TIME" ] && CODEX_RESET_AT="${CODEX_RESET_TIME}"
  elif [ -n "$CODEX_PCT_RAW" ]; then
    # A session window WAS reported but its reset time has passed -> the window
    # rolled over, so usage is back to 0%. Show a fresh 0% rather than freezing on
    # the stale percentage; drop the past reset time (we can't know the next one
    # until Codex runs again, so the reset row simply won't render).
    CODEX_PCT="0"
    CODEX_RESET_AT=""
    CODEX_RESET_EPOCH=""
  else
    # No session window at all -- newer Codex builds report only the weekly
    # window. Hide the session rows entirely so we don't invent a phantom 0% row;
    # the weekly rows below carry the real data.
    CODEX_PCT=""
    CODEX_RESET_AT=""
    CODEX_RESET_EPOCH=""
  fi
fi

# Render the pie chart from SVG (vector) and downsample to 11x11 with
# high-quality anti-aliasing. Rasterizing at high resolution first and then
# resizing produces much cleaner edges than rasterizing directly at 11x11.
generate_pie_b64() {
  # $1 is the percent of session time CONSUMED. The pie shows time CONSUMED:
  # empty ring at session start, fills clockwise as time passes, ends as a
  # full circle. Outline always visible; inner pie sits inside it with a gap.
  #
  # Output is a vector PDF (via rsvg-convert) with a 16.5x16.5 pt MediaBox.
  # NSImage rasterizes PDF natively at full retina resolution -- the same
  # technique macOS apps like Focus use for crisp menu bar icons.
  local pct=$1 svg _f="$IMGCACHE/pie-$1"
  [ -f "$_f" ] && { cat "$_f"; return; }
  if [ "$pct" -le 0 ]; then
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="42" fill="none" stroke="black" stroke-width="6"/>
    </svg>'
  elif [ "$pct" -ge 100 ]; then
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="42" fill="none" stroke="black" stroke-width="6"/>
      <circle cx="50" cy="50" r="30" fill="black"/>
    </svg>'
  else
    local bx by large
    bx=$(awk -v p="$pct" 'BEGIN { printf "%.3f", 50 + sin(p/100 * 6.2831853) * 30 }')
    by=$(awk -v p="$pct" 'BEGIN { printf "%.3f", 50 - cos(p/100 * 6.2831853) * 30 }')
    [ "$pct" -gt 50 ] && large=1 || large=0
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="42" fill="none" stroke="black" stroke-width="6"/>
      <path d="M 50,20 A 30,30 0 '$large',1 '$bx','$by' L 50,50 Z" fill="black"/>
    </svg>'
  fi
  { if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    # Fallback: rasterize at 14x14 if librsvg isn't installed.
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize 14x14 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi ; } | tee "$_f"
}

# Dash icon shown when the session has reset since the last data scrape,
# signalling that the displayed numbers are stale and the user should click
# to refresh.
generate_dash_b64() {
  local _f="$IMGCACHE/dash"
  [ -f "$_f" ] && { cat "$_f"; return; }
  local svg='<svg xmlns="http://www.w3.org/2000/svg" width="16.5pt" height="16.5pt" viewBox="0 0 100 100">
    <rect x="20" y="45" width="60" height="10" rx="3" fill="black"/>
  </svg>'
  { if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize 14x14 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi ; } | tee "$_f"
}

# Render a colored "pill" title image (rounded rectangle + white label) for a
# section header. SwiftBar can't paint a menu-row background, so we draw the
# header as a full-color image via the same vector pipeline as the pie icon.
#   $1 = label text, $2 = background hex (e.g. "#3b82f6")
generate_label_b64() {
  local text="$1" bg="$2" len w
  local _f="$IMGCACHE/label-${bg//[^[:alnum:]]/_}-${text//[^[:alnum:]]/_}"
  [ -f "$_f" ] && { cat "$_f"; return; }
  len=${#text}
  # ~13 user-units per bold char + 24 units of horizontal padding.
  w=$(( len * 13 + 24 ))
  # Pill body height in units. Larger than the label's ~18 units so there's colored
  # padding above and below the text; bump BODY for more top/bottom pill padding.
  local body=37 rx
  rx=$(( body * 7 / 30 ))                    # scale corner radius with height
  # PADT / PADB units of transparent space ABOVE / BELOW the pill body act as the
  # gaps to the rows around it — baked into the pill's own (already tall) image row
  # so they aren't subject to SwiftBar's minimum-row-height clamp the way a separate
  # spacer row is. Each unit is ~0.607pt, so 8 ≈ 5px.
  local padT=8 padB=8 vbh
  vbh=$(( padT + body + padB ))
  # ~0.607 pt/unit keeps the established horizontal scale; the image (and row) grow
  # taller with PADT + BODY + PADB.
  local hpt wpt ty
  hpt=$(awk -v v="$vbh" 'BEGIN { printf "%.2f", v * 18.2 / 30 }')
  wpt=$(awk -v w="$w" 'BEGIN { printf "%.1f", w * 18.2 / 30 }')
  ty=$(awk -v b="$body" -v pt="$padT" 'BEGIN { printf "%.1f", pt + (b + 18 * 0.717) / 2 }')  # center caps
  local svg='<svg xmlns="http://www.w3.org/2000/svg" width="'"$wpt"'pt" height="'"$hpt"'pt" viewBox="0 0 '"$w"' '"$vbh"'">
    <rect x="0" y="'"$padT"'" width="'"$w"'" height="'"$body"'" rx="'"$rx"'" fill="'"$bg"'"/>
    <text x="'"$((w/2))"'" y="'"$ty"'" font-family="Helvetica" font-size="18" font-weight="bold" fill="#ffffff" text-anchor="middle">'"$text"'</text>
  </svg>'
  { if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize x36 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi ; } | tee "$_f"
}

# Render a horizontal progress bar image: a rounded track (same hue at low opacity
# so it reads on light+dark) with a filled portion proportional to `$1` percent,
# tinted `$2` (hex). The "X% Used" text is rendered separately as the menu row's
# label to the right of this image. Drawn via the same vector pipeline as the pills
# so it's crisp at any retina scale.
#   $1 = percent used (0-100), $2 = fill hex (e.g. "#3b82f6")
generate_bar_b64() {
  local pct="$1" fill="$2"
  [ -z "$pct" ] && pct=0
  case "$pct" in *[!0-9]*) pct=0;; esac
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local _f="$IMGCACHE/bar-${fill//[^[:alnum:]]/_}-$pct"
  [ -f "$_f" ] && { cat "$_f"; return; }
  # Height tuned to sit alongside the row's text label. W/H set the aspect; hpt is
  # the on-screen bar height in pt (wpt scales to keep the ~150pt width).
  local W=200 H=12 fw wpt hpt
  fw=$(awk -v p="$pct" -v w="$W" 'BEGIN { printf "%.1f", w * p / 100 }')
  hpt="9"
  wpt=$(awk -v w="$W" -v h="$hpt" -v ht="$H" 'BEGIN { printf "%.1f", w * h / ht }')
  local svg='<svg xmlns="http://www.w3.org/2000/svg" width="'"$wpt"'pt" height="'"$hpt"'pt" viewBox="0 0 '"$W"' '"$H"'">
    <rect x="0" y="0" width="'"$W"'" height="'"$H"'" rx="6" fill="'"$fill"'" fill-opacity="0.22"/>
    <rect x="0" y="0" width="'"$fw"'" height="'"$H"'" rx="6" fill="'"$fill"'"/>
  </svg>'
  { if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize x24 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi ; } | tee "$_f"
}

# Render a reset time/date row ("↻ 1h 45m ( 4:49 PM )") as a grey image so we can
# control the font size and vertical position (which plain SwiftBar text rows don't
# allow). The text is smaller than the default row font and sits high in a taller
# canvas, so it reads as a caption tucked up under the bar above it.
#   $1 = the full row text (glyph + times)
generate_reset_b64() {
  local text="$1"
  local _f="$IMGCACHE/reset-${text//[^[:alnum:]]/_}"
  [ -f "$_f" ] && { cat "$_f"; return; }
  # Split the leading "↻ " glyph from the time text so the glyph can be drawn a bit
  # larger than the (smaller) time text.
  # Reload icon = the real ↻ (U+21BB) glyph from the macOS SF system font, but
  # OUTLINED to vector path data so there is NO font resolution at render time.
  # (A <text font-family=...> glyph is a gamble: SwiftBar's NSImage SVG rasterizer
  # doesn't resolve "Apple Symbols"/SF and falls back to a heavy face; my local
  # rsvg preview does resolve it, which masked the bug. Embedding the outline makes
  # it render thin identically everywhere.) The path is the SF ↻ outline in font
  # units (upm 2048); the transform flips Y (font up -> SVG down), scales to ~font
  # size, and sits it on the text baseline. Time text stays in Helvetica.
  local rest="${text#↻ }" xrest=1 glyph=""
  if [ "$rest" != "$text" ]; then
    xrest=18
    glyph='<path transform="translate(0,12.2) scale(0.006442,-0.006442)" fill="#8a8a8a" d="M838 -36Q693 -36 566.5 18.5Q440 73 344.0 169.0Q248 265 194.0 391.5Q140 518 140 662Q140 807 194.0 933.5Q248 1060 344.0 1156.0Q440 1252 566.5 1306.0Q693 1360 838 1360Q898 1360 955.5 1350.5Q1013 1341 1066 1321Q1083 1315 1103.5 1300.5Q1124 1286 1124 1251Q1124 1223 1108.5 1205.5Q1093 1188 1069.5 1182.5Q1046 1177 1023 1186Q936 1217 838 1217Q723 1217 622.5 1174.0Q522 1131 446.0 1055.0Q370 979 327.0 878.5Q284 778 284 663Q284 549 327.0 448.5Q370 348 446.0 272.0Q522 196 622.5 153.0Q723 110 838 110Q953 110 1053.5 153.0Q1154 196 1230.0 272.0Q1306 348 1349.0 448.5Q1392 549 1392 663Q1392 693 1413.0 714.0Q1434 735 1464 735Q1494 735 1515.0 714.0Q1536 693 1536 663Q1536 518 1482.0 391.5Q1428 265 1332.0 169.0Q1236 73 1109.5 18.5Q983 -36 838 -36ZM1038 1263 766 1531Q756 1541 751.5 1554.5Q747 1568 747 1582Q747 1613 767.5 1634.5Q788 1656 817 1656Q847 1656 869 1634L1185 1314Q1206 1293 1206 1263Q1206 1232 1185 1211L869 895Q848 875 817 875Q788 875 767.5 895.5Q747 916 747 947Q747 961 752.0 974.0Q757 987 767 997Z"/>'
  fi
  local rlen=${#rest} w H=21
  # ~8pt per char + glyph zone + padding; generous so the text never clips.
  w=$(( xrest + rlen * 8 + 8 ))
  local esc
  esc=$(printf '%s' "$rest" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  # 1 unit = 1pt. Canvas taller than the text (row grows ~8px) with the baseline
  # high so the text hugs the bar above and the slack falls below.
  local svg='<svg xmlns="http://www.w3.org/2000/svg" width="'"$w"'pt" height="'"$H"'pt" viewBox="0 0 '"$w"' '"$H"'">
    '"$glyph"'
    <text x="'"$xrest"'" y="11.5" font-family="Helvetica" font-size="13" fill="#8a8a8a">'"$esc"'</text>
  </svg>'
  { if command -v rsvg-convert >/dev/null 2>&1; then
    echo "$svg" | rsvg-convert --format=pdf 2>/dev/null | base64 | tr -d '\n'
  else
    echo "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos -resize x52 png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi ; } | tee "$_f"
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
  # No session data yet -> render an empty 0% ring as a placeholder.
  ICON_B64="$(generate_pie_b64 0)"
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

# Row suffixes. Every row is purely informational: no href/bash actions, so macOS
# auto-disables the items and they are neither selectable (no hover highlight) nor
# clickable. $G keeps just a grey color for the footer.
C=""
CC=""
CX=""
G="color=#888888,#888888"

# Codex usage comes from local Codex CLI logs, independent of the Claude server,
# so it renders in every path -- always visible, even at 100% or when the
# Claude data is unavailable.
render_codex() {
  [ -n "$CODEX_PCT" ] || [ -n "$CODEX_RESET_AT" ] || [ "$CODEX_CAPPED" = "1" ] \
    || [ -n "$CODEX_WEEKLY_PCT" ] || [ -n "$CODEX_WEEKLY_RESET_EPOCH" ] \
    || return
  # A blank row of vertical spacing above the Codex section. SwiftBar collapses
  # truly empty lines, so emit a non-breaking space (U+00A0) to force a full-height
  # row that renders as blank.
  printf '\xc2\xa0\n'
  # Green pill title (rendered as a full-color image; see the Claude header note).
  echo " | image=$(generate_label_b64 "Codex" "#16a34a")"
  # Capped: the limit is exhausted and Codex stops reporting a 5h window, so show
  # the cap state rather than a stale percentage.
  if [ "$CODEX_CAPPED" = "1" ]; then
    echo "Limit Reached | $CX"
  else
    if [ -n "$CODEX_PCT" ]; then
      echo "${CODEX_PCT}% | image=$(generate_bar_b64 "$CODEX_PCT" "#16a34a") size=12 $CX"
    fi
    if [ -n "$CODEX_RESET_AT" ]; then
      # Grey reload glyph, white time, grey "- <remaining>" (basic ANSI grey).
      codex_rem=$(fmt_remaining "$CODEX_RESET_EPOCH")
      if [ -n "$codex_rem" ]; then
        echo " | image=$(generate_reset_b64 "↻ $codex_rem ( $CODEX_RESET_AT )") $CX"
      else
        echo " | image=$(generate_reset_b64 "↻ $CODEX_RESET_AT") $CX"
      fi
    fi
  fi
  # Weekly (7-day) window rows, directly under the Codex 5h rows.
  render_codex_weekly
}

# Codex's weekly (7-day) window rows: percentage then reset date, shown under the
# Codex header right below the 5h session rows.
render_codex_weekly() {
  [ -n "$CODEX_WEEKLY_PCT" ] || [ -n "$CODEX_WEEKLY_RESET_EPOCH" ] || return
  if [ -n "$CODEX_WEEKLY_PCT" ]; then
    echo "${CODEX_WEEKLY_PCT}% | image=$(generate_bar_b64 "$CODEX_WEEKLY_PCT" "#16a34a") size=12 $CX"
  fi
  if [ -n "$CODEX_WEEKLY_RESET_EPOCH" ] && [ "$CODEX_WEEKLY_RESET_EPOCH" != "null" ]; then
    # Match Claude's weekly reset format: "Mon 12:18 PM" (day then time).
    wk_reset=$(date -r "$CODEX_WEEKLY_RESET_EPOCH" +"%a %-I:%M %p" 2>/dev/null)
    if [ -n "$wk_reset" ]; then
      echo " | image=$(generate_reset_b64 "↻ $wk_reset") $CX"
    fi
  fi
}

if [ -z "$JSON" ]; then
  echo "No data — is the local server running? | color=red"
  echo "Open Claude.ai | $C"
  render_codex
  exit 0
fi

# --- Claude block ---
# Grey header line (no action), then white data rows. Prefer the absolute reset
# time we computed above; fall back to whatever the page said ("Resets in ...").
SESSION_HEADER_RESET="$SESSION_RESET_AT"
[ -z "$SESSION_HEADER_RESET" ] && SESSION_HEADER_RESET="$SESSION_RESET"
# Blue pill title (rendered as a full-color image; SwiftBar can't color a row bg).
echo " | image=$(generate_label_b64 "Claude" "#3b82f6")"
if [ -n "$SESSION_PCT" ]; then
  echo "${SESSION_PCT}% | image=$(generate_bar_b64 "$SESSION_PCT" "#3b82f6") size=12 $C"
fi
# Reset row: reload glyph, time, and live remaining, dimmed to 50% opacity.
# Strip a leading "Resets " from the page-text fallback so it doesn't double up.
if [ -n "$SESSION_HEADER_RESET" ]; then
  reset_time="${SESSION_HEADER_RESET#Resets }"
  rem=$(fmt_remaining "$RESET_EPOCH")
  if [ -n "$rem" ]; then
    echo " | image=$(generate_reset_b64 "↻ $rem ( $reset_time )") $C"
  else
    echo " | image=$(generate_reset_b64 "↻ $reset_time") $C"
  fi
fi
# Weekly (7-day) window rows, directly under the Claude 5h rows: the "All Models"
# percentage, then per-model buckets when present, then the weekly reset date.
if [ -n "$WEEKLY_ALL_PCT" ]; then
  echo "${WEEKLY_ALL_PCT}% | image=$(generate_bar_b64 "$WEEKLY_ALL_PCT" "#3b82f6") size=12 $C"
fi
wk_row() {
  local label="$1" pct="$2"
  [ -n "$pct" ] && echo "${label}: ${pct}% | image=$(generate_bar_b64 "$pct" "#3b82f6") size=12 $C"
}
wk_row "Sonnet" "$WEEKLY_SONNET_PCT"
wk_row "Opus"   "$WEEKLY_OPUS_PCT"
wk_row "Design" "$WEEKLY_DESIGN_PCT"
WEEKLY_RESET="$WEEKLY_ALL_RESET"
[ -z "$WEEKLY_RESET" ] && WEEKLY_RESET="$WEEKLY_SONNET_RESET"
[ -z "$WEEKLY_RESET" ] && WEEKLY_RESET="$WEEKLY_OPUS_RESET"
[ -z "$WEEKLY_RESET" ] && WEEKLY_RESET="$WEEKLY_DESIGN_RESET"
if [ -n "$WEEKLY_RESET" ]; then
  echo " | image=$(generate_reset_b64 "↻ ${WEEKLY_RESET#Resets }") $C"
fi

# --- Fable block ---
# Purple pill + a single usage row (Fable's weekly bucket).
if [ -n "$WEEKLY_FABLE_PCT" ]; then
  printf '\xc2\xa0\n'
  echo " | image=$(generate_label_b64 "Fable" "#9333ea")"
  echo "${WEEKLY_FABLE_PCT}% | image=$(generate_bar_b64 "$WEEKLY_FABLE_PCT" "#9333ea") size=12 $C"
fi

# --- Codex block (5h session + weekly, under one Codex header) ---
render_codex

# --- API Cost block ---
# Show only if we have any cost data (otherwise the section is hidden).
if [ -n "$COST_TOTAL$COST_OPUS$COST_SONNET$COST_HAIKU" ]; then
  # A blank spacer row above the API Cost section (non-breaking space; see note
  # in render_codex).
  printf '\xc2\xa0\n'
  # Orange pill title (full-color image; see the Claude header note).
  echo " | image=$(generate_label_b64 "API Cost" "#f97316")"
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

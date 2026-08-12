#!/bin/bash
# <xbar.title>Claude Usage</xbar.title>
# <xbar.version>v1.2</xbar.version>
# <xbar.author>local</xbar.author>
# <xbar.desc>Shows Claude session and weekly usage limits from the OAuth usage API.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# refreshOnOpen intentionally omitted: it makes SwiftBar re-run this whole script
# (curl + ~19 image builds) synchronously before drawing the dropdown, causing a
# multi-second lag on every click. Without it the menu opens instantly from the
# last background refresh (data is at most one 60s cycle stale). A 60s cadence is
# plenty for a 5-hour usage window, hence the 60s filename interval.

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
IMG_V=2
IMGCACHE="$HOME/.cache/claude-usage/img/v$IMG_V"
mkdir -p "$IMGCACHE"
# Reset-countdown strings change each minute, so their images accumulate; evict
# anything older than a day. One find per real render is negligible next to the
# ~19 rsvg-convert calls the cache removes.
find "$IMGCACHE" -type f -mtime +1 -delete 2>/dev/null

# --- SVG -> base64 PNG ---
# Renders $1 (SVG source) to a 2x PNG and stamps it 144 DPI, so NSImage reports the
# SVG's own point size ($2 x $3) while carrying retina pixels.
#
# We deliberately do NOT emit PDF here. A PDF-backed NSImage has no pixel
# representation, so CoreGraphics re-rasterizes it through WindowServer on every
# draw. With 11 images in the dropdown that made each 60s SwiftBar refresh saturate
# the compositor for ~4s, stalling input system-wide. A PNG is a straight blit.
#   $1 = SVG source, $2 = width in pt, $3 = height in pt
svg_to_b64() {
  local svg="$1" w2 h2
  w2=$(awk -v v="$2" 'BEGIN { printf "%.0f", v * 2 }')
  h2=$(awk -v v="$3" 'BEGIN { printf "%.0f", v * 2 }')
  if command -v rsvg-convert >/dev/null 2>&1 && command -v magick >/dev/null 2>&1; then
    printf '%s' "$svg" \
      | rsvg-convert --format=png -w "$w2" -h "$h2" 2>/dev/null \
      | magick png:- -density 144 -units PixelsPerInch png:- 2>/dev/null \
      | base64 | tr -d '\n'
  else
    # No librsvg: rasterize with ImageMagick alone, same 2x-at-144-DPI contract.
    printf '%s' "$svg" \
      | magick -background none -density 800 svg:- -filter Lanczos \
               -resize "${w2}x${h2}" -density 144 -units PixelsPerInch png:- 2>/dev/null \
      | base64 | tr -d '\n'
  fi
}

# --- Cost + pushed usage: read the local server first ---
# The usage endpoint carries no console spend figure -- its `spend` field is
# prepaid credits, a different number -- so the API Cost rows still come from
# cost.js scraping platform.claude.com into the local server. Month-to-date spend
# moves slowly, so that page is reloaded every 30 min (see refresh-usage.sh)
# rather than every 60s like the old usage scrape.
COST_JSON=$(curl -fsS --max-time 2 "http://localhost:7823/usage" 2>/dev/null)

# --- Preferred usage source: pushed by the extension ---
# usage.js (running in any claude.ai tab) calls claude.ai's own cookie-authenticated
# /api/organizations/<org>/usage once a minute and POSTs the result here. That is the
# ONLY way to get per-minute usage: the OAuth API below is rate-limited to roughly one
# call every three minutes across all its consumers (this plugin, Claude Code, and the
# Claude desktop app), so polling it every 60s just returns 429.
#
# The two endpoints return an identical payload shape, so whichever wins is parsed by
# exactly the same code below. If nothing has pushed recently -- no claude.ai tab open,
# browser closed -- we fall through to the OAuth API on its slower TTL.
USAGE_PUSH_MAX=150
PUSHED_USAGE=""
PUSHED_AGE=0
if [ -n "$COST_JSON" ]; then
  _pushed=$(printf '%s' "$COST_JSON" | python3 -c "
import json, sys, time
try:
    d = json.loads(sys.stdin.read() or '{}')
except Exception:
    d = {}
u, ts = d.get('usage'), d.get('usageUpdatedAt')
if isinstance(u, dict) and u.get('five_hour') and isinstance(ts, (int, float)):
    age = int(time.time() - ts / 1000)
    if 0 <= age < $USAGE_PUSH_MAX:
        print(age)
        print(json.dumps(u))
" 2>/dev/null)
  if [ -n "$_pushed" ]; then
    PUSHED_AGE=$(printf '%s' "$_pushed" | sed -n 1p)
    PUSHED_USAGE=$(printf '%s' "$_pushed" | sed -n 2p)
  fi
fi

# --- Usage: direct OAuth API call ---
# The session/weekly numbers come straight from Claude's OAuth usage endpoint
# rather than the browser extension. That drops the dependency on a claude.ai tab
# staying open (and being force-reloaded every 60s) for the fastest-moving number
# in the menu bar, and gives us absolute `resets_at` timestamps instead of scraped
# relative text like "Resets in 1 hr 45 min".
#
# The bearer token is Claude Code's own OAuth token from the login keychain. It
# rotates roughly hourly and Claude Code refreshes it on use, so re-reading the
# keychain each render always picks up the current one. We deliberately do NOT
# touch the refresh token -- refreshing here would race Claude Code's own session.
#
# This endpoint is internal and undocumented (the payload carries codenamed
# fields like `tangelo` and `nimbus_quill`), so it can change without notice.
API_URL="https://api.anthropic.com/api/oauth/usage"
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)

# --- Fetch throttle + last-good cache ---
# This endpoint rate-limits hard. Measured: one request per 60s returned HTTP 429
# on 7 of 7 attempts over 7 minutes, with an unhelpful `retry-after: 0`. We are not
# the only consumer -- Claude Code polls the same endpoint for its own status -- so
# a 60s plugin poll simply does not fit in the budget.
#
# So: render every 60s as before, but only actually CALL the API when the cached
# payload is older than USAGE_TTL. In between, the cached payload is reused. That
# drops us from ~60 calls/hour to ~12 and leaves headroom for Claude Code.
#
# Separately, if a fetch fails we keep serving the last good payload up to
# USAGE_STALE_MAX so a transient 429 never blanks a menu that was correct a minute
# ago. Past that the numbers are too old to show and the error surfaces instead.
#
# This is NOT a fallback to the extension/localhost for usage -- that stays removed
# by request. It is only this script re-using its own most recent API response.
USAGE_CACHE="$HOME/.cache/claude-usage/usage.json"
USAGE_TTL=300
USAGE_STALE_MAX=1800

_cache_age=999999
if [ -f "$USAGE_CACHE" ]; then
  _cache_age=$(( $(date +%s) - $(stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0) ))
  [ "$_cache_age" -lt 0 ] && _cache_age=999999
fi

USAGE_JSON=""
HTTP_CODE=""
USAGE_AGE=0
if [ -n "$PUSHED_USAGE" ]; then
  # A claude.ai tab pushed within USAGE_PUSH_MAX: use it and make NO OAuth call at
  # all this render. This is the normal path, and it is what makes 60s updates
  # possible without touching the rate-limited endpoint.
  USAGE_JSON="$PUSHED_USAGE"
  USAGE_AGE="$PUSHED_AGE"
elif [ -n "$TOKEN" ] && [ "$_cache_age" -ge "$USAGE_TTL" ]; then
  _resp=$(curl -sS -w $'\n%{http_code}' --max-time 4 "$API_URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-cli/2.1.227 (external, cli)" 2>/dev/null)
  HTTP_CODE="${_resp##*$'\n'}"
  [ "$HTTP_CODE" = "200" ] && USAGE_JSON="${_resp%$'\n'*}"
fi

if [ -n "$USAGE_JSON" ]; then
  printf '%s' "$USAGE_JSON" > "$USAGE_CACHE.$$" && mv -f "$USAGE_CACHE.$$" "$USAGE_CACHE"
elif [ -f "$USAGE_CACHE" ] && [ "$_cache_age" -lt "$USAGE_STALE_MAX" ]; then
  USAGE_JSON=$(cat "$USAGE_CACHE" 2>/dev/null)
  USAGE_AGE="$_cache_age"
fi

# Extract every field from BOTH payloads in ONE pass, one value per line in a
# fixed order, blank for anything missing, so the read block below stays aligned.
# This is python-only rather than the previous jq-first split: the API returns ISO
# timestamps that need real date parsing, which jq's fromdateiso8601 will not take
# with fractional seconds and a +00:00 offset. It is still a single subprocess.
# The two payloads are fed on one stdin separated by a 0x1F record separator.
read_fields() {
  printf '%s\n\037\n%s' "$USAGE_JSON" "$COST_JSON" | python3 -c "
import json, sys, time
from datetime import datetime

raw = sys.stdin.read().split('\n\037\n')
def load(i):
    try:
        return json.loads(raw[i]) if i < len(raw) and raw[i].strip() else {}
    except Exception:
        return {}
u, c = load(0), load(1)

def epoch(iso):
    # resets_at looks like 2026-08-11T20:00:00.651709+00:00
    if not iso:
        return ''
    try:
        return str(int(datetime.fromisoformat(iso).timestamp()))
    except Exception:
        return ''

def win(name):
    w = u.get(name)
    return w if isinstance(w, dict) else {}

def pct(w):
    v = w.get('utilization')
    return '' if v is None else str(int(round(v)))

# Per-model weekly buckets arrive as weekly_scoped entries in limits[], keyed by
# model display name. Build the map once so any model Anthropic adds later shows
# up without another code change.
scoped = {}
for l in (u.get('limits') or []):
    if not isinstance(l, dict) or l.get('kind') != 'weekly_scoped':
        continue
    name = (((l.get('scope') or {}).get('model') or {}).get('display_name') or '').lower()
    if name:
        scoped[name] = l

def scoped_pct(name):
    l = scoped.get(name)
    if l and l.get('percent') is not None:
        return str(int(round(l['percent'])))
    # Fall back to the top-level seven_day_<model> window when present.
    return pct(win('seven_day_' + name))

def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)

# Cost is keyed by SERVICE (claude, gemini, ...), one row each -- never by model.
# A null value is meaningful, not missing: the provider page rendered but has no
# figure yet (Gemini shows a dash until Google's billing pipeline reports, up to
# 24h later). Keep it so the row still shows, as a dash -- printing 0 would claim
# zero spend rather than not-known-yet.
# 'totalUSD'/'perModel' are the pre-per-service payload shape; ignore them rather
# than render a stray 'TotalUSD:' row from a not-yet-reloaded script.
costs = dict(
    (k, v) for k, v in (c.get('cost') or {}).items()
    if k not in ('period', 'totalUSD', 'perModel') and (v is None or is_num(v))
)

# Age in seconds since each service last POSTed, from the per-service arrival
# stamps the server writes. The global updatedAt stands in ONLY while no stamps
# exist at all -- state written before the server recorded them -- so a first run
# after the upgrade doesn't flag every row until each scraper has posted once.
# Once any stamp exists the fallback is dropped: it is clobbered by whichever
# scraper posted last, so a service missing from the map would otherwise hide
# behind its neighbours' liveness, which is exactly the case worth flagging.
stamps = c.get('costUpdatedAt') or {}
fallback = None if stamps else c.get('updatedAt')
now_ms = time.time() * 1000

def age_of(k):
    ts = stamps.get(k)
    if not is_num(ts):
        ts = fallback
    if not is_num(ts):
        return ''
    return str(max(0, int((now_ms - ts) / 1000)))

five, seven = win('five_hour'), win('seven_day')
rows = [
    pct(five), epoch(five.get('resets_at')),
    pct(seven), epoch(seven.get('resets_at')),
    scoped_pct('sonnet'),
    scoped_pct('opus'),
    scoped_pct('design'),
    scoped_pct('fable'),
    # Values and ages as name=value pairs joined by ';', over the same sorted key
    # set, so adding a new provider needs no change here or in the renderer.
    # NB: no double quotes anywhere in this python block; it is embedded in a bash
    # double-quoted string and a quote here silently truncates the whole parser.
    ';'.join('%s=%s' % (k, '' if costs[k] is None else costs[k]) for k in sorted(costs)),
    ';'.join('%s=%s' % (k, age_of(k)) for k in sorted(costs)),
]
for r in rows:
    print('' if r is None else r)
" 2>/dev/null
}

{
  IFS= read -r SESSION_PCT
  IFS= read -r RESET_EPOCH
  IFS= read -r WEEKLY_ALL_PCT
  IFS= read -r WEEKLY_RESET_EPOCH
  IFS= read -r WEEKLY_SONNET_PCT
  IFS= read -r WEEKLY_OPUS_PCT
  IFS= read -r WEEKLY_DESIGN_PCT
  IFS= read -r WEEKLY_FABLE_PCT
  IFS= read -r COST_SERVICES
  IFS= read -r COST_AGES
} < <(read_fields)

# How old a service's last reported figure may get before its row is flagged as
# not updating. Each scraper POSTs every 60s while its tab is open and posts
# NOTHING when the scrape fails, so anything past a few minutes means that one
# provider's pipeline is down (tab closed, logged out, markup moved) even while
# the others keep reporting. 15 min tolerates the 30-min page reload cycle's
# in-flight gaps without sitting on a genuine break for long.
COST_STALE_MAX=900

# Human age from a seconds count: "just now" / "5 min ago" / "3h ago" / "2d ago".
fmt_age() {
  local s="$1" m h d
  case "$s" in ''|*[!0-9]*) echo "unknown"; return;; esac
  m=$(( s / 60 ))
  [ "$m" -lt 1 ] && { echo "just now"; return; }
  [ "$m" -eq 1 ] && { echo "1 min ago"; return; }
  [ "$m" -lt 90 ] && { echo "$m min ago"; return; }
  h=$(( m / 60 ))
  [ "$h" -lt 48 ] && { echo "${h}h ago"; return; }
  d=$(( h / 24 ))
  echo "${d}d ago"
}

# Look up one service's age (seconds) in the "claude=45;gemini=3600" pair string.
# Echoes nothing when that service has no recorded update at all.
cost_age() {
  local key="$1" pair _ifs="$IFS"
  IFS=';'
  for pair in $COST_AGES; do
    if [ "${pair%%=*}" = "$key" ]; then
      IFS="$_ifs"
      printf '%s' "${pair#*=}"
      return
    fi
  done
  IFS="$_ifs"
}

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
# Claude sessions are 5-hour rolling windows, so 300 minutes total. The API hands
# us an absolute reset timestamp, so elapsed time is just the remainder of that
# window: no more parsing "Resets in 1 hr 45 min" out of scraped page text, and no
# more anchoring the result to a scrape time that could already be a minute stale.
SESSION_TOTAL_MIN=300

PIE_PCT=""
SESSION_RESET_AT=""
if [ -n "$RESET_EPOCH" ]; then
  REMAINING=$(( (RESET_EPOCH - $(date +%s)) / 60 ))
  if [ "$REMAINING" -gt 0 ]; then
    PIE_PCT=$(( (SESSION_TOTAL_MIN - REMAINING) * 100 / SESSION_TOTAL_MIN ))
    [ "$PIE_PCT" -lt 0 ]   && PIE_PCT=0
    [ "$PIE_PCT" -gt 100 ] && PIE_PCT=100
    SESSION_RESET_AT=$(date -r "$RESET_EPOCH" +"%-I:%M %p" 2>/dev/null)
  else
    # The reset time has passed: the 5-hour window rolled over, so usage is back
    # to 0 for the window we are now in. Report a fresh 0% and an empty ring
    # rather than freezing on the previous window's percentage. The old reset
    # time is dropped rather than shown in the past -- the next one isn't known
    # until the API reports again, so the reset row simply won't render. Same
    # rule the Codex block applies to its own rolled-over session window.
    SESSION_PCT="0"
    RESET_EPOCH=""
  fi
fi

# --- Weekly cap override for the menu bar ---
# The 7-day all-models bucket is the hard stop: at 100% nothing runs until it
# resets, whatever the 5-hour number says. So the menu bar reports the cap --
# full pie, 100% -- rather than a comfortable session percentage beside a
# part-filled ring, which would read as "plenty left" while everything is
# blocked. This deliberately outranks the session rollover above; a fresh 5h
# window is worth nothing while the week is capped.
#
# Only the menu bar is overridden. The dropdown keeps showing the true session
# and per-model numbers, which is where you look to find out WHAT is exhausted.
TITLE_PCT="$SESSION_PCT"
case "$WEEKLY_ALL_PCT" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$WEEKLY_ALL_PCT" -ge 100 ]; then
      TITLE_PCT="100"
      PIE_PCT=100
    fi
    ;;
esac

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
CODEX_WARN=""
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

  # Warning conditions for the Codex header. This section is fed by local rollout
  # logs, so "broken" means the logs are present but yield nothing usable -- the
  # schema moved (this parser has been bitten by that before) -- or the newest
  # reading belongs to a weekly window that has already closed, i.e. every number
  # under the header is from an expired window. NOT having run Codex lately is not
  # a warning: the 5h rollover above already renders that as a fresh 0%.
  if [ -z "$CODEX_FILES" ]; then
    CODEX_WARN="No Codex session logs in ~/.codex/sessions"
  elif [ -z "$CODEX_PCT_RAW" ] && [ -z "$CODEX_WEEKLY_PCT_RAW" ]; then
    CODEX_WARN="Session logs carry no rate-limit data — the Codex log format may have changed"
  elif [ -n "$CODEX_WEEKLY_RESET_EPOCH" ] && [ "$CODEX_WEEKLY_RESET_EPOCH" != "null" ] \
       && [ "$CODEX_WEEKLY_RESET_EPOCH" -le "$NOW_EPOCH" ] 2>/dev/null; then
    CODEX_WARN="Weekly window already reset — no new reading since Codex last ran"
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
  # Output is a 2x PNG stamped 144 DPI (see svg_to_b64), so NSImage reports a
  # 16.5x16.5 pt image backed by 33x33 retina pixels.
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
  svg_to_b64 "$svg" 16.5 16.5 | tee "$_f"
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
  svg_to_b64 "$svg" "$wpt" "$hpt" | tee "$_f"
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
  svg_to_b64 "$svg" "$wpt" "$hpt" | tee "$_f"
}

# Render a reset time/date row ("↻ 1h 45m ( 4:49 PM )") as a grey image so we can
# control the font size and vertical position (which plain SwiftBar text rows don't
# allow). The text is smaller than the default row font and sits high in a taller
# canvas, so it reads as a caption tucked up under the bar above it.
#   $1 = the full row text (glyph + times)
# $2 = "volatile" when the text embeds a live countdown ("1h 21m"), which changes
# every minute. Those images can never be reused -- next render's key is different --
# so memoizing them is pure cost: a dead file written per render per row, unbounded
# growth (measured 2069 files / 16MB after a day, 91% of the whole image cache), and
# a daily-eviction `find` that then has to walk all of them. Volatile rows skip the
# cache in both directions and just render. Static rows (a bare reset time, e.g.
# "↻ Tue 1:00 AM") still memoize and hit essentially every time.
generate_reset_b64() {
  local text="$1" volatile="$2" _f=""
  if [ "$volatile" != "volatile" ]; then
    _f="$IMGCACHE/reset-${text//[^[:alnum:]]/_}"
    [ -f "$_f" ] && { cat "$_f"; return; }
  fi
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
  if [ -n "$_f" ]; then
    svg_to_b64 "$svg" "$w" "$H" | tee "$_f"
  else
    svg_to_b64 "$svg" "$w" "$H"
  fi
}

# Choose icon: pie chart of session time elapsed, or an empty ring when there is
# no open window to measure -- either no session data at all (before anything has
# reported) or a window that has rolled over, which zeroed PIE_PCT above.
ICON_B64=""
if [ -n "$PIE_PCT" ]; then
  ICON_B64="$(generate_pie_b64 "$PIE_PCT")"
else
  ICON_B64="$(generate_pie_b64 0)"
fi

# --- Menu bar title ---
TITLE_TEXT="--"
if [ -n "$TITLE_PCT" ]; then
  TITLE_TEXT="${TITLE_PCT}%"
fi

if [ -n "$ICON_B64" ]; then
  echo " ${TITLE_TEXT} | templateImage=${ICON_B64}"
else
  echo "☁ ${TITLE_TEXT}"
fi
echo "---"

# Row suffixes. Data rows are purely informational: no href/bash actions, so macOS
# auto-disables the items and they are neither selectable (no hover highlight) nor
# clickable. $G keeps just a grey color for the footer.
#
# The two section headers that have a page behind them -- Claude and API Cost -- do
# carry an href, so those alone are clickable and highlight on hover. Fable and Codex
# stay inert: Fable has no page of its own, and Codex is a local-file source.
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
    || [ -n "$CODEX_WARN" ] \
    || return
  # A blank row of vertical spacing above the Codex section. SwiftBar collapses
  # truly empty lines, so emit a non-breaking space (U+00A0) to force a full-height
  # row that renders as blank.
  printf '\xc2\xa0\n'
  # Green pill title (rendered as a full-color image; see the Claude header note).
  # A warning to the RIGHT of the pill means the rows below it are not being fed:
  # the pill is an image, so the row's text label lands after it. Hover for why.
  if [ -n "$CODEX_WARN" ]; then
    echo "⚠️ | image=$(generate_label_b64 "Codex" "#16a34a") tooltip=\"$CODEX_WARN\""
  else
    echo " | image=$(generate_label_b64 "Codex" "#16a34a")"
  fi
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
        echo " | image=$(generate_reset_b64 "↻ $codex_rem ( $CODEX_RESET_AT )" volatile) $CX"
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

# --- Claude header ---
# Blue pill title (rendered as a full-color image; SwiftBar can't color a row bg),
# with a warning to the RIGHT of the pill when the payload behind EVERY Claude row
# -- session, weekly, per-model -- is not current. The pill is an image, so the
# row's text label lands after it. Rendered by both the no-data path and the normal
# one so the section is always identifiable, even when it has nothing to show.
CLAUDE_WARN=""
if [ -z "$USAGE_JSON" ]; then
  CLAUDE_WARN="No usage data — see the error below"
elif [ "$USAGE_AGE" -ge "$USAGE_TTL" ]; then
  # Past the TTL means a fetch was attempted and failed, so these are cached
  # numbers being replayed rather than anything current.
  CLAUDE_WARN="Not updating — showing a cached snapshot from $(fmt_age "$USAGE_AGE")"
elif [ -z "$PUSHED_USAGE" ]; then
  # Nothing was pushed within USAGE_PUSH_MAX, so the extension's once-a-minute
  # poll is not landing and these numbers came from the plugin's own 5-minute
  # OAuth fallback. The data is not WRONG, just up to five minutes behind, which
  # is invisible without saying so.
  #
  # Keyed on the SOURCE, not on age: the fallback resets the age to 0 every time
  # it fetches, so an age test would blink the warning off every 5 minutes while
  # minute polling stayed just as broken.
  CLAUDE_WARN="Minute polling is down — updating every 5 min via the API fallback instead of every 60s"
fi
render_claude_header() {
  local img
  img=$(generate_label_b64 "Claude" "#3b82f6")
  local href='href="https://claude.ai/new#settings/usage"'
  if [ -n "$CLAUDE_WARN" ]; then
    echo "⚠️ | image=$img $href tooltip=\"$CLAUDE_WARN\""
  else
    echo " | image=$img $href"
  fi
}

if [ -z "$USAGE_JSON" ]; then
  # Only reached when the fetch failed AND there was no usable cached payload.
  render_claude_header
  if [ -z "$TOKEN" ]; then
    echo "No Claude Code credentials in keychain | color=red"
  elif [ "$HTTP_CODE" = "429" ]; then
    echo "Usage API rate-limited — will retry | color=red"
  elif [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
    echo "Usage API error (HTTP $HTTP_CODE) | color=red"
  else
    echo "Could not reach the usage API | color=red"
  fi
  render_codex
  exit 0
fi

# --- Claude block ---
# Grey header line (no action), then white data rows. The reset time is always the
# absolute one computed from the API timestamp; there is no scraped-text fallback.
SESSION_HEADER_RESET="$SESSION_RESET_AT"
render_claude_header
if [ -n "$SESSION_PCT" ]; then
  echo "${SESSION_PCT}% | image=$(generate_bar_b64 "$SESSION_PCT" "#3b82f6") size=12 $C"
fi
# Reset row: reload glyph, time, and live remaining, dimmed to 50% opacity.
if [ -n "$SESSION_HEADER_RESET" ]; then
  reset_time="$SESSION_HEADER_RESET"
  rem=$(fmt_remaining "$RESET_EPOCH")
  if [ -n "$rem" ]; then
    echo " | image=$(generate_reset_b64 "↻ $rem ( $reset_time )" volatile) $C"
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
if [ -n "$WEEKLY_RESET_EPOCH" ]; then
  weekly_reset_time=$(date -r "$WEEKLY_RESET_EPOCH" +"%a %-I:%M %p" 2>/dev/null)
  [ -n "$weekly_reset_time" ] && \
    echo " | image=$(generate_reset_b64 "↻ $weekly_reset_time") $C"
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
# One row per SERVICE (Claude, Gemini, ...), never per model. COST_SERVICES arrives
# as "claude=101.42;gemini=5" so a new provider appears here automatically once
# something POSTs its key -- no change needed in this file.
if [ -n "$COST_SERVICES" ]; then
  # A blank spacer row above the API Cost section (non-breaking space; see note
  # in render_codex).
  printf '\xc2\xa0\n'
  # Orange pill title (full-color image; see the Claude header note).
  echo " | image=$(generate_label_b64 "API Cost" "#f97316") href=\"https://platform.claude.com/workspaces/default/cost\""
  _old_ifs="$IFS"; IFS=';'
  for _svc in $COST_SERVICES; do
    _name="${_svc%%=*}"
    _val="${_svc#*=}"
    # Service keys are lowercase by convention. Capitalising the first letter is
    # right for most of them ("claude" -> "Claude"), but not for names with
    # internal capitals, so those get an explicit spelling.
    case "$_name" in
      openai) _label="OpenAI" ;;
      *)      _label="$(printf '%s' "${_name:0:1}" | tr '[:lower:]' '[:upper:]')${_name:1}" ;;
    esac
    # A warning to the LEFT of the label when THIS provider's scraper has stopped
    # reporting. Each service is scraped independently, so one going dark (tab
    # closed, logged out, page markup moved) leaves a stale figure sitting next to
    # two live ones with nothing to distinguish them. The age is per service --
    # a single global timestamp could not tell them apart.
    _age=$(cost_age "$_name")
    _warn=""
    if [ -z "$_age" ]; then
      _warn="Never updated — nothing has been received for $_label"
    elif [ "$_age" -ge "$COST_STALE_MAX" ] 2>/dev/null; then
      _warn="Not updating — last figure received $(fmt_age "$_age")"
    fi
    # Google reports Gemini spend on a delay of up to 24h, so this row can read
    # $0.00 while spend is actually accruing. Say so on hover rather than letting
    # the number quietly mislead. A tooltip adds no action, so the row stays inert.
    _note=""
    [ "$_name" = "gemini" ] && \
      _note="Google reports Gemini spend with up to 24h delay"
    _tip=""
    if [ -n "$_warn" ] && [ -n "$_note" ]; then
      _tip=" tooltip=\"$_warn. $_note\""
    elif [ -n "$_warn" ]; then
      _tip=" tooltip=\"$_warn\""
    elif [ -n "$_note" ]; then
      _tip=" tooltip=\"$_note\""
    fi
    [ -n "$_warn" ] && _label="⚠️ $_label"
    echo "${_label}: $(fmt_usd "$_val") | $CC$_tip"
  done
  IFS="$_old_ifs"
fi

# Footer reports the age of the CLAUDE USAGE payload, always and only. That is the
# headline number -- the one the menu bar itself shows -- so a single unqualified
# "Last Updated" has to mean that or nothing.
#
# It used to fall through to the cost scrape age whenever usage happened to be
# fetched live on this render, so the same label silently described two different
# sources with no way to tell which. Cost freshness is now carried per service by
# the warning on each API Cost row, which is strictly better: one number could
# never say WHICH provider had gone quiet.
FOOTER=""
if [ "$USAGE_AGE" -ge "$USAGE_TTL" ]; then
  # Older than the refresh interval => a fetch was attempted and failed. Mark it,
  # so a degraded menu is visibly different from one inside its normal TTL.
  FOOTER="Last Updated: $(fmt_age "$USAGE_AGE") (cached)"
else
  # Either fetched live on this render (age 0) or normal in-TTL reuse.
  FOOTER="Last Updated: $(fmt_age "$USAGE_AGE")"
fi
if [ -n "$FOOTER" ]; then
  echo "---"
  echo "$FOOTER | $G"
fi

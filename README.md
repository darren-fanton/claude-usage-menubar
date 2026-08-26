# Claude Usage Menu Bar

Surfaces your Claude session and weekly usage limits in your macOS menu bar.

```
extension content scripts ──POST──▶ localhost:7823 ──GET──▶ SwiftBar
  usage.js   → plan usage, any claude.ai tab, 60s                 (bash plugin)
  cost.js    → Claude console spend                                    │
  openai.js  → OpenAI project spend                                    │
  gemini.js  → Gemini billing cost                                     │
                                                                       │
Claude OAuth usage API ───────────GET (fallback, ≤1 per 5 min)─────────┘
```

**Usage numbers** have two sources, and the plugin prefers whichever is fresher:

1. **`usage.js`** runs in any open claude.ai tab and calls claude.ai's own
   cookie-authenticated `/api/organizations/<org>/usage` — the exact endpoint the
   Settings → Usage page hits when you press its Refresh button — once a minute, POSTing
   the result to the local server. **This is the only way to get per-minute updates.**
2. **The OAuth API** (`api.anthropic.com/api/oauth/usage`) is the fallback for when no
   claude.ai tab is open. It needs no browser at all, authenticating with Claude Code's
   keychain token.

Both return an **identical payload shape**, so the plugin parses either with the same
code. Both give absolute `resets_at` timestamps rather than text like "Resets in 1 hr".

The OAuth endpoint cannot be polled every 60s — it is aggressively rate-limited and
shared with Claude Code and the Claude desktop app. Measured: 0 successes in 7 attempts
at a 60s cadence, and roughly 1 in 3 once traffic settled, i.e. about one call every
three minutes across all consumers. So the plugin only calls it when nothing has pushed
recently and its cache is older than `USAGE_TTL` (default 300s). If a call fails, the
last good payload is served for up to 30 minutes and the footer is marked `(cached)`.

**Practical upshot:** keep any claude.ai tab open and you get 60s updates. Close them all
and it degrades to ~5-minute updates rather than breaking.

**API cost figures** come from per-service content scripts, one row per provider:

| Row | Source | Figure |
|---|---|---|
| `Claude:` | `platform.claude.com/cost` | month-to-date total cost (tokens + web search + code execution) |
| `OpenAI:` | `platform.openai.com/settings/*/limits` | current project spend (the `$X` of `$X / $limit`) |
| `Gemini:` | `aistudio.google.com/**/billing` | month-to-date "Total cost" from the "Billing Account Cost for Gemini API" card |

> **Gemini lags.** The billing card itself says "Cost information may take up to 24 hours to
> update", so this row can read `$0.00` while spend is actually accruing. The row carries a
> tooltip saying so. When the card can't be read at all the scraper posts *nothing* rather
> than a zero — "not reported yet" and "you spent nothing" must not look alike — and the
> row's per-service age stops advancing, which is what raises the ⚠️.

A service may post `null` to mean "no figure yet"; that renders as `-`. Posting `0` means a
real zero. The distinction matters for any provider whose billing reports on a delay.

Both scrape the rendered page — neither console exposes a JSON endpoint a content script
can call directly. Each posts only its own key, and the server merges the `cost` object
per service, so one provider updating never wipes another's figure. Those tabs need to
stay open, and the extension reloads each of them every 10 minutes. None of the three
pages repaints its figure after load, and a tab Chromium has frozen runs no scrape timer
at all, so on a backgrounded browser the reload cycle is what actually produces each
row's number.

The extension and the local server are optional: without them the menu bar still works
from the OAuth API alone, just at ~5-minute resolution and with no API Cost rows.

> **Note:** the usage endpoint is internal and undocumented (its payload carries
> codenamed fields), so it may change without notice.

---

## Prerequisites

- macOS
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- [Claude Code](https://claude.com/claude-code), logged in — the plugin reads its OAuth token from the keychain (service `Claude Code-credentials`) to call the usage API.
- `python3` (ships with macOS) — used to parse the API payload.

Needed for per-minute usage updates and the optional **API Cost** rows:

- [Node.js](https://nodejs.org) (any modern version; only the standard library is used)
- Google Chrome (or any Chromium-based browser that supports MV3 unpacked extensions)
- **For the crisp vector pie-chart icon:** `librsvg` and `imagemagick` (both via Homebrew: `brew install librsvg imagemagick`). Without `librsvg`, the script falls back to a slightly fuzzier 14×14 raster icon.
- **Strongly recommended:** `pngquant` (`brew install pngquant`) — halves the size of every menu image. SwiftBar retains each bitmap it is handed for the life of the process, so the payload per refresh is what eventually degrades the display (see [Why SwiftBar gets restarted](#why-swiftbar-gets-restarted)). Without it the menu looks identical, just twice as heavy.

---

## 1. Install the Node.js server

The server listens on `127.0.0.1:7823`, persists the most recent payload to `~/Library/Application Support/claude-usage-menubar/state.json`, and exposes `GET /usage` and `POST /usage`.

```bash
cd ~/Projects/claude-usage-menubar/server

# Sanity check
node server.js
# -> claude-usage server on :7823
# Ctrl-C to stop, then install as a LaunchAgent below.
```

### Auto-start at login

```bash
# 1. Find your real node binary path
which node
# e.g. /opt/homebrew/bin/node  or  /usr/local/bin/node

# 2. Materialize the plist with absolute paths and copy it in place
SERVER_PATH="$HOME/Projects/claude-usage-menubar/server/server.js"
NODE_PATH="$(which node)"

sed -e "s|__SERVER_PATH__|$SERVER_PATH|" \
    -e "s|__HOME__|$HOME|" \
    "$HOME/Projects/claude-usage-menubar/server/io.claude-usage.server.plist" \
  | sed -e "s|/usr/local/bin/node|$NODE_PATH|" \
  > ~/Library/LaunchAgents/io.claude-usage.server.plist

# 3. Load it
launchctl unload ~/Library/LaunchAgents/io.claude-usage.server.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/io.claude-usage.server.plist

# 4. Verify
curl -s http://localhost:7823/usage
# -> {} until the extension reports
```

Logs land at `~/Library/Logs/claude-usage-server.log`.

To uninstall: `launchctl unload ~/Library/LaunchAgents/io.claude-usage.server.plist && rm ~/Library/LaunchAgents/io.claude-usage.server.plist`.

---

## 2. Install the Chrome extension (needed for 60s updates)

Skip only if ~5-minute usage updates are fine and you don't want the API Cost rows.

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top right).
3. Click **Load unpacked** and select the `extension/` folder.
4. Keep **any** claude.ai tab open — `usage.js` pushes plan usage from there every 60s.
   It does not have to be the usage settings page; any claude.ai page works.
5. For the API Cost rows, leave open whichever provider pages you want rows for:
   - <https://platform.claude.com/cost> → `Claude:`
   - `https://platform.openai.com/settings/<project>/limits` → `OpenAI:`
   - `https://aistudio.google.com/u/<n>/billing` → `Gemini:`

`usage.js` calls claude.ai's own `/api/organizations/<org>/usage` and POSTs the JSON
verbatim. With several claude.ai tabs open, a `localStorage` lease elects a single poller
so it stays at one request per minute in total, not one per tab.

`cost.js` posts `cost.claude`, `openai.js` posts `cost.openai`, `gemini.js` posts
`cost.gemini` — each only its own key.

`background.js` reloads every scraped tab except `claude.ai` on a 10-minute alarm. Three
things depend on it: the figures only change at load; a page left open long enough drifts
into a state the scrape cannot read, after which that scraper posts nothing at all and the
row is flagged; and a tab Chromium has frozen runs no scrape timer until something resumes
it — on a backgrounded browser a reloaded tab posts once and then goes quiet, so the
10-minute cycle is the reporting cadence and the 15-minute staleness threshold is the
margin around it.

Each scraper stores its timer ids on a per-tab registry rather than an "already ran" flag,
so the re-injection `background.js` performs on extension reload replaces the previous
timer instead of deferring to one whose extension context has just been torn down. That
re-injection is followed by a reload of the provider tabs, because injecting into a frozen
tab delivers the script without running it.

Verify:

```bash
curl -s http://localhost:7823/usage | jq
```

You should see a `usage` object with a recent `usageUpdatedAt` (from `usage.js`) and, if
you opened the console tab, a `cost` object:

```bash
curl -s http://localhost:7823/usage \
  | jq '{sessionPct: .usage.five_hour.utilization,
         pushedSecondsAgo: (now - (.usageUpdatedAt / 1000) | floor),
         cost}'
```

`pushedSecondsAgo` should stay under 60. If it climbs past ~150 the plugin stops trusting
the push and falls back to the OAuth API — check that a claude.ai tab is actually open.

To exercise the fallback path directly:

```bash
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
curl -s -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-cli/2.1.227 (external, cli)"
```

A `429` here is normal and expected — it is why `usage.js` exists.

---

## 3. Install the SwiftBar plugin

```bash
# 1. Find your SwiftBar plugin folder (SwiftBar → Preferences → Plugin Folder)
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"   # default
mkdir -p "$PLUGIN_DIR"

# 2. Symlink the script (so edits propagate without copying)
ln -sf "$HOME/Projects/claude-usage-menubar/swiftbar/claude-usage.60s.sh" \
       "$PLUGIN_DIR/claude-usage.60s.sh"

# 3. Refresh SwiftBar (menu bar → SwiftBar → Refresh All)
```

The filename's `.60s.` suffix tells SwiftBar to re-run it every 60 seconds.

### Why SwiftBar gets restarted

SwiftBar 2.0.1 never releases the bitmaps a plugin hands it. Every refresh's images are retained for the life of the process, so a 60s cadence accumulates them until WindowServer's compositing cost climbs and the whole display starts to stutter — in other apps, not just the menu bar.

Measured on this plugin, at one refresh per second with byte-identical output each time:

| menu payload | WindowServer CPU over 360 refreshes | SwiftBar RSS |
| --- | --- | --- |
| 11 images, 27.7 KB | 48.5% → 68.5% | 57 → 74 MB |
| menu-bar pie only | 45.8% → 45.2% (flat) | 58 → 60 MB |
| no images at all | 47.2% → 45.8% (flat) | 59 → 67 MB |

Two things keep it in check:

1. **`png_quantize` in the plugin** palette-quantizes every image, halving the payload (27.7 KB → ~14 KB per refresh) at 0.2% RMSE from the truecolour original. It uses `pngquant` rather than ImageMagick's `PNG8` because `PNG8` collapses alpha to binary — 234 alpha levels → 1 on a reset caption — which destroys the text antialiasing and the bar's translucent track.
2. **A LaunchAgent restarts SwiftBar every 4 hours**, dropping the retained pile (~2.5 MB by then) at once.

```bash
RESTART_SCRIPT="$HOME/Projects/claude-usage-menubar/swiftbar/restart-swiftbar.sh"

sed -e "s|__RESTART_SCRIPT_PATH__|$RESTART_SCRIPT|" \
    -e "s|__HOME__|$HOME|g" \
    "$HOME/Projects/claude-usage-menubar/swiftbar/io.claude-usage.swiftbar-restart.plist" \
  > ~/Library/LaunchAgents/io.claude-usage.swiftbar-restart.plist

launchctl bootout   gui/$UID/io.claude-usage.swiftbar-restart 2>/dev/null
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.claude-usage.swiftbar-restart.plist

# Prove it actually fires, rather than trusting a clean exit
launchctl kickstart gui/$UID/io.claude-usage.swiftbar-restart
```

The restart is a no-op when SwiftBar isn't running, so quitting it stays a deliberate act — the timer won't resurrect it. Logs land at `~/Library/Logs/claude-usage-swiftbar-restart.log`.

To uninstall: `launchctl bootout gui/$UID/io.claude-usage.swiftbar-restart && rm ~/Library/LaunchAgents/io.claude-usage.swiftbar-restart.plist`.

### What you'll see

**Menu bar:** a pie-chart icon showing elapsed session time, plus the session percent
(`24%`), or `--` if there is no data yet.

**Dropdown** (section headers render as colored pills, usage rows as bars):

```
Claude
24%                      ← 5-hour session
↻ 1h 21m ( 2:00 PM )
7%                       ← weekly, all models
↻ Tue 1:00 AM

Fable
6%

Codex
0%
↻ 4h 12m ( 5:31 PM )

API Cost
Claude: $101.42
---
Last Updated: 2 min ago
```

Per-model weekly rows (Sonnet, Opus, Design) appear automatically when the API reports
them.

**API Cost is one row per service, never per model.** The renderer emits a row for every
numeric key it finds under `cost` in the local server payload, sorted by name, so adding
another provider needs no code change here — just POST it:

```bash
curl -X POST localhost:7823/usage -H 'Content-Type: application/json' \
  -d '{"cost":{"gemini":37.50},"updatedAt":'"$(date +%s)"'000}'
```

That renders a new row alongside `Claude:`, `OpenAI:` and `Gemini:`. The server merges `cost`
one level deep, so each writer posts only its own key and leaves the others intact.
Names get title-case automatically; add an entry to the `case` in the renderer for one
with internal capitals (that is how `openai` becomes `OpenAI`).

### What "Last Updated" refers to

| Footer | Meaning |
|---|---|
| *(absent)* | Usage was just fetched and there is no cost data. Nothing is stale. |
| `Last Updated: N min ago` | Usage is live; `N` is the age of the **scraped cost** figure. |
| `Last Updated: N min ago` (usage in-TTL) | Usage is `N` minutes old — reused from cache within its normal refresh interval. |
| `Last Updated: N min ago (cached)` | A fetch was **attempted and failed**; usage is `N` minutes old and degraded. |

The `(cached)` suffix is the signal that something is wrong. Without it, the menu is
operating normally.

---

## Project layout

```
claude-usage-menubar/
├── README.md
├── extension/                          # 60s usage pushes + API Cost rows
│   ├── manifest.json
│   ├── background.js                   # retrofits scripts into already-open tabs
│   ├── usage.js                        # pushes plan usage from any claude.ai tab
│   ├── cost.js                         # scrapes platform.claude.com spend
│   ├── openai.js                       # scrapes platform.openai.com project spend
│   └── gemini.js                       # scrapes AI Studio billing cost
├── server/
│   ├── server.js
│   └── io.claude-usage.server.plist    # template — see install steps
└── swiftbar/
    ├── claude-usage.60s.sh             # menu bar plugin; calls the usage API
    ├── restart-swiftbar.sh             # 4h restart; frees SwiftBar's retained images
    └── io.claude-usage.swiftbar-restart.plist   # template — see install steps
```

---

## Troubleshooting

- **"No Claude Code credentials in keychain"** — the plugin couldn't read the OAuth token. Confirm Claude Code is logged in and that `security find-generic-password -s "Claude Code-credentials" -w` returns JSON.
- **"Could not reach the usage API"** — the token was found but the call failed. Most often the token expired and Claude Code hasn't refreshed it yet; run any Claude Code command and it renews. Reproduce with the `curl` in §2.
- **Usage percentages are right but API Cost rows are missing** — that's the extension half. Check the server (`curl http://localhost:7823/usage`) and that a `platform.claude.com/cost` tab is open. Note the payload must use per-service keys (`cost.claude`); the older `cost.totalUSD` shape is ignored.
- **Footer stuck on `(cached)`** — the usage API keeps failing. Usually HTTP 429 from too many calls; raise `USAGE_TTL` in the plugin. Check the live status with the `curl` in §2.
- **A provider row never appears** — its content script probably isn't running in that tab. `background.js` retrofits scripts into already-open tabs on reload, so a plain extension reload should be enough; if a row is still missing, reload that tab and check `chrome://extensions` for errors on the service worker.
- **Removing a content script doesn't stop it** — Chromium leaves already-injected scripts running in open tabs, orphaned, until those tabs reload. `background.js` can add scripts to open tabs but cannot remove them.
- **Extension can't reach localhost** — verify `host_permissions` includes `http://localhost:7823/*` in `manifest.json` and that you reloaded the extension after editing.
- **Server won't start as LaunchAgent** — check `~/Library/Logs/claude-usage-server.log`. Most often the `node` path in the plist is wrong; rerun the `sed` step from §1.

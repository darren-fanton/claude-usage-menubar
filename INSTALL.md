# Install — for Claude Code

> **Hi Claude.** Your user wants you to install this project on their macOS machine. Read through everything before you start so you understand the moving parts, then walk the user through it step by step. Do not run installation commands silently — narrate each step so the user knows what's happening on their machine. Stop and ask the user before any irreversible step (loading a LaunchAgent, editing files outside this folder, installing system packages, etc.).

## What this is

Surfaces Claude session and weekly usage limits (and optional Anthropic API costs) in the macOS menu bar via [SwiftBar](https://github.com/swiftbar/SwiftBar).

```
extension content scripts ──POST──▶ localhost:7823 ──GET──▶ SwiftBar
  usage.js   → plan usage, any claude.ai tab, 60s                 (bash plugin)
  cost.js    → Claude console spend                                    │
  openai.js  → OpenAI project spend                                    │
  gemini.js  → Gemini billing cost                                     │
                                                                       │
Claude OAuth usage API ───────────GET (fallback, ≤1 per 5 min)─────────┘
```

**Usage** has two sources. `usage.js` runs in any open claude.ai tab and calls claude.ai's
own `/api/organizations/<org>/usage` every 60s — this is the only way to get per-minute
updates. The OAuth API (`api.anthropic.com`, Claude Code's keychain token) is the fallback
when no tab is open; it is rate-limited to roughly one call every three minutes across all
consumers, so it cannot drive a 60s cadence on its own. Both return the same payload shape.

**API cost** is one row per service, scraped by a content script per provider:
`cost.js` from the Claude console, `openai.js` from the OpenAI project Limits page,
`gemini.js` from the Google AI Studio Billing page (which Google updates up to 24h late). Each
posts only its own key and the server merges `cost` per service, so providers never
overwrite each other. Neither console exposes a JSON endpoint a content script can call,
so both are DOM scrapes and need their tab left open.

That split matters for install: **the extension and the Node server are needed for
per-minute usage updates and the API Cost rows.** Without them the menu still works from
the OAuth API alone at ~5-minute resolution; in that case only step 3 (the SwiftBar
plugin) is required — skip steps 1 and 2 entirely. Ask the user which they want before
installing anything.

There is one LaunchAgent, and it only keeps the Node server alive. Keeping the scraped
provider tabs reloaded is the extension's own job, on a service-worker alarm.

## Prerequisites — confirm with the user before installing anything

The user must already have, or be willing to install:

- **macOS** (the SwiftBar plugin uses BSD `date`; ImageMagick `magick` and `rsvg-convert` are macOS Homebrew tools).
- **[SwiftBar](https://github.com/swiftbar/SwiftBar)** — open the App Store link or `brew install --cask swiftbar`. The user must launch it once and grant permissions.
- **Claude Code, logged in.** The plugin reads its OAuth token from the keychain. Verify with the command below — it must print JSON, not an error.
- **Recommended for the crisp pie-chart icon**: `librsvg` and `imagemagick` (`brew install librsvg imagemagick`). Without `librsvg`, the script falls back to a fuzzier 14×14 raster icon.
- **Strongly recommended**: `pngquant` (`brew install pngquant`). It halves the size of every menu image. SwiftBar retains each bitmap it is handed for the life of the process, so the payload per refresh is what eventually degrades the display — see Step 3b. Without it the menu is identical, just twice as heavy.

For per-minute usage updates and the optional API Cost rows:

- **Node.js** (any modern version — only the standard library is used). Check with `which node`. If missing, suggest `brew install node` and **wait for confirmation** before running it.
- **A Chromium-based browser** (Chrome, Dia, Arc, Brave) where the user is logged into claude.ai (usage), and the Claude / OpenAI / Google AI Studio consoles (cost rows).

Verify the keychain token is readable:

```bash
security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['claudeAiOauth']; print('token ok, expires', d['expiresAt'])"
```

If that fails, the plugin cannot fetch usage — have the user log in to Claude Code first.

Run a single batched check first:

```bash
which node; which jq; which rsvg-convert; which magick; which pngquant; ls /Applications/SwiftBar.app 2>/dev/null
```

Report what's missing and offer to install it. **Do not install anything without explicit user approval.**

## Where the user wants the project installed

By default, this project lives at `~/Projects/claude-usage-menubar/`. If the user has a different layout, ask them where they want it and substitute that path everywhere below. The two plist templates in `server/` use `__SERVER_PATH__` and `__HOME__` placeholders that you'll materialize with absolute paths at install time, so the project folder can live anywhere — but it must not move after install (paths are baked into the LaunchAgents).

If the project isn't already in place: have the user unzip it to their chosen location, then `cd` into it. Confirm `pwd` looks right before continuing.

## Step 1 — Install the Node server + LaunchAgent

The server listens on `127.0.0.1:7823`, persists the most recent payload to `~/Library/Application Support/claude-usage-menubar/state.json`, and exposes `GET /usage` and `POST /usage`.

```bash
# Sanity check (Ctrl-C after you see the banner)
node "$PWD/server/server.js"
# -> claude-usage server on :7823
```

Then materialize the LaunchAgent plist with absolute paths and load it:

```bash
PROJECT_DIR="$PWD"   # run this from the project root
NODE_PATH="$(which node)"

sed -e "s|__SERVER_PATH__|$PROJECT_DIR/server/server.js|" \
    -e "s|__HOME__|$HOME|" \
    "$PROJECT_DIR/server/io.claude-usage.server.plist" \
  | sed -e "s|/usr/local/bin/node|$NODE_PATH|" \
  > ~/Library/LaunchAgents/io.claude-usage.server.plist

launchctl unload ~/Library/LaunchAgents/io.claude-usage.server.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/io.claude-usage.server.plist

# Verify
curl -s http://localhost:7823/usage
# -> {} until the extension reports
```

Server logs land at `~/Library/Logs/claude-usage-server.log`.

**Uninstall (for reference):** `launchctl unload ~/Library/LaunchAgents/io.claude-usage.server.plist && rm ~/Library/LaunchAgents/io.claude-usage.server.plist`.

## Step 2 — Install the Chrome extension

This is a manual step — you can't load an unpacked extension on the user's behalf. Walk them through it:

1. Open `chrome://extensions` (or the equivalent in Dia/Arc/Brave).
2. Toggle **Developer mode** in the top right.
3. Click **Load unpacked** and select the `extension/` folder inside this project.
4. Open one tab per provider they want a cost row for, and leave each open:
   - <https://platform.claude.com/cost> → `cost.claude`
   - `https://platform.openai.com/settings/<project>/limits` → `cost.openai`
   - <https://aistudio.google.com/u/<n>/billing> → `cost.gemini`

Costs are tracked **per service, one row each** — never broken down by model. Any writer can add a provider by POSTing its own key (`cost.gemini`, …); the menu renders a row per numeric key it finds and needs no change.

Those tabs have to be reloaded periodically or they go quiet: none of the three pages repaints its figure after load, and Chromium freezes background tabs — a frozen tab runs no scrape timer, so on a backgrounded browser each tab posts once about 2s after load and then nothing until the next reload. `background.js` reloads every scraped tab except `claude.ai` on a 10-minute alarm, which is therefore the real reporting cadence, not a safety net behind the 60s page timers. **No LaunchAgent, AppleScript, or Automation permission is involved** — earlier versions drove this from launchd and only ever reloaded the Claude tab.

Note for reloads *of the extension itself*: Chromium only injects content scripts when a page loads, so a newly added script does not reach tabs that are already open. `background.js` handles that — on install, update (which is what an unpacked reload fires) and browser startup it injects each content script into every open tab its patterns match, so reloading the extension is sufficient. The reverse still needs manual work: a script *removed* from the extension keeps running in open tabs until those tabs reload.

There is no longer a claude.ai tab to open — usage comes from the API.

Verify after they've loaded the extension and opened the page:

```bash
curl -s http://localhost:7823/usage | jq
```

Should show a `cost` object within a few seconds. Usage percentages will **not** appear
here; that's expected.

## Step 3 — Install the SwiftBar plugin

```bash
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"   # default
mkdir -p "$PLUGIN_DIR"

# Symlink so future edits to the project propagate without copying
ln -sf "$PROJECT_DIR/swiftbar/claude-usage.60s.sh" \
       "$PLUGIN_DIR/claude-usage.60s.sh"

# Refresh: SwiftBar menu bar icon → Refresh All
```

The filename's `.60s.` suffix tells SwiftBar to re-run it every 60 seconds.

## Step 3b — Install the SwiftBar restart agent

**Do not skip this.** SwiftBar 2.0.1 never releases the bitmaps a plugin hands it: every refresh's images are retained for the life of the process, and at a 60s cadence the pile grows until WindowServer's compositing cost climbs and the whole display starts to stutter — in other apps, not just the menu bar. Quitting SwiftBar clears it instantly, which is the only lever available from outside the app.

Measured at one refresh per second with byte-identical output, WindowServer CPU rose 48.5% → 68.5% over 360 refreshes with the images present, and stayed flat (45.8% → 45.2%) with the dropdown images removed. `pngquant` halves what accumulates; this agent bounds it.

```bash
RESTART_SCRIPT="$PROJECT_DIR/swiftbar/restart-swiftbar.sh"

sed -e "s|__RESTART_SCRIPT_PATH__|$RESTART_SCRIPT|" \
    -e "s|__HOME__|$HOME|g" \
    "$PROJECT_DIR/swiftbar/io.claude-usage.swiftbar-restart.plist" \
  > ~/Library/LaunchAgents/io.claude-usage.swiftbar-restart.plist

launchctl bootout   gui/$UID/io.claude-usage.swiftbar-restart 2>/dev/null
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.claude-usage.swiftbar-restart.plist

# A clean exit is not evidence — kick it and confirm SwiftBar's pid changes
pgrep -x SwiftBar
launchctl kickstart gui/$UID/io.claude-usage.swiftbar-restart
sleep 6; pgrep -x SwiftBar
```

It fires every 4 hours and is a no-op when SwiftBar isn't running, so a deliberate quit stays quit. Logs: `~/Library/Logs/claude-usage-swiftbar-restart.log`.

### What the user will see

**Menu bar:** a small pie chart that empties as the 5-hour session window elapses, plus the session percent (e.g. `19%`). Falls back to `--` if there's no data.

**Dropdown:**

```
Session – Resets at 4:51 PM
All Models: 19% Used
---
Weekly – Resets Tue 1:00 AM
All Models: 49% Used
Sonnet: 39% Used
Opus: 12% Used
Design: 0% Used
---
API Cost – Month to Date
Claude: $101.42
---
Last Updated: 2 min ago
```

(The cost block only appears if the user opened `platform.claude.com/cost` and the cost-scraper script ran.)

## Project layout

```
claude-usage-menubar/
├── INSTALL.md                            # this file
├── README.md                             # original / longform reference
├── extension/
│   ├── manifest.json
│   ├── background.js                     # retrofits scripts into already-open tabs
│   ├── usage.js                          # pushes plan usage from any claude.ai tab
│   ├── openai.js                         # scrapes OpenAI project spend
│   ├── gemini.js                         # scrapes AI Studio billing cost
│   ├── cost.js                           # scrapes console month-to-date spend
│   ├── cost.js                           # scrapes platform.claude.com cost page
│   └── icons/
├── server/
│   ├── server.js                         # the Node server itself
│   └── io.claude-usage.server.plist      # template — see Step 1
└── swiftbar/
    ├── claude-usage.60s.sh               # the menu bar plugin
    ├── restart-swiftbar.sh               # 4h restart; frees retained images
    ├── io.claude-usage.swiftbar-restart.plist   # template — see Step 3b
    ├── icon.svg
    ├── claude-logo-source.png
    ├── menubar-icon.png
    └── menubar-icon.b64
```

## Verification checklist (run end-to-end after install)

```bash
# 1. Server is listening
curl -s -m 2 http://localhost:7823/usage | jq

# 2. LaunchAgents loaded
launchctl list | grep claude-usage

# 3. Server log has the banner
tail -5 ~/Library/Logs/claude-usage-server.log

# 4. SwiftBar plugin renders without errors
bash "$HOME/Library/Application Support/SwiftBar/Plugins/claude-usage.60s.sh" | head -20

# 5. Restart agent is loaded and its interval is 4h
launchctl print gui/$UID/io.claude-usage.swiftbar-restart | grep -E 'program|run interval'

# 6. Images are palette-quantized (PaletteAlpha, not truecolour) and still 144 DPI
rm -f ~/.cache/claude-usage/menu.txt
bash "$HOME/Library/Application Support/SwiftBar/Plugins/claude-usage.60s.sh" \
  | sed -n 's/.*image=\([A-Za-z0-9+/=]*\).*/\1/p' | head -1 | base64 -d \
  | magick identify -format '%[type] %x\n' -
```

## Troubleshooting

- **Menu bar stuck on `--`, or "No Claude Code credentials in keychain"** — the plugin couldn't read the OAuth token. Confirm Claude Code is logged in and rerun the `security find-generic-password` check from Prerequisites.
- **"Could not reach the usage API"** — token found but the call failed, usually an expired token that Claude Code hasn't refreshed yet. Running any Claude Code command renews it. The plugin deliberately never uses the refresh token itself, to avoid racing Claude Code's own session.
- **`curl` returns `{}` indefinitely** — extension can't reach localhost. Check Chrome DevTools → Console on `claude.ai` for `Failed to fetch` errors against `localhost:7823`. Verify the manifest still has `http://localhost:7823/*` in `host_permissions` and reload the extension.
- **Menu bar values flip between two readings** — the user has tabs in two different Claude accounts open, both POSTing. The content script is supposed to skip POSTing when the session bar has no reset countdown, but if both have valid data, the user must close one of the duplicates. Look for incoming POSTs by tailing the server log and watch `state.json` for ~30s to identify the rogue tab.
- **Reset times are wrong / missing** — these now come from the API's absolute `resets_at` timestamps, so a wrong time means either a system clock problem or an API shape change. Inspect the raw payload with the `curl` in README §2.
- **A cost row shows ⚠️ and its figure is frozen** — that provider's scraper has stopped posting, which almost always means its tab is gone, logged out, or routed off the scraped path. Confirm a tab is open at a URL matching that provider's `content_scripts` pattern in `manifest.json`, then check the extension's service worker console for `[claude-usage] reload failed`. The worker reloads those tabs every 10 minutes; the row is flagged after 15.
- **Server LaunchAgent won't start** — check `~/Library/Logs/claude-usage-server.log`. The `node` path baked into the plist may be wrong; rerun the `sed` step from §1 with the correct `which node` output.

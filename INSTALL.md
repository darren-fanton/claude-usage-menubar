# Install — for Claude Code

> **Hi Claude.** Your user wants you to install this project on their macOS machine. Read through everything before you start so you understand the moving parts, then walk the user through it step by step. Do not run installation commands silently — narrate each step so the user knows what's happening on their machine. Stop and ask the user before any irreversible step (loading a LaunchAgent, editing files outside this folder, installing system packages, etc.).

## What this is

A three-piece system that surfaces Claude.ai session and weekly usage limits (and optional Anthropic API costs) in the macOS menu bar via [SwiftBar](https://github.com/swiftbar/SwiftBar).

```
Chrome extension  ──POST──▶  localhost:7823  ──GET──▶  SwiftBar
(scrapes claude.ai)        (Node.js, ~50 LOC)        (bash plugin)
```

Plus two LaunchAgents: one keeps the Node server alive, one auto-reloads the relevant browser tab(s) every 60s so the scrape stays fresh.

## Prerequisites — confirm with the user before installing anything

The user must already have, or be willing to install:

- **macOS** (the SwiftBar plugin uses BSD `date`; ImageMagick `magick` and `rsvg-convert` are macOS Homebrew tools).
- **Node.js** (any modern version — only the standard library is used). Check with `which node`. If missing, suggest `brew install node` and **wait for confirmation** before running it.
- **[SwiftBar](https://github.com/swiftbar/SwiftBar)** — open the App Store link or `brew install --cask swiftbar`. The user must launch it once and grant permissions.
- **A Chromium-based browser** (Chrome, Dia, Arc, Brave) where the user is logged into claude.ai.
- **Recommended**: `jq` (`brew install jq`) — falls back to `python3` automatically if missing.
- **Recommended for the crisp pie-chart icon**: `librsvg` and `imagemagick` (`brew install librsvg imagemagick`). Without `librsvg`, the script falls back to a fuzzier 14×14 raster icon.

Run a single batched check first:

```bash
which node; which jq; which rsvg-convert; which magick; ls /Applications/SwiftBar.app 2>/dev/null
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

## Step 2 — Install the auto-refresh helper + LaunchAgent

This is the AppleScript-driven helper that reloads the user's open `claude.ai/settings/usage` and `platform.claude.com/workspaces/default/cost` tabs every 60s, so the scrape stays fresh. It only touches those two exact URLs — other claude.ai tabs (chats, projects) are left alone.

```bash
mkdir -p "$HOME/.local/bin"
cp "$PROJECT_DIR/swiftbar/refresh-usage.sh" "$HOME/.local/bin/claude-usage-refresh"
chmod +x "$HOME/.local/bin/claude-usage-refresh"

# Materialize the refresh LaunchAgent
sed -e "s|__HOME__|$HOME|g" \
    "$PROJECT_DIR/server/io.claude-usage.refresh.plist" \
  > ~/Library/LaunchAgents/io.claude-usage.refresh.plist

launchctl unload ~/Library/LaunchAgents/io.claude-usage.refresh.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/io.claude-usage.refresh.plist
```

> **Heads up to flag for the user**: the first time the refresh helper runs, macOS will prompt to grant the controlling app (e.g. `osascript`, or whatever spawned launchd) **Automation** permission for Chrome / Dia / Arc / Brave. The prompt may appear silently in **System Settings → Privacy & Security → Automation**. If the menu bar never updates, this is the most likely cause — have the user check that panel and approve.

Refresh logs land at `~/Library/Logs/claude-usage-refresh.log`. To stop auto-reloads (e.g. it's interrupting an open chat): `launchctl unload ~/Library/LaunchAgents/io.claude-usage.refresh.plist`.

## Step 3 — Install the Chrome extension

This is a manual step — you can't load an unpacked extension on the user's behalf. Walk them through it:

1. Open `chrome://extensions` (or the equivalent in Dia/Arc/Brave).
2. Toggle **Developer mode** in the top right.
3. Click **Load unpacked** and select the `extension/` folder inside this project.
4. Open <https://claude.ai/settings/usage> and leave the tab open. The content script scrapes whatever's in the DOM and POSTs to `localhost:7823`.
5. (Optional) For API cost data, also open <https://platform.claude.com/workspaces/default/cost>.

Verify after they've loaded the extension and opened the page:

```bash
curl -s http://localhost:7823/usage | jq
```

Should show real percentages within a few seconds.

The content script:

- Finds `h3` headings starting with **"Plan usage limits"** and **"Weekly limits"**.
- Reads each `[role="progressbar"]`'s `aria-valuenow`.
- Reads the adjacent `span.whitespace-nowrap.text-footnote.text-secondary` for the reset string.
- POSTs every 60s and on DOM mutation (debounced to ≥ 5s).
- Skips POSTing if the session bar is found but has no reset string (defends against accidentally overwriting good data when a different account's tab is also open).

## Step 4 — Install the SwiftBar plugin

```bash
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"   # default
mkdir -p "$PLUGIN_DIR"

# Symlink so future edits to the project propagate without copying
ln -sf "$PROJECT_DIR/swiftbar/claude-usage.30s.sh" \
       "$PLUGIN_DIR/claude-usage.30s.sh"

# Refresh: SwiftBar menu bar icon → Refresh All
```

The filename's `.30s.` suffix tells SwiftBar to re-run it every 30 seconds.

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
All Models: $2.63
Opus: $2.49
Sonnet: $0.10
Haiku: $0.04
---
Last updated: just now
```

(The cost block only appears if the user opened `platform.claude.com/workspaces/default/cost` and the cost-scraper script ran.)

## Project layout

```
claude-usage-menubar/
├── INSTALL.md                            # this file
├── README.md                             # original / longform reference
├── extension/
│   ├── manifest.json
│   ├── content.js                        # scrapes claude.ai usage page
│   ├── cost.js                           # scrapes platform.claude.com cost page
│   └── icons/
├── server/
│   ├── server.js                         # the Node server itself
│   ├── io.claude-usage.server.plist      # template — see Step 1
│   └── io.claude-usage.refresh.plist     # template — see Step 2
└── swiftbar/
    ├── claude-usage.30s.sh               # the menu bar plugin
    ├── refresh-usage.sh                  # auto-reload helper (→ ~/.local/bin/)
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

# 4. Refresh log shows recent activity (after ~1 min)
tail -10 ~/Library/Logs/claude-usage-refresh.log

# 5. SwiftBar plugin renders without errors
bash "$HOME/Library/Application Support/SwiftBar/Plugins/claude-usage.30s.sh" | head -20
```

## Troubleshooting

- **Menu bar stuck on `--`** — the server is up but the extension hasn't reported. Have the user open <https://claude.ai/settings/usage> and check `chrome://extensions` for any errors on the `Claude Usage Reporter` extension.
- **`curl` returns `{}` indefinitely** — extension can't reach localhost. Check Chrome DevTools → Console on `claude.ai` for `Failed to fetch` errors against `localhost:7823`. Verify the manifest still has `http://localhost:7823/*` in `host_permissions` and reload the extension.
- **Menu bar values flip between two readings** — the user has tabs in two different Claude accounts open, both POSTing. The content script is supposed to skip POSTing when the session bar has no reset countdown, but if both have valid data, the user must close one of the duplicates. Look for incoming POSTs by tailing the server log and watch `state.json` for ~30s to identify the rogue tab.
- **Reset times are wrong / missing** — Claude occasionally renames Tailwind classes. Update `RESET_SELECTOR` in `extension/content.js` to match whatever class chain the reset span currently uses.
- **Auto-refresh isn't reloading the tab** — check `~/Library/Logs/claude-usage-refresh.log`. The most common cause is missing **Automation** permission for the browser app under System Settings → Privacy & Security → Automation. Also make sure the user actually has a tab open at exactly `claude.ai/settings/usage` (not, say, `claude.ai/settings`) — the helper only matches the full prefix.
- **Server LaunchAgent won't start** — check `~/Library/Logs/claude-usage-server.log`. The `node` path baked into the plist may be wrong; rerun the `sed` step from §1 with the correct `which node` output.

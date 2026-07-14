# Claude Usage Menu Bar

A tiny three-piece system that surfaces your [Claude.ai](https://claude.ai) session and weekly usage limits in your macOS menu bar.

```
Chrome extension  ──POST──▶  localhost:7823  ──GET──▶  SwiftBar
(scrapes claude.ai)        (Node.js, ~50 LOC)        (bash plugin)
```

The extension scrapes the visible numbers from Claude's settings UI (it does not call any private API), the Node server caches the latest payload, and SwiftBar polls the cache once every 30 seconds.

---

## Prerequisites

- macOS
- [Node.js](https://nodejs.org) (any modern version; only the standard library is used)
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- Google Chrome (or any Chromium-based browser that supports MV3 unpacked extensions)
- `jq` is recommended for the SwiftBar plugin but **not required** — it falls back to `python3` automatically.
- **For the crisp vector pie-chart icon:** `librsvg` and `imagemagick` (both via Homebrew: `brew install librsvg imagemagick`). Without `librsvg`, the script falls back to a slightly fuzzier 14×14 raster icon.

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

## 2. Install the Chrome extension

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top right).
3. Click **Load unpacked** and select the `extension/` folder.
4. Open [claude.ai](https://claude.ai) and navigate to **Settings → Usage** (or wherever the "Plan usage limits" / "Weekly limits" cards are visible). The extension scrapes whatever is currently in the DOM.

The content script:

- Finds the `h3` headed **"Plan usage limits"** and **"Weekly limits"**.
- Reads each `[role="progressbar"]`'s `aria-valuenow`.
- Reads the adjacent `span.whitespace-nowrap.text-footnote.text-secondary` for the reset string.
- POSTs to `http://localhost:7823/usage` every 60 s and on DOM mutation (debounced to ≥ 5 s).

Verify:

```bash
curl -s http://localhost:7823/usage | jq
```

You should see your real percentages.

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

The filename's `.30s.` suffix tells SwiftBar to re-run it every 30 seconds.

### What you'll see

**Menu bar:** `☁ 33%` — current session percent, or `☁ --` if there is no data yet.

**Dropdown:**

```
Session: 33% – Resets in 1 hr 51 min
---
Weekly – All Models: 38% – Resets Tue 12:59 AM
Weekly – Sonnet: 37% – Resets Tue 1:00 AM
Weekly – Design: 0%
---
Last updated: 2 min ago
Open Claude.ai
Refresh
```

---

## Project layout

```
claude-usage-menubar/
├── README.md
├── extension/
│   ├── manifest.json
│   └── content.js
├── server/
│   ├── server.js
│   └── io.claude-usage.server.plist   # template — see install steps
└── swiftbar/
    └── claude-usage.60s.sh
```

---

## Troubleshooting

- **Menu bar shows `☁ --`** — either the server is down (`curl http://localhost:7823/usage`) or the extension hasn't reported yet (open `claude.ai` settings).
- **`curl` returns `{}`** — the extension isn't reaching the server. Check Chrome DevTools → Console on `claude.ai`; look for `Failed to fetch` against `localhost:7823`.
- **Extension can't reach localhost** — verify `host_permissions` includes `http://localhost:7823/*` in `manifest.json` and that you reloaded the extension after editing.
- **Reset strings look wrong** — Claude occasionally renames classes. Update `RESET_SELECTOR` in `extension/content.js`.
- **Server won't start as LaunchAgent** — check `~/Library/Logs/claude-usage-server.log`. Most often the `node` path in the plist is wrong; rerun the `sed` step from §1.

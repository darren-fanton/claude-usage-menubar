#!/usr/bin/env node
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = 7823;
const STATE_FILE = path.join(
  process.env.HOME,
  "Library",
  "Application Support",
  "claude-usage-menubar",
  "state.json"
);

fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });

let state = null;
try {
  state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
} catch {}

function cors(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
}

http
  .createServer((req, res) => {
    cors(res);
    if (req.method === "OPTIONS") return res.writeHead(204).end();

    if (req.method === "GET" && req.url === "/usage") {
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify(state || {}));
    }

    if (req.method === "POST" && req.url === "/usage") {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        try {
          // Shallow-merge top-level keys so different content scripts
          // (claude.ai for usage, platform.claude.com for cost) can each
          // POST a partial payload without clobbering the other's data.
          const incoming = JSON.parse(body);
          const prev = state || {};
          const next = { ...prev, ...incoming };
          // `cost` needs one more level of merging: it is written by several
          // independent scrapers, one per service (cost.claude from the Claude
          // console, cost.openai from the OpenAI dashboard). A top-level merge
          // alone would let whichever posted last replace the whole object and
          // wipe every other service's figure.
          if (incoming.cost && typeof incoming.cost === "object") {
            next.cost = { ...(prev.cost || {}), ...incoming.cost };
          }
          state = next;
          fs.writeFile(STATE_FILE, JSON.stringify(state), () => {});
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end('{"ok":true}');
        } catch {
          res.writeHead(400).end('{"ok":false}');
        }
      });
      return;
    }

    res.writeHead(404).end();
  })
  .listen(PORT, "127.0.0.1", () => console.log(`claude-usage server on :${PORT}`));

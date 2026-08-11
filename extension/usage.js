// Pushes Claude plan usage to the local menu bar server once a minute.
//
// Source is claude.ai's OWN cookie-authenticated usage endpoint --
// /api/organizations/<org>/usage -- which is exactly what Settings > Usage calls
// when you press its Refresh button. Not the DOM, and not the OAuth API.
//
// Why not the OAuth API (api.anthropic.com/api/oauth/usage): it is aggressively
// rate-limited and shared with Claude Code and the Claude desktop app, which poll
// it for their own status. Measured at a 60s cadence it returned HTTP 429 on 7 of
// 7 attempts, and only ~1 in 3 once traffic had settled. It cannot support
// per-minute updates. This endpoint can, because it is the one the web app itself
// uses and it is authenticated by the session cookie we already have here.
//
// Why not scrape the DOM (what the old content.js did): this returns the same
// structured payload the OAuth API does -- identical field names, absolute
// `resets_at` timestamps -- so the menu bar plugin parses it with zero changes,
// and there is no aria-valuenow/class-name fragility to break on a redesign.
//
// Runs on ANY claude.ai page, so no need to keep the usage settings page open.

(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // With several claude.ai tabs open, every one of them would poll. Elect a single
  // poller via a short localStorage lease (shared across same-origin tabs) so we
  // make one request a minute in total, not one per tab.
  const LOCK_KEY = "claude-usage-menubar:poller";
  const ID = Math.random().toString(36).slice(2) + Date.now();
  function claimLease() {
    const now = Date.now();
    try {
      const raw = localStorage.getItem(LOCK_KEY);
      const lease = raw ? JSON.parse(raw) : null;
      // Someone else holds a lease that hasn't gone stale -- stand down this tick.
      if (lease && lease.id !== ID && now - lease.at < POLL_MS * 1.5) return false;
      localStorage.setItem(LOCK_KEY, JSON.stringify({ id: ID, at: now }));
      return true;
    } catch {
      return true; // storage blocked; better to poll than to go silent
    }
  }

  let orgId = null;
  async function getOrgId() {
    if (orgId) return orgId;
    const c = document.cookie
      .split("; ")
      .find((x) => x.startsWith("lastActiveOrg="));
    if (c) {
      orgId = decodeURIComponent(c.split("=")[1]);
      return orgId;
    }
    try {
      const r = await fetch("/api/organizations", { credentials: "include" });
      if (!r.ok) return null;
      const j = await r.json();
      if (Array.isArray(j) && j[0] && j[0].uuid) orgId = j[0].uuid;
    } catch {}
    return orgId;
  }

  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (!claimLease()) return;
    inFlight = true;
    try {
      const id = await getOrgId();
      if (!id) return;
      const r = await fetch(`/api/organizations/${id}/usage`, {
        credentials: "include",
      });
      // 401 after a logout, 429, 5xx -- skip this tick and keep the last good
      // payload on the server rather than clobbering it with junk.
      if (!r.ok) return;
      const usage = await r.json();
      if (!usage || typeof usage !== "object" || !usage.five_hour) return;
      await fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ usage, usageUpdatedAt: Date.now() }),
      });
    } catch (e) {
      // local server down or offline; try again next tick
    } finally {
      inFlight = false;
    }
  }

  send();
  setInterval(send, POLL_MS);
})();

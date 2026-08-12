// Injects the content scripts into tabs that are ALREADY OPEN.
//
// Chromium only injects a content script when a page loads. Reloading an
// extension does not retrofit its scripts into existing tabs -- so after adding
// or changing a script you had to hunt down and reload each provider tab by hand,
// and until you did, that provider silently reported nothing. (The mirror image
// also bites: a content script removed from the extension keeps running in tabs
// that already have it, orphaned, until those tabs reload.)
//
// This runs on install, on update (which is what an unpacked reload fires), and
// at browser startup, and injects each content script into every open tab its own
// manifest patterns match. After this, reloading the extension is genuinely
// sufficient.
//
// The script list is read from the manifest at runtime rather than duplicated
// here, so adding a provider means touching manifest.json only.

async function injectIntoOpenTabs(reason) {
  const { content_scripts: scripts = [] } = chrome.runtime.getManifest();
  let injected = 0;

  for (const cs of scripts) {
    if (!cs.matches || !cs.js) continue;
    let tabs = [];
    try {
      tabs = await chrome.tabs.query({ url: cs.matches });
    } catch (e) {
      // No host permission for these patterns, or an invalid pattern.
      console.warn("[claude-usage] tabs.query failed for", cs.matches, e);
      continue;
    }
    for (const tab of tabs) {
      // Skip tabs we cannot script: no id, discarded/sleeping, or a non-http
      // scheme that slipped through the pattern.
      if (!tab.id || tab.discarded || !/^https?:/.test(tab.url || "")) continue;
      try {
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: cs.js,
        });
        injected++;
      } catch (e) {
        // Injection legitimately fails on some pages (error pages, pre-render,
        // a tab that navigated away mid-loop). Not worth failing the whole run.
        console.warn("[claude-usage] inject failed for tab", tab.id, e);
      }
    }
  }

  console.log(`[claude-usage] ${reason}: injected into ${injected} open tab(s)`);
}

chrome.runtime.onInstalled.addListener((d) => injectIntoOpenTabs(d.reason));
chrome.runtime.onStartup.addListener(() => injectIntoOpenTabs("startup"));

// --- Usage polling ---------------------------------------------------------
//
// The once-a-minute usage poll runs HERE, in the service worker, not in a page.
//
// It used to live in usage.js as a setInterval inside any claude.ai tab. That
// only polls while the tab is awake, and Chromium browsers freeze background
// tabs -- Dia aggressively so. A frozen tab runs no timers, so the poll stopped
// dead for hours at a time while the tab still looked open in the tab strip.
// Measured: one POST on tab load, then silence for 4+ hours. The menu quietly
// fell back to the plugin's own 5-minute OAuth poll, which is the slowest thing
// the plugin can do without tripping that endpoint's rate limit.
//
// chrome.alarms wakes the worker on schedule with no tab involved, awake or
// otherwise, and re-registers across browser restarts. The request carries the
// claude.ai session cookie because the extension holds host permission for the
// origin -- the same cookie auth the content script relied on, minus the page.
const USAGE_ALARM = "claude-usage-poll";
const USAGE_ENDPOINT = "http://localhost:7823/usage";

let orgId = null;
async function getOrgId() {
  if (orgId) return orgId;
  // The content script could read document.cookie; a worker has no document, so
  // ask the cookie store for the same lastActiveOrg value.
  try {
    const c = await chrome.cookies.get({
      url: "https://claude.ai/",
      name: "lastActiveOrg",
    });
    if (c && c.value) return (orgId = decodeURIComponent(c.value));
  } catch {}
  try {
    const r = await fetch("https://claude.ai/api/organizations", {
      credentials: "include",
    });
    if (!r.ok) return null;
    const j = await r.json();
    if (Array.isArray(j) && j[0] && j[0].uuid) orgId = j[0].uuid;
  } catch {}
  return orgId;
}

async function pollUsage() {
  try {
    const id = await getOrgId();
    if (!id) return;
    const r = await fetch(`https://claude.ai/api/organizations/${id}/usage`, {
      credentials: "include",
    });
    // 401 after a logout, 429, 5xx -- skip this tick and keep the last good
    // payload on the server rather than clobbering it with junk. Drop the cached
    // org id so a switched or expired session re-resolves on the next tick.
    if (!r.ok) {
      orgId = null;
      return;
    }
    const usage = await r.json();
    if (!usage || typeof usage !== "object" || !usage.five_hour) return;
    await fetch(USAGE_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // usageSource says which poller produced this. The page timer and this
      // worker can both be live, and when the menu says usage is stale the first
      // question is which one stopped -- a guess is not good enough.
      body: JSON.stringify({
        usage,
        usageUpdatedAt: Date.now(),
        usageSource: "worker",
      }),
    });
  } catch (e) {
    // local server down, or offline; the next alarm tries again
  }
}

// periodInMinutes: 1 is the floor Chrome honours for a released extension, and
// is exactly the cadence we want. Created only when absent: re-creating on every
// worker start would reset the schedule each time the worker is woken.
chrome.alarms.get(USAGE_ALARM).then((a) => {
  if (!a) chrome.alarms.create(USAGE_ALARM, { periodInMinutes: 1 });
});
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === USAGE_ALARM) pollUsage();
});

// Poll immediately on install/update/startup so a fresh browser doesn't sit on
// stale numbers for a minute waiting for the first alarm.
chrome.runtime.onInstalled.addListener(() => pollUsage());
chrome.runtime.onStartup.addListener(() => pollUsage());

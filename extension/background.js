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
// manifest patterns match.
//
// Re-injection only helps if the script actually re-arms on it, which is the other
// half of the story and lives in the scripts themselves: the isolated world -- and
// the registry they guard themselves with -- survives an extension reload, so each
// one has to REPLACE the timer its previous injection left behind rather than see a
// flag already set and bail out. See openai.js.
//
// And injection reaches a frozen tab without running there, so bootstrap() at the
// bottom follows it with a reload of the provider tabs. Those three things together
// are what make reloading the extension genuinely sufficient.
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

// Registered at the bottom of this file, alongside the rest of bootstrap().

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

// --- Claude API spend ------------------------------------------------------
//
// Month-to-date console spend, fetched from the API the billing page itself
// calls, not scraped out of it.
//
// It used to be cost.js, a content script on platform.claude.com/cost reading the
// "Total cost" card. Three problems, all structural. That card is a usage roll-up,
// not the billed figure: measured side by side, /cost said $266.28 while
// settings/billing said "$267.07 spent", and what the account is actually charged
// against its spend limit is what a row headed API Cost should carry. It needed a
// tab parked on that page forever, reloaded every 10 minutes, because the page
// paints its number once at load and a frozen background tab runs no timers. And
// it read the DOM, so every console restyle was an outage nobody noticed until the
// row went stale.
//
// GET /api/organizations/<org>/current_spend answers with the exact number behind
// that sentence, in minor units:
//
//     {"amount":26707,"resets_at":"2026-09-01T00:00:00Z"}
//
// Cookie-authenticated against the console session, same arrangement as the usage
// poll above: no tab, no page, no markup. `resets_at` confirms the calendar-month
// window the API Cost row already assumes; it is not posted because nothing reads
// it yet.
const SPEND_ALARM = "claude-spend-poll";

// Well inside the menu's 15-minute per-service staleness threshold, and slow
// enough not to hammer a billing endpoint for a number that moves in cents.
const SPEND_MINUTES = 5;

// The console org is NOT organizations[0]. An account with both a chat org and an
// API org gets them back in an order that is not ours to choose -- here the chat
// org sorts first, and current_spend on it answers 403, which would have looked
// exactly like a dead session and reported nothing forever. The API org is the one
// carrying the `api` capability, so select on that and let the order fall where it
// likes.
let spendOrgId = null;
async function getSpendOrgId() {
  if (spendOrgId) return spendOrgId;
  try {
    const r = await fetch("https://platform.claude.com/api/organizations", {
      credentials: "include",
    });
    if (!r.ok) return null;
    const orgs = await r.json();
    if (!Array.isArray(orgs)) return null;
    const api = orgs.find((o) => (o.capabilities || []).includes("api"));
    if (api && api.uuid) spendOrgId = api.uuid;
  } catch {}
  return spendOrgId;
}

async function pollSpend() {
  try {
    const id = await getSpendOrgId();
    if (!id) return;
    const r = await fetch(
      `https://platform.claude.com/api/organizations/${id}/current_spend`,
      { credentials: "include" }
    );
    // Logged out, rate-limited, 5xx -- post NOTHING and leave the last good figure
    // standing. The row's per-service stamp then stops advancing and the menu flags
    // it, which is the whole point: a missing figure must never be published as
    // zero, because "not reported" and "spent nothing" read identically otherwise.
    // Drop the cached org so a switched or expired session re-resolves next tick.
    if (!r.ok) {
      spendOrgId = null;
      return;
    }
    const j = await r.json();
    if (!j || typeof j.amount !== "number") return;
    await fetch(USAGE_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // Only our own key; the server merges `cost` per service and stamps arrival
      // per service.
      body: JSON.stringify({
        cost: { claude: j.amount / 100 },
        updatedAt: Date.now(),
      }),
    });
  } catch (e) {
    // local server down, or offline; the next alarm tries again
  }
}

// --- Provider page reloads -------------------------------------------------
//
// The cost scrapers read a number out of a rendered page, and none of those pages
// renders it twice. The OpenAI limits page and AI Studio's billing page each paint
// their figure at load and leave it there, so a tab opened yesterday reports
// yesterday's number today no matter how often the scraper re-reads the DOM. Worse, an SPA left open long enough drifts -- session expiry,
// a re-render into an error state -- and then the scrape finds nothing, the
// scraper posts nothing (deliberately: a missing figure must not be published as
// zero), that service's arrival stamp stops advancing, and the menu flags the row.
// Nothing recovers it, because recovery requires a reload.
//
// A launchd job used to drive this over AppleScript, but only for the Claude cost
// tab -- OpenAI and Gemini were never reloaded at all, and AppleScript needs
// Automation permission per browser to do anything. The worker already knows every
// tab the extension scrapes, so it reloads them itself. Claude spend no longer
// belongs to this loop at all: pollSpend() above calls the console API directly and
// needs no tab to reload.
//
// Reloading is also the only thing that gets these tabs reporting at all. Chromium
// freezes background tabs (Dia aggressively) and a frozen tab runs no setInterval,
// so a scraper's 60s poll stops dead -- the same failure that moved usage polling
// in here. Measured on a backgrounded Dia: each reloaded tab posts once, ~2s after
// load, and then goes silent until the next reload. So this alarm is not a
// safety net behind the page timers; it IS the reporting cadence, and the page
// timers only contribute while a tab happens to be awake.
const RELOAD_ALARM = "provider-page-reload";

// Comfortably under the menu's 15-minute per-service staleness threshold. Because
// a frozen tab reports once per reload and no more, a row's age peaks just above
// this figure -- so the gap between the two is the whole margin, and one skipped
// cycle is exactly the kind of breakage the warning is meant to surface.
const RELOAD_MINUTES = 10;

// Every page the extension scrapes EXCEPT claude.ai: usage comes from the fetch
// above and needs no tab, so reloading claude.ai would buy nothing and throw away
// whatever conversation is open there. Derived from the manifest for the same
// reason injectIntoOpenTabs is -- adding a provider stays a manifest-only change.
function reloadMatches() {
  const { content_scripts: scripts = [] } = chrome.runtime.getManifest();
  return scripts
    .filter((cs) => cs.matches && cs.js && !cs.js.includes("usage.js"))
    .flatMap((cs) => cs.matches);
}

async function reloadProviderPages() {
  const matches = reloadMatches();
  if (!matches.length) return;

  let tabs = [];
  try {
    tabs = await chrome.tabs.query({ url: matches });
  } catch (e) {
    console.warn("[claude-usage] reload query failed for", matches, e);
    return;
  }

  // Every match, including whatever tab is active. An earlier version skipped the
  // active tab of the last-focused window, on the theory that a tab you are looking
  // at is neither frozen nor worth reloading under you. Measured: with Dia in the
  // background its last-focused window still reports focused, so the OpenAI tab --
  // active in that window -- was skipped every cycle and went 20 minutes without
  // reporting while the other two recovered on schedule. A tab that never refreshes
  // is the whole bug; a dashboard blinking every 10 minutes is not, and these three
  // pages hold no form state to lose.
  for (const tab of tabs) {
    if (!tab.id) continue;
    try {
      await chrome.tabs.reload(tab.id);
    } catch (e) {
      // Tab closed or navigated away mid-loop; the next alarm sees the new set.
      console.warn("[claude-usage] reload failed for tab", tab.id, e);
    }
  }
}

// --- Alarms ----------------------------------------------------------------

// periodInMinutes: 1 is the floor Chrome honours for a released extension, and
// is exactly the cadence we want. Created only when absent: re-creating on every
// worker start would reset the schedule each time the worker is woken.
chrome.alarms.get(USAGE_ALARM).then((a) => {
  if (!a) chrome.alarms.create(USAGE_ALARM, { periodInMinutes: 1 });
});
chrome.alarms.get(RELOAD_ALARM).then((a) => {
  if (!a) {
    chrome.alarms.create(RELOAD_ALARM, { periodInMinutes: RELOAD_MINUTES });
  }
});
chrome.alarms.get(SPEND_ALARM).then((a) => {
  if (!a) chrome.alarms.create(SPEND_ALARM, { periodInMinutes: SPEND_MINUTES });
});
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === USAGE_ALARM) pollUsage();
  if (a.name === RELOAD_ALARM) reloadProviderPages();
  if (a.name === SPEND_ALARM) pollSpend();
});

// --- Bootstrap -------------------------------------------------------------

// Runs on install, on update (which is what an unpacked reload fires), and at
// browser startup.
//
// The reload at the end is not redundant with the injection at the start.
// Injecting a script into a FROZEN tab delivers it but does not run it -- nothing
// runs there until the tab is resumed. Measured across an extension reload with
// Dia in the background: the one provider tab that happened to be visible posted
// within 2s of injection, while the two frozen ones stayed silent for the entire
// alarm period. A reload resumes them.
//
// It also realigns the tabs with the alarm. Chrome clears an extension's alarms on
// update, so the alarm recreated above does not fire for a full RELOAD_MINUTES --
// long enough, from a standing start, for a row to cross the staleness threshold
// before its first scheduled reload ever lands.
async function bootstrap(reason) {
  await injectIntoOpenTabs(reason);
  pollUsage();
  pollSpend();
  reloadProviderPages();
}

chrome.runtime.onInstalled.addListener((d) => bootstrap(d.reason));
chrome.runtime.onStartup.addListener(() => bootstrap("startup"));

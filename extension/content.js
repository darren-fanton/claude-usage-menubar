(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;
  // Bump this string whenever the scraper changes so it's obvious in the console
  // which version is actually loaded (i.e. whether the extension was reloaded).
  const VERSION = "aria-3";
  console.log(`[claude-usage] content script loaded (${VERSION})`, location.href);

  // The usage bars expose `aria-valuenow` for the percentage. claude.ai's
  // redesign dropped the explicit role="progressbar", so key off the aria attr.
  const BAR_SELECTOR = "[aria-valuenow]";

  // Map of weekly row labels -> JSON keys
  const WEEKLY_KEY_MAP = {
    "all models": "allModels",
    "sonnet": "sonnet",
    "design": "design",
    "opus": "opus",
    "fable": "fable",
  };

  function findSectionByHeading(headingText) {
    // Match across heading levels -- the redesign no longer guarantees <h3>.
    const headings = Array.from(document.querySelectorAll("h1,h2,h3,h4"));
    const needle = headingText.toLowerCase();
    // Use startsWith so we tolerate trailing badges like "Plan usage limitsMax (20x)".
    const match = headings.find((h) =>
      h.textContent.trim().toLowerCase().startsWith(needle)
    );
    if (!match) return null;
    // Walk up to a reasonable container that holds the usage bars.
    let node = match.parentElement;
    for (let i = 0; i < 6 && node; i++) {
      if (node.querySelector(BAR_SELECTOR)) return node;
      node = node.parentElement;
    }
    return null;
  }

  function readBar(barEl) {
    // aria-valuenow is the percentage when valuemax is 100 (the usual case);
    // normalize against valuemax defensively in case it isn't.
    const now = parseFloat(barEl.getAttribute("aria-valuenow"));
    const max = parseFloat(barEl.getAttribute("aria-valuemax"));
    let pct = null;
    if (Number.isFinite(now)) {
      pct =
        Number.isFinite(max) && max > 0
          ? Math.round((now / max) * 100)
          : Math.round(now);
    }

    // Find a nearby "Resets …" label. class names on claude.ai churn, so match
    // by text content rather than a fragile selector: walk up from the bar and
    // grab the nearest leaf element whose text starts with "Resets".
    let reset = null;
    let scope = barEl.parentElement;
    for (let i = 0; i < 6 && scope && !reset; i++) {
      const el = Array.from(scope.querySelectorAll("*")).find(
        (x) => x.children.length === 0 && /^resets\b/i.test(x.textContent.trim())
      );
      if (el) reset = el.textContent.trim();
      scope = scope.parentElement;
    }
    return { pct, reset };
  }

  function readSession() {
    const section = findSectionByHeading("Plan usage limits");
    if (!section) return null;
    const bar = section.querySelector(BAR_SELECTOR);
    if (!bar) return null;
    return readBar(bar);
  }

  function readWeekly() {
    const section = findSectionByHeading("Weekly limits");
    if (!section) return null;
    const bars = Array.from(section.querySelectorAll(BAR_SELECTOR));
    const out = {};
    for (const bar of bars) {
      // Find the label for this row by walking up to a row container.
      let label = null;
      let scope = bar.parentElement;
      for (let i = 0; i < 6 && scope && !label; i++) {
        // The row usually has a text node before the bar with the model name.
        const text = scope.textContent.toLowerCase();
        for (const key of Object.keys(WEEKLY_KEY_MAP)) {
          if (text.includes(key)) {
            label = key;
            break;
          }
        }
        if (label) break;
        scope = scope.parentElement;
      }
      if (!label) continue;
      const jsonKey = WEEKLY_KEY_MAP[label];
      if (out[jsonKey]) continue; // first match wins (smallest enclosing row)
      out[jsonKey] = readBar(bar);
    }
    return Object.keys(out).length ? out : null;
  }

  // Track the last distinct scrape so `updatedAt` reflects when the usage data
  // actually changed, not merely when we last polled. claude.ai is a SPA: an
  // idle/stale tab keeps the same frozen numbers in the DOM, and re-stamping a
  // fresh timestamp on every poll makes the menu bar perpetually say "just now"
  // while the reset countdown (anchored to updatedAt) slides forward and never
  // expires. Reusing the prior timestamp on unchanged data keeps the reset time
  // anchored to when the data was genuinely captured, so staleness surfaces.
  let lastSig = null;
  let lastUpdatedAt = 0;

  function buildPayload() {
    const session = readSession();
    const weekly = readWeekly();
    if (!session && !weekly) return null;
    // If a session bar is on the page but no reset countdown is in scope,
    // this tab is on a different account or in a transitional render —
    // skip rather than overwrite good data from another tab. EXCEPTION: a
    // genuinely 0%-used session (freshly reset) shows no countdown yet, and we
    // still want to report it so the menu bar updates to 0% instead of showing
    // the prior session's stale numbers.
    if (session && !session.reset && session.pct !== 0) return null;
    const sig = JSON.stringify({ session, weekly });
    if (sig !== lastSig) {
      lastSig = sig;
      lastUpdatedAt = Date.now();
    }
    return {
      session: session || null,
      weekly: weekly || {},
      updatedAt: lastUpdatedAt,
    };
  }

  let lastSent = 0;
  let inFlight = false;
  async function send(force = false) {
    if (inFlight) return;
    const now = Date.now();
    if (!force && now - lastSent < 5_000) return; // debounce mutations
    const payload = buildPayload();
    if (!payload) return;
    inFlight = true;
    try {
      await fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      lastSent = now;
      console.log("[claude-usage] sent", payload.session, payload.weekly);
    } catch (e) {
      console.warn("[claude-usage] POST failed", e);
    } finally {
      inFlight = false;
    }
  }

  // Initial + polling
  send(true);
  setInterval(() => send(true), POLL_MS);

  // DOM mutations -> debounced send. claude.ai is a busy SPA, so the observer
  // fires constantly; invoking send() (which re-scans the DOM) on every batch is
  // wasteful. Coalesce each burst into a single deferred scan with a trailing
  // timer: while a scan is already queued, further mutations are a near-free
  // early return. We also drop characterData (text-level) tracking -- it's the
  // most expensive mode to run across the whole subtree, and the 60s poll above
  // already backstops anything the coarser childList signal misses.
  let debounceTimer = null;
  const obs = new MutationObserver(() => {
    if (debounceTimer) return; // a scan is already queued for this burst
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      send(false);
    }, 1_000);
  });
  obs.observe(document.body, { childList: true, subtree: true });
})();

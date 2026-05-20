(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  const RESET_SELECTOR = "span.whitespace-nowrap.text-footnote.text-secondary";

  // Map of weekly row labels -> JSON keys
  const WEEKLY_KEY_MAP = {
    "all models": "allModels",
    "sonnet": "sonnet",
    "design": "design",
    "opus": "opus",
  };

  function findSectionByHeading(headingText) {
    const headings = Array.from(document.querySelectorAll("h3"));
    const needle = headingText.toLowerCase();
    // Use startsWith so we tolerate trailing badges like "Plan usage limitsMax (5x)".
    const match = headings.find((h) =>
      h.textContent.trim().toLowerCase().startsWith(needle)
    );
    if (!match) return null;
    // Walk up to a reasonable container that holds the progress bars.
    let node = match.parentElement;
    for (let i = 0; i < 6 && node; i++) {
      if (node.querySelector('[role="progressbar"]')) return node;
      node = node.parentElement;
    }
    return null;
  }

  function readBar(barEl) {
    const pctRaw = barEl.getAttribute("aria-valuenow");
    const pct = pctRaw == null ? null : parseInt(pctRaw, 10);

    // Look for a nearby reset label. Among spans matching the reset selector,
    // prefer one whose text mentions "reset" (case-insensitive) so we don't
    // accidentally grab the "39% used" label that shares the same classes.
    let reset = null;
    let scope = barEl.parentElement;
    for (let i = 0; i < 5 && scope && !reset; i++) {
      const spans = Array.from(scope.querySelectorAll(RESET_SELECTOR));
      const resetSpan = spans.find((s) => /reset/i.test(s.textContent));
      if (resetSpan) reset = resetSpan.textContent.trim();
      scope = scope.parentElement;
    }
    return { pct: Number.isFinite(pct) ? pct : null, reset };
  }

  function readSession() {
    const section = findSectionByHeading("Plan usage limits");
    if (!section) return null;
    const bar = section.querySelector('[role="progressbar"]');
    if (!bar) return null;
    return readBar(bar);
  }

  function readWeekly() {
    const section = findSectionByHeading("Weekly limits");
    if (!section) return null;
    const bars = Array.from(section.querySelectorAll('[role="progressbar"]'));
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

  function buildPayload() {
    const session = readSession();
    const weekly = readWeekly();
    if (!session && !weekly) return null;
    // If a session bar is on the page but no reset countdown is in scope,
    // this tab is on a different account or in a transitional render —
    // skip rather than overwrite good data from another tab.
    if (session && !session.reset) return null;
    return {
      session: session || null,
      weekly: weekly || {},
      updatedAt: Date.now(),
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
    } catch (e) {
      // Server likely not running; ignore.
    } finally {
      inFlight = false;
    }
  }

  // Initial + polling
  send(true);
  setInterval(() => send(true), POLL_MS);

  // DOM mutations -> debounced send
  const obs = new MutationObserver(() => send(false));
  obs.observe(document.body, { childList: true, subtree: true, characterData: true });
})();

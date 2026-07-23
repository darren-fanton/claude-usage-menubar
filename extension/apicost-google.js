// Scrapes Google AI Studio spend from aistudio.google.com/.../spend and POSTs
// it as `apiCostGoogle`.
//
// The page shows a current spend and a cap but no ready-made percent, so we
// read both dollar amounts and compute pct = usage / cap. Class hints from the
// live page ("usage" for current spend, "limit" for the cap) may drift, so we
// log what we find and fall back to a whole-page regex scan. Note: this page is
// slow to render its dollar amount, so the MutationObserver below is what
// usually catches it.

(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // Your Google AI Studio monthly budget/cap in dollars. Set it here and we
  // compute % = spend / cap. Leave null to try to scrape a cap from the page.
  const MONTHLY_CAP_USD = null;

  const firstDollar = (t) => {
    const m = (t || "").match(/\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/);
    return m ? parseFloat(m[1].replace(/,/g, "")) : null;
  };

  // Read current spend (usd) and the cap, then derive the percent.
  function scrape() {
    const usageEls = Array.from(document.querySelectorAll('.usage, [class~="usage"]'));
    const limitEls = Array.from(document.querySelectorAll('.limit, [class~="limit"]'));

    let usage = null;
    let cap = null;
    for (const e of usageEls) {
      const d = firstDollar(e.textContent);
      if (d != null) { usage = d; break; }
    }
    for (const e of limitEls) {
      const d = firstDollar(e.textContent);
      if (d != null) { cap = d; break; }
    }

    // Fallback: an explicit "$X / $Y" or "$X of $Y" pair anywhere on the page.
    if (usage == null || cap == null) {
      const m = (document.body.textContent || "").match(
        /\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:\/|of)\s*\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/i
      );
      if (m) {
        if (usage == null) usage = parseFloat(m[1].replace(/,/g, ""));
        if (cap == null) cap = parseFloat(m[2].replace(/,/g, ""));
      }
    }

    // A configured budget wins over any scraped cap.
    if (MONTHLY_CAP_USD != null) cap = MONTHLY_CAP_USD;

    let pct = null;
    if (usage != null && cap != null && cap > 0) {
      pct = Math.round((usage / cap) * 100);
    }
    return { usd: usage, cap, pct };
  }

  function buildPayload() {
    const { usd, cap, pct } = scrape();
    console.log("[claude-usage] google → spend:", usd, "cap:", cap, "pct:", pct);
    if (usd == null && pct == null) return null;
    return { apiCostGoogle: { usd, cap, pct, ts: Date.now() }, updatedAt: Date.now() };
  }

  let lastSent = 0;
  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (Date.now() - lastSent < 5_000) return;
    const payload = buildPayload();
    if (!payload) return;
    inFlight = true;
    try {
      await fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      lastSent = Date.now();
    } catch (e) {
      // server probably down; ignore
    } finally {
      inFlight = false;
    }
  }

  setTimeout(send, 2000);
  setInterval(send, POLL_MS);
  const obs = new MutationObserver(() => send());
  obs.observe(document.body, { childList: true, subtree: true, characterData: true });
})();

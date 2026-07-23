// Scrapes the Claude API spend + budget percent from
// platform.claude.com/settings/billing and POSTs it as `apiCostClaude`.
//
// Anchors (from the live page, may need tuning):
//   $ amount -> class "text-primary font-medium inline-flex gap-2 items-center text-body"
//   percent  -> class "text-secondary whitespace-nowrap text-right text-footnote"
// Falls back to a regex scan of the page if those classes move.

(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // Only run on the billing page; the extension also injects cost.js across
  // platform.claude.com, so bail elsewhere to avoid duplicate work.
  if (!/^\/settings\/billing/.test(location.pathname)) return;

  console.log("[claude-usage] apicost-claude loaded on", location.href);

  const parseMoney = (t) => {
    if (!t) return null;
    const m = t.match(/\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/);
    return m ? parseFloat(m[1].replace(/,/g, "")) : null;
  };
  const parsePct = (t) => {
    if (!t) return null;
    const m = t.match(/([0-9]+(?:\.[0-9]+)?)\s*%/);
    return m ? Math.round(parseFloat(m[1])) : null;
  };

  function readUsd() {
    const el = document.querySelector(
      ".text-primary.font-medium.inline-flex.gap-2.items-center.text-body"
    );
    const fromAnchor = el && parseMoney(el.textContent);
    if (fromAnchor != null) return fromAnchor;
    // Fallback: first dollar amount on the page.
    return parseMoney(document.body.textContent);
  }

  function readPct() {
    const els = document.querySelectorAll(
      ".text-secondary.whitespace-nowrap.text-right.text-footnote"
    );
    for (const el of els) {
      const p = parsePct(el.textContent);
      if (p != null) return p;
    }
    return parsePct(document.body.textContent);
  }

  function buildPayload() {
    const usd = readUsd();
    const pct = readPct();
    console.log("[claude-usage] claude billing scrape → usd:", usd, "pct:", pct);
    if (usd == null && pct == null) return null; // don't clobber good data
    return { apiCostClaude: { usd, pct, ts: Date.now() }, updatedAt: Date.now() };
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

  setTimeout(send, 1500);
  setInterval(send, POLL_MS);
  const obs = new MutationObserver(() => send());
  obs.observe(document.body, { childList: true, subtree: true, characterData: true });
})();

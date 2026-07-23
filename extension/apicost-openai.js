// Scrapes the OpenAI project spend from
// platform.openai.com/settings/proj_.../limits and POSTs it as `apiCostOpenai`.
//
// The page shows a current spend and a cap but no ready-made percent, so we
// read both dollar amounts and compute pct = usage / cap. Class hints from the
// live page ("AKDe9" for the amounts, "-dWeP" nested) are build-hashed and may
// drift, so we log what we find and fall back to a whole-page regex scan.

(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // Your OpenAI monthly budget/cap in dollars. The limits page doesn't expose a
  // clean cap element to scrape, so set it here and we compute % = spend / cap.
  // Leave null to fall back to trying to scrape a cap from the page.
  const MONTHLY_CAP_USD = null;

  const firstDollar = (t) => {
    const m = (t || "").match(/\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/);
    return m ? parseFloat(m[1].replace(/,/g, "")) : null;
  };

  // Read current spend (usd) and the cap, then derive the percent.
  function scrape() {
    const anchors = Array.from(
      document.querySelectorAll('[class~="AKDe9"], [class~="-dWeP"]')
    );

    let usage = null;
    let cap = null;

    // Best signal: an explicit "$X / $Y" or "$X of $Y" usage/limit pair.
    const sources = anchors.map((e) => e.textContent).concat(document.body.textContent);
    for (const t of sources) {
      const m = (t || "").match(
        /\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:\/|of)\s*\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/i
      );
      if (m) {
        usage = parseFloat(m[1].replace(/,/g, ""));
        cap = parseFloat(m[2].replace(/,/g, ""));
        break;
      }
    }

    // Fallback: the first two dollar amounts among the anchors (used, then limit).
    if (usage == null || cap == null) {
      const nums = [];
      for (const e of anchors) {
        const d = firstDollar(e.textContent);
        if (d != null) nums.push(d);
      }
      if (usage == null && nums.length >= 1) usage = nums[0];
      if (cap == null && nums.length >= 2) cap = nums[1];
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
    console.log("[claude-usage] openai → spend:", usd, "cap:", cap, "pct:", pct);
    if (usd == null && pct == null) return null;
    return { apiCostOpenai: { usd, cap, pct, ts: Date.now() }, updatedAt: Date.now() };
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

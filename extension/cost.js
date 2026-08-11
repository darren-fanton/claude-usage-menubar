// Scrapes API workspace cost from platform.claude.com/workspaces/*/cost ONLY.
// Both the manifest match and the onCostPage() guard below enforce that: an
// earlier build matched all of platform.claude.com, so it also ran on /docs/*
// pages and posted numbers parsed out of their Next.js hydration payload.
// Reads the total month-to-date cost from the "Total token cost" card and POSTs it
// as `cost.claude` into the local server payload.
//
// There is deliberately no per-model breakdown. It used to walk the Chart.js donut
// and hover each slice to read tooltips, which was ~100 lines of fragile DOM poking
// for a split nobody wanted. Costs are tracked per SERVICE now, one row per
// provider.

(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // The manifest match only gates the INITIAL injection, and the console is an
  // SPA that can route away from the cost page without a reload. Re-check the
  // path before every scrape so we never read numbers off some other console
  // page and POST them as spend.
  function onCostPage() {
    return /^\/workspaces\/[^/]+\/cost\/?$/.test(location.pathname);
  }

  // -- Total cost ----------------------------------------------------------

  function readTotal() {
    const labels = Array.from(document.querySelectorAll("h1, h2, h3, label"));
    const labelEl = labels.find(
      (el) => el.textContent.trim().toLowerCase() === "total token cost"
    );
    if (!labelEl) return null;
    // Walk up to a sibling/parent that holds the dollar value.
    let scope = labelEl.parentElement;
    for (let i = 0; i < 3 && scope; i++) {
      const valEl = scope.querySelector(
        ".text-3xl, .text-2xl, .text-4xl, [class*='text-3xl']"
      );
      if (valEl) {
        const m = valEl.textContent.match(/\$([0-9]+(?:\.[0-9]+)?)/);
        if (m) return parseFloat(m[1]);
      }
      scope = scope.parentElement;
    }
    // Fallback: any large $ amount on the page.
    for (const el of document.querySelectorAll(
      ".text-3xl, .text-2xl, .text-4xl"
    )) {
      const m = el.textContent.match(/\$([0-9]+(?:\.[0-9]+)?)/);
      if (m) return parseFloat(m[1]);
    }
    return null;
  }

  // -- Send loop -----------------------------------------------------------

  // The cost block is keyed BY SERVICE, not by model: one total per provider, so
  // adding Gemini (or anything else) later just means another writer putting its
  // own key in here. The menu renders one row per key it finds and needs no change.
  async function buildPayload() {
    const total = readTotal();
    if (total === null) return null;
    return {
      cost: {
        claude: total,
        period: "month-to-date",
      },
      updatedAt: Date.now(),
    };
  }

  let lastSent = 0;
  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (!onCostPage()) return;
    if (Date.now() - lastSent < 5_000) return;
    const payload = await buildPayload();
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

  // Wait for the chart to render, then poll.
  setTimeout(send, 2000);
  setInterval(send, POLL_MS);
})();

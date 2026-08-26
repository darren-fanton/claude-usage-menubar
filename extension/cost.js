// Scrapes API cost from platform.claude.com/cost ONLY. Both the manifest match
// and the onCostPage() guard below enforce that: an earlier build matched all of
// platform.claude.com, so it also ran on /docs/* pages and posted numbers parsed
// out of their Next.js hydration payload.
//
// The console moved this page in Aug 2026: it used to live at
// /workspaces/<id>/cost, which now renders an empty shell -- the heading paints,
// the data never arrives. Cost is org-wide and lives at /cost. The old URL is not
// matched at all, so a tab left open on it stops being scraped rather than being
// reloaded every 10 minutes for nothing.
//
// Reads the month-to-date total from the "Total cost" card and POSTs it as
// `cost.claude` into the local server payload.
//
// There is deliberately no per-model breakdown. It used to walk the Chart.js donut
// and hover each slice to read tooltips, which was ~100 lines of fragile DOM poking
// for a split nobody wanted. Costs are tracked per SERVICE now, one row per
// provider.

(() => {
  // Exactly one live timer per tab, and it must belong to the CURRENT extension
  // context.
  //
  // background.js re-injects into open tabs whenever the extension reloads, and the
  // isolated world -- this registry with it -- outlives that reload; only a page
  // navigation clears it. So a plain "already ran, bail out" flag made every
  // re-injection a no-op, deferring to a timer whose extension context had just
  // been torn down and which could no longer reach the server. Silent by
  // construction: reloading the extension killed this scraper until someone
  // reloaded the tab by hand, and the menu just showed a stale figure.
  //
  // Holding the timer ids instead of a boolean makes re-injection a REPLACEMENT --
  // cancel what the previous injection left running, then arm our own. Still one
  // timer, so the double-POST the old guard existed to prevent stays prevented.
  const _reg = (globalThis.__claudeUsageMenubar ||= {});
  if (_reg.cost) {
    clearTimeout(_reg.cost.first);
    clearInterval(_reg.cost.poll);
  }

  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // The manifest match only gates the INITIAL injection, and the console is an
  // SPA that can route away from the cost page without a reload. Re-check the
  // path before every scrape so we never read numbers off some other console
  // page and POST them as spend.
  function onCostPage() {
    return /^\/cost\/?$/.test(location.pathname);
  }

  // -- Total cost ----------------------------------------------------------

  // Card labels to read, in preference order. "Total cost" is the whole API bill
  // -- tokens plus web search plus code execution -- which is what a single
  // "Claude" row in the menu should say. "Total token cost" is the fallback for a
  // layout that offers no combined figure; it under-reports by whatever the
  // non-token lines come to.
  const TOTAL_LABELS = ["total cost", "total token cost"];

  // An element's visible label, with nested controls stripped. Each card heading
  // wraps an info button whose accessible text ("More info about total cost")
  // otherwise lands in textContent and defeats an equality match.
  function labelText(el) {
    if (el.children.length > 2) return "";
    const clone = el.cloneNode(true);
    clone
      .querySelectorAll("button, [aria-hidden='true'], .sr-only")
      .forEach((n) => n.remove());
    return clone.textContent.trim().replace(/\s+/g, " ").toLowerCase();
  }

  // Find the card labelled `label` and read the dollar figure out of it.
  //
  // Deliberately class-free. The previous version keyed on Tailwind size classes
  // (.text-3xl and friends) to find the value; the console's Aug 2026 redesign
  // renamed every one of them, readTotal() returned null, and -- because a missing
  // figure is deliberately never posted as zero -- the row simply stopped
  // updating. It went unnoticed for nine days. Anchoring on the visible label and
  // then taking the first currency-shaped leaf inside its card survives a
  // restyle, which is the only thing about these pages that is predictable.
  function readLabelled(label) {
    // EVERY element whose visible text is the label, not just the first: the page
    // carries more than one node reading "Total cost" (the card heading, and text
    // inside the card's info popover), and only one of them sits in a card with a
    // figure. Committing to the first match and returning null when it yields
    // nothing is what made this silently read the token subtotal instead of the
    // combined total.
    const candidates = Array.from(
      document.querySelectorAll("h1, h2, h3, h4, label, div, span")
    ).filter((el) => labelText(el) === label);

    for (const labelEl of candidates) {
      // Widen from the label to its card, stopping at the first currency leaf.
      let scope = labelEl.parentElement;
      for (let i = 0; i < 4 && scope; i++) {
        for (const el of scope.querySelectorAll("*")) {
          if (el.children.length) continue;
          const m = el.textContent.trim().match(/^\$([0-9,]+(?:\.[0-9]+)?)$/);
          if (m) return parseFloat(m[1].replace(/,/g, ""));
        }
        scope = scope.parentElement;
      }
    }
    return null;
  }

  function readTotal() {
    for (const label of TOTAL_LABELS) {
      const v = readLabelled(label);
      if (v !== null) return v;
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
  _reg.cost = {
    first: setTimeout(send, 2000),
    poll: setInterval(send, POLL_MS),
  };
})();

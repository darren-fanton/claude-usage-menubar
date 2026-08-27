// Scrapes current OpenAI project spend from the project Limits page and POSTs it
// as `cost.openai` into the local menu bar server.
//
// The page shows "Project spend limit ... $0.16 / $200.00" -- spent over the
// period, then the cap. We report the SPENT figure, so it lines up with the
// Claude console's month-to-date total in the same API Cost list.
//
// Deliberately NOT the "Credits $31.21" figure in the header: that is remaining
// prepaid balance, not spend, and mixing the two in one list would be nonsense.
//
// This is a DOM scrape rather than an API call, unlike usage.js. The dashboard's
// own JSON endpoints (/v1/dashboard/organization/costs and friends) need auth
// headers the page supplies internally; fetching them from here just returns the
// SPA's HTML shell. The Limits page is expected to stay open anyway.

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
  if (_reg.openai) {
    clearTimeout(_reg.openai.first);
    clearInterval(_reg.openai.poll);
  }

  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // "$0.16 / $200.00" -> [spent, limit]
  const PAIR = /\$\s*([\d,]+(?:\.\d+)?)\s*\/\s*\$\s*([\d,]+(?:\.\d+)?)/;
  const num = (s) => parseFloat(s.replace(/,/g, ""));

  // platform.openai.com is an SPA and can route between settings pages without a
  // reload, so re-check the path every tick rather than trusting the injection.
  function onLimitsPage() {
    return /^\/settings\/[^/]+\/limits\/?$/.test(location.pathname);
  }

  function readProjectSpend() {
    // Anchor on the section heading, then look for the "$spent / $limit" pair
    // within a few levels of it.
    const els = document.querySelectorAll("h1,h2,h3,h4,label,div,span");
    let head = null;
    for (const e of els) {
      if (e.textContent.trim().toLowerCase() === "project spend limit") {
        head = e;
        break;
      }
    }
    let scope = head ? head.parentElement : null;
    for (let i = 0; i < 6 && scope; i++) {
      const m = scope.textContent.match(PAIR);
      if (m) return num(m[1]);
      scope = scope.parentElement;
    }
    // Fallback: a lone "$X / $Y" leaf node is distinctive enough on this page.
    for (const el of document.querySelectorAll("div,span,p")) {
      if (el.children.length) continue;
      const m = el.textContent.trim().match(new RegExp("^" + PAIR.source + "$"));
      if (m) return num(m[1]);
    }
    return null;
  }

  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (!onLimitsPage()) return;
    const spent = readProjectSpend();
    // null means the page hasn't rendered yet, or the markup moved. Skip rather
    // than posting a zero and making the menu claim spend dropped to nothing.
    if (spent === null || !Number.isFinite(spent)) return;
    inFlight = true;
    try {
      await fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        // Only our own key: the server merges `cost` per service, so this leaves
        // cost.claude untouched.
        body: JSON.stringify({
          cost: { openai: spent },
          updatedAt: Date.now(),
        }),
      });
    } catch (e) {
      // local server down; try again next tick
    } finally {
      inFlight = false;
    }
  }

  // The figure renders client-side, so give it a moment on first load.
  _reg.openai = {
    first: setTimeout(send, 2500),
    poll: setInterval(send, POLL_MS),
  };
})();

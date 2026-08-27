// Scrapes current OpenAI spend from the org Limits page and POSTs it as
// `cost.openai` into the local menu bar server.
//
// The page shows "Organization spend limit ... $12.85 / $100.00" -- spent over the
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

  // "$12.85 / $100.00" -> [spent, limit]
  const PAIR = /\$\s*([\d,]+(?:\.\d+)?)\s*\/\s*\$\s*([\d,]+(?:\.\d+)?)/;
  const WHOLE = new RegExp("^" + PAIR.source + "$");
  const num = (s) => parseFloat(s.replace(/,/g, ""));

  // Whitespace-collapsed text of an element. The two halves of the figure live in
  // separate nodes, so every match below runs against a CONTAINER's text, and a
  // container concatenates its children with whatever line breaks the layout left
  // in. Without the collapse, "$12.85\n  / $100.00" misses a regex that allows
  // only \s* between the halves in one line of source.
  const norm = (el) => (el.textContent || "").replace(/\s+/g, " ").trim();

  // platform.openai.com is an SPA and can route between settings pages without a
  // reload, so re-check the path every tick rather than trusting the injection.
  function onLimitsPage() {
    return /^\/settings\/[^/]+\/limits\/?$/.test(location.pathname);
  }

  // Read the spent half of the "$spent / $limit" figure.
  //
  // This used to require the exact heading "project spend limit" and, failing
  // that, a single LEAF node reading "$X / $Y". OpenAI moved both out from under
  // it: the card is headed "Organization spend limit" now, and the figure renders
  // as two sibling nodes, "$12.85" and "/ $100.00". Neither path could match, so
  // the scraper returned null, posted nothing -- correctly, a missing figure is
  // never published -- and the row sat on a months-old number until its staleness
  // warning was the only thing saying so.
  //
  // Two ways in, and neither trusts an exact label. The heading match accepts any
  // "<something> spend limit", so the next rename from Organization to whatever
  // costs nothing. If even that moves, the shape match takes over: an element
  // whose ENTIRE text is a currency pair. Container text, not leaf text, so a
  // figure split across any number of nodes still reads, and the tightest such
  // element wins so it is the figure itself rather than the card around it.
  function readOrgSpend() {
    const heads = Array.from(
      document.querySelectorAll("h1,h2,h3,h4,label,div,span")
    ).filter(
      (e) =>
        e.children.length < 3 &&
        /^[a-z ]*spend limit$/i.test(norm(e)) &&
        !/^edit/i.test(norm(e))
    );
    for (const head of heads) {
      let scope = head.parentElement;
      for (let i = 0; i < 6 && scope; i++) {
        const m = norm(scope).match(PAIR);
        if (m) return num(m[1]);
        scope = scope.parentElement;
      }
    }

    // Measured on the live page: exactly one element matches this whole-string,
    // and the alert rows ("Alert when spend reaches 80% ($80)") do not, because
    // the match has to be the element's entire text.
    let best = null;
    for (const el of document.querySelectorAll("*")) {
      const m = norm(el).match(WHOLE);
      if (!m) continue;
      const size = el.querySelectorAll("*").length;
      if (!best || size < best.size) best = { size, value: num(m[1]) };
    }
    return best ? best.value : null;
  }

  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (!onLimitsPage()) return;
    const spent = readOrgSpend();
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

// Scrapes Gemini API spend from the Google AI Studio Spend page and POSTs it as
// `cost.gemini` into the local menu bar server.
//
// Reads the "Monthly spend cap" card, which shows "$0.00 / -" (or "$0.00 / $50.00"
// once a cap is set). The first amount is spend-so-far either way, and it resets on
// the first of the month PST -- the closest match to the Claude console's
// month-to-date total.
//
// The other figure on the page, "Your Total Cost", is a rolling 28-day chart with no
// plain-text total in the DOM, so it is not scrapeable and would not line up with
// the other rows anyway.
//
// IMPORTANT CAVEAT: Google states costs "take a few hours to show up, and might take
// longer than 24 hours". This row therefore lags reality by up to a day and can read
// $0.00 while spend is actually accruing. That is Google's reporting delay, not a
// bug here -- the menu carries a tooltip saying so.
//
// DOM scrape rather than an API call: AI Studio talks to a protobuf-over-HTTP
// `$rpc/...MakerSuiteService` backend, which is not practical to call directly.

(() => {
  // Guard against running twice in one tab. background.js retrofits open tabs when
  // the extension reloads, and a tab that loaded normally already has us. All of an
  // extension's content scripts share a single isolated world per tab, so a global
  // flag is enough -- without it the second run starts a second timer and we POST
  // twice a minute.
  const _reg = (globalThis.__claudeUsageMenubar ||= {});
  if (_reg.gemini) return;
  _reg.gemini = true;

  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  // The card reads "<spend> / <cap>", where EITHER side can be "-": the cap is "-"
  // when unset, and the spend is "-" until Google's billing pipeline reports. Match
  // the pair as a whole and take the left side. Grabbing the first "$..." in the
  // card instead would read the CAP as spend whenever spend is "-" and a cap is set.
  const PAIR = /(\$\s*[\d,]+(?:\.\d+)?|-)\s*\/\s*(\$\s*[\d,]+(?:\.\d+)?|-)/;
  const num = (s) => parseFloat(s.replace(/[$,\s]/g, ""));

  // AI Studio is an SPA and the account-scoped path varies (/spend, /u/5/spend),
  // so check the suffix rather than trusting the injection match.
  function onSpendPage() {
    return /\/spend\/?$/.test(location.pathname);
  }

  // Three distinct outcomes, and the caller treats each differently:
  //   number     -> a real figure (including a genuine 0)
  //   null       -> the card rendered but spend reads "-": not reported YET
  //   undefined  -> card not found at all (still loading, or markup moved)
  function readMonthlySpend() {
    const leaves = [];
    for (const e of document.querySelectorAll("*")) {
      if (!e.children.length) leaves.push(e);
    }
    let head = null;
    for (const e of leaves) {
      if (e.textContent.trim().toLowerCase().startsWith("monthly spend cap")) {
        head = e;
        break;
      }
    }
    let scope = head ? head.parentElement : null;
    for (let i = 0; i < 6 && scope; i++) {
      const m = scope.textContent.match(PAIR);
      if (m) return m[1] === "-" ? null : num(m[1]);
      scope = scope.parentElement;
    }
    // Fallback: the spend figure carries a `usage` class of its own.
    const span = document.querySelector("span.usage");
    if (span) {
      const t = span.textContent.trim();
      if (t === "-") return null;
      const m = t.match(/\$\s*([\d,]+(?:\.\d+)?)/);
      if (m) return num(m[1]);
    }
    return undefined;
  }

  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (!onSpendPage()) return;
    const spend = readMonthlySpend();
    // Card not found -> post nothing and keep whatever the menu already had.
    if (spend === undefined) return;
    // Spend reads "-" -> post an explicit null so the menu shows "-" too. Posting 0
    // here would be a lie: "not reported yet" and "you spent nothing" look identical
    // on screen but mean very different things, and Google's figure can lag a day.
    if (spend !== null && !Number.isFinite(spend)) return;
    inFlight = true;
    try {
      await fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        // Only our own key; the server merges `cost` per service.
        // `spend` is a number, or null meaning "not reported yet" -> renders "-".
        body: JSON.stringify({
          cost: { gemini: spend },
          updatedAt: Date.now(),
        }),
      });
    } catch (e) {
      // local server down; try again next tick
    } finally {
      inFlight = false;
    }
  }

  setTimeout(send, 2500);
  setInterval(send, POLL_MS);
})();

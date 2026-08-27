// Scrapes Gemini API spend from the Google AI Studio Billing page and POSTs it as
// `cost.gemini` into the local menu bar server.
//
// Reads the "Billing Account Cost for Gemini API" card, which covers the current
// month to date ("August 1 - 26, 2026") and reads:
//
//     Cost $0.60   -   Savings $0.00   =   Total cost $0.60
//
// We take "Total cost", the net figure, falling back to "Cost". They are the same
// number until a discount or credit applies, and when one does, the net is what
// the account is actually billed -- which is what a row headed API Cost should say.
//
// This replaced the /spend page's "Monthly spend cap" card, which reported spend as
// the left half of a "<spend> / <cap>" pair. The billing page states its own date
// range, so the figure no longer has to be inferred from a cap widget.
//
// IMPORTANT CAVEAT: the card itself says "Cost information may take up to 24 hours
// to update". This row therefore lags reality by up to a day and can read $0.00
// while spend is actually accruing. That is Google's reporting delay, not a bug
// here -- the menu carries a tooltip saying so.
//
// DOM scrape rather than an API call: AI Studio talks to a protobuf-over-HTTP
// `$rpc/...MakerSuiteService` backend, which is not practical to call directly.

(() => {
  // Exactly one live timer per tab, and it must belong to the CURRENT extension
  // context. background.js re-injects into open tabs on every extension reload, but
  // the isolated world holding this registry outlives that reload -- so a plain
  // "already ran, bail out" flag turned re-injection into a no-op that deferred to
  // a timer whose context had just been torn down and could no longer reach the
  // server. Holding the timer ids makes re-injection a replacement instead. See
  // openai.js for the full account.
  const _reg = (globalThis.__claudeUsageMenubar ||= {});
  if (_reg.gemini) {
    clearTimeout(_reg.gemini.first);
    clearInterval(_reg.gemini.poll);
  }

  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  const CURRENCY = /^\s*\$\s*([\d,]+(?:\.\d+)?)\s*$/;
  const num = (s) => parseFloat(s.replace(/[$,\s]/g, ""));

  // AI Studio is an SPA and the path is account-scoped (/billing, /u/3/billing),
  // with the billing account and project carried in the query string. Check the
  // path suffix rather than trusting the injection match.
  function onBillingPage() {
    return /\/billing\/?$/.test(location.pathname);
  }

  // Labels to read, in preference order. See the header for why net beats gross.
  const LABELS = ["total cost", "cost"];

  // Find the figure sitting under `label` in the cost card.
  //
  // Every candidate is tried, not just the first: the chart legend beneath the card
  // ALSO renders a "Total cost" label (twice -- one visible, one a hidden ruler
  // element used for measurement), and neither has a figure anywhere near it.
  // Taking the first match and giving up would read the legend and report nothing.
  function readLabelled(label) {
    const leaves = Array.from(document.querySelectorAll("*")).filter(
      (e) => !e.children.length
    );
    const candidates = leaves.filter(
      (e) => e.textContent.trim().toLowerCase() === label
    );
    for (const el of candidates) {
      let scope = el.parentElement;
      for (let i = 0; i < 4 && scope; i++) {
        for (const leaf of leaves) {
          if (!scope.contains(leaf)) continue;
          const m = leaf.textContent.match(CURRENCY);
          if (m) return num(m[1]);
        }
        scope = scope.parentElement;
      }
    }
    return null;
  }

  // null means the card was not found, or found without a figure -- still loading,
  // or the markup moved. The caller posts NOTHING in that case, deliberately: a
  // missing figure must never be published as zero, because "not reported yet" and
  // "you spent nothing" look identical in the menu and mean very different things.
  // The row's per-service age then stops advancing, which is what makes the menu
  // flag it instead of showing a wrong number confidently.
  function readSpend() {
    for (const label of LABELS) {
      const v = readLabelled(label);
      if (v !== null && Number.isFinite(v)) return v;
    }
    return null;
  }

  let inFlight = false;
  async function send() {
    if (inFlight) return;
    if (!onBillingPage()) return;
    const spend = readSpend();
    if (spend === null) return;
    inFlight = true;
    try {
      await fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        // Only our own key; the server merges `cost` per service.
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

  _reg.gemini = {
    first: setTimeout(send, 2500),
    poll: setInterval(send, POLL_MS),
  };
})();

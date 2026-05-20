// Scrapes API workspace cost from platform.claude.com/workspaces/*/cost.
// Reads:
//   - Total month-to-date cost from the "Total token cost" card.
//   - Per-model breakdown by walking the Chart.js donut: programmatically
//     hover slices around the ring and read the tooltip after each.
//
// POSTs a `cost` block into the existing local server payload.

(() => {
  const ENDPOINT = "http://localhost:7823/usage";
  const POLL_MS = 60_000;

  const MODEL_KEYS = ["opus", "sonnet", "haiku"];

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

  // -- Per-model breakdown -------------------------------------------------

  // First try a static text scan: maybe there's a legend/table with model
  // names + dollar amounts already in the DOM.
  function readPerModelStatic() {
    const found = {};
    // Find every text node that mentions one of our models.
    const walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_TEXT
    );
    let node;
    while ((node = walker.nextNode())) {
      const lower = node.textContent.toLowerCase();
      for (const key of MODEL_KEYS) {
        if (!lower.includes(key) || found[key]) continue;
        // Walk up looking for a $ amount in the same row/card.
        let scope = node.parentElement;
        for (let i = 0; i < 5 && scope; i++) {
          const text = scope.textContent;
          // Be careful: the scope might contain multiple model names + $.
          // Only accept if exactly one model name appears in this scope.
          const modelHits = MODEL_KEYS.filter((k) =>
            text.toLowerCase().includes(k)
          );
          if (modelHits.length === 1 && modelHits[0] === key) {
            const m = text.match(/\$([0-9]+(?:\.[0-9]+)?)/);
            if (m) {
              found[key] = parseFloat(m[1]);
              break;
            }
          }
          scope = scope.parentElement;
        }
      }
    }
    return Object.keys(found).length ? found : null;
  }

  // Fallback: programmatically hover the donut chart canvas at many
  // angles, read the tooltip text after each hover.
  async function readPerModelByHover() {
    const canvas = document.querySelector('canvas[role="img"]');
    if (!canvas) return null;
    const rect = canvas.getBoundingClientRect();
    if (rect.width < 20 || rect.height < 20) return null;
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    const r = Math.min(rect.width, rect.height) / 2 * 0.7;

    const found = {};
    const samples = 36;
    for (let i = 0; i < samples; i++) {
      const angle = (i / samples) * 2 * Math.PI;
      const x = cx + Math.cos(angle) * r;
      const y = cy + Math.sin(angle) * r;
      for (const type of ["pointermove", "mousemove"]) {
        canvas.dispatchEvent(
          new MouseEvent(type, {
            clientX: x,
            clientY: y,
            bubbles: true,
            cancelable: true,
            view: window,
          })
        );
      }
      // Give Chart.js a tick to update tooltip content.
      await new Promise((r) => setTimeout(r, 25));
      const tooltip = document.querySelector('[role="tooltip"]');
      if (!tooltip) continue;
      const txt = tooltip.textContent;
      const modelMatch = txt.match(/Claude\s+(Opus|Sonnet|Haiku)/i);
      const dollarMatch = txt.match(/\$([0-9]+(?:\.[0-9]+)?)/);
      if (modelMatch && dollarMatch) {
        const key = modelMatch[1].toLowerCase();
        if (found[key] == null) found[key] = parseFloat(dollarMatch[1]);
      }
    }
    // Reset hover so we don't leave the page in a hovered state.
    canvas.dispatchEvent(
      new MouseEvent("mouseleave", { bubbles: true, cancelable: true })
    );
    return Object.keys(found).length ? found : null;
  }

  // -- Send loop -----------------------------------------------------------

  async function buildPayload() {
    const totalUSD = readTotal();
    let perModel = readPerModelStatic();
    if (!perModel) perModel = await readPerModelByHover();
    if (totalUSD === null && !perModel) return null;
    return {
      cost: {
        totalUSD,
        perModel: perModel || {},
        period: "month-to-date",
      },
      updatedAt: Date.now(),
    };
  }

  let lastSent = 0;
  let inFlight = false;
  async function send() {
    if (inFlight) return;
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

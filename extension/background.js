// Injects the content scripts into tabs that are ALREADY OPEN.
//
// Chromium only injects a content script when a page loads. Reloading an
// extension does not retrofit its scripts into existing tabs -- so after adding
// or changing a script you had to hunt down and reload each provider tab by hand,
// and until you did, that provider silently reported nothing. (The mirror image
// also bites: a content script removed from the extension keeps running in tabs
// that already have it, orphaned, until those tabs reload.)
//
// This runs on install, on update (which is what an unpacked reload fires), and
// at browser startup, and injects each content script into every open tab its own
// manifest patterns match. After this, reloading the extension is genuinely
// sufficient.
//
// The script list is read from the manifest at runtime rather than duplicated
// here, so adding a provider means touching manifest.json only.

async function injectIntoOpenTabs(reason) {
  const { content_scripts: scripts = [] } = chrome.runtime.getManifest();
  let injected = 0;

  for (const cs of scripts) {
    if (!cs.matches || !cs.js) continue;
    let tabs = [];
    try {
      tabs = await chrome.tabs.query({ url: cs.matches });
    } catch (e) {
      // No host permission for these patterns, or an invalid pattern.
      console.warn("[claude-usage] tabs.query failed for", cs.matches, e);
      continue;
    }
    for (const tab of tabs) {
      // Skip tabs we cannot script: no id, discarded/sleeping, or a non-http
      // scheme that slipped through the pattern.
      if (!tab.id || tab.discarded || !/^https?:/.test(tab.url || "")) continue;
      try {
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: cs.js,
        });
        injected++;
      } catch (e) {
        // Injection legitimately fails on some pages (error pages, pre-render,
        // a tab that navigated away mid-loop). Not worth failing the whole run.
        console.warn("[claude-usage] inject failed for tab", tab.id, e);
      }
    }
  }

  console.log(`[claude-usage] ${reason}: injected into ${injected} open tab(s)`);
}

chrome.runtime.onInstalled.addListener((d) => injectIntoOpenTabs(d.reason));
chrome.runtime.onStartup.addListener(() => injectIntoOpenTabs("startup"));

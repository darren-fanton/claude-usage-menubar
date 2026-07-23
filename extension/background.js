// Clicking the toolbar icon opens (or focuses) the four pages this extension
// scrapes, so you can eyeball / refresh them in one click.

const SCRAPE_URLS = [
  "https://claude.ai/settings/usage",
  "https://platform.claude.com/settings/billing",
  "https://platform.openai.com/settings/proj_vxOhdwuqhmqTXXVDefWUzMRY/limits",
  "https://aistudio.google.com/u/2/spend?project=gen-lang-client-0546438527",
];

// Open the URL, or focus an existing tab that's already on that page (matched
// by scheme+host+path, ignoring query strings) so repeated clicks don't stack.
async function openOrFocus(url) {
  const base = url.split("?")[0];
  try {
    const tabs = await chrome.tabs.query({ url: base + "*" });
    if (tabs && tabs.length) {
      await chrome.tabs.update(tabs[0].id, { active: true });
      if (tabs[0].windowId != null) {
        await chrome.windows.update(tabs[0].windowId, { focused: true });
      }
      return;
    }
  } catch (e) {
    // query can fail if host permissions are missing; fall through to create.
  }
  await chrome.tabs.create({ url });
}

chrome.action.onClicked.addListener(async () => {
  for (const url of SCRAPE_URLS) {
    await openOrFocus(url);
  }
});

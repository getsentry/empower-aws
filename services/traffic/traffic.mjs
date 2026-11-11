// Scheduled demo traffic: a real headless browser uses the storefront like a shopper,
// so Sentry gets the whole trace (browser → agent → Bedrock → store API → RDS).
// Runs as its own ECS service and loops: one session, then sleep about INTERVAL_MINUTES.
//   node traffic.mjs            loop forever
//   node traffic.mjs --once     one session of each flow, exit non-zero if any failed (CI)
import { chromium } from 'playwright-core';

const BASE = (process.env.STOREFRONT_URL || '').replace(/\/$/, '');
const INTERVAL_MINUTES = Number(process.env.INTERVAL_MINUTES || 15);
const MODEL = process.env.AGENT_MODEL || 'haiku';
const ONCE = process.argv.includes('--once');
if (!BASE) throw new Error('STOREFRONT_URL is required');

// Weights decide how often each flow runs. Most agent flows end in a failing tool call
// (expired coupon, out-of-stock purchase); the browse flow should succeed.
const FLOWS = [
  { name: 'agent-purchase', weight: 4, messages: ['Show me plants under $200', 'Add one of each to the cart', 'Checkout', 'Apply Coupon', 'Purchase'] },
  { name: 'agent-browse', weight: 3, messages: ['Which plants do well in low light?', 'Add the first one to my cart', "What's in my cart?"] },
  { name: 'agent-coupon', weight: 2, messages: ['Show me plants under $200', 'Add the cheapest one to my cart', 'Checkout', 'Apply Coupon'] },
  { name: 'storefront-checkout', weight: 2, run: storefrontCheckout },
];

const log = (fields) => console.log(JSON.stringify({ time: new Date().toISOString(), ...fields }));
const pause = (page, min, max) => page.waitForTimeout(min + Math.random() * (max - min));

async function openChat(page) {
  await page.goto(`${BASE}/?se=traffic&agent_model=${MODEL}`, { waitUntil: 'domcontentloaded' });
  const input = page.locator('#chat-message-input').first();
  if (!(await input.isVisible({ timeout: 5000 }).catch(() => false))) {
    for (const selector of ['.hero-agent-button', '.chat-toggle-button']) {
      const button = page.locator(selector).first();
      if (await button.isVisible().catch(() => false)) {
        await button.click();
        break;
      }
    }
  }
  await input.waitFor({ timeout: 30000 });
  return input;
}

async function chat(page, messages) {
  const input = await openChat(page);
  for (const message of messages) {
    await input.fill(message);
    await page.locator('#chat-send-button').first().click();
    // The input says "Thinking…" while a turn streams.
    const thinking = () => document.querySelector('#chat-message-input')?.placeholder === 'Thinking…';
    await page.waitForFunction(thinking, null, { timeout: 15000 }).catch(() => {});
    const done = () => document.querySelector('#chat-message-input')?.placeholder !== 'Thinking…';
    await page.waitForFunction(done, null, { timeout: 180000 });
    await pause(page, 2000, 6000); // reading time
  }
}

async function storefrontCheckout(page) {
  await page.goto(`${BASE}/products?se=traffic`, { waitUntil: 'domcontentloaded' });
  const add = page.locator('button:has-text("Add to cart")');
  await add.first().waitFor({ timeout: 90000 }); // /products is slow on purpose
  const count = await add.count();
  for (let i = 0; i < 1 + Math.floor(Math.random() * 2); i++) {
    await add.nth(Math.floor(Math.random() * count)).click();
    await pause(page, 500, 1500);
  }
  await page.locator('a[href="/cart"]:visible').first().click();
  await page.locator('a[href="/checkout-form"]:visible').first().click();
  await page.locator('.complete-checkout-btn').first().click();
  await page.waitForURL(/\/(complete|error)/, { timeout: 90000 });
  return page.url().includes('/complete') ? 'complete' : 'error page';
}

async function runFlow(browser, flow) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const started = Date.now();
  try {
    const result = flow.run ? await flow.run(page) : await chat(page, flow.messages);
    await pause(page, 3000, 5000);
    await page.goto('about:blank'); // pagehide lets the Sentry SDK flush the last transaction
    await page.waitForTimeout(2000);
    log({ flow: flow.name, ok: true, result, seconds: Math.round((Date.now() - started) / 1000) });
    return true;
  } catch (error) {
    log({ flow: flow.name, ok: false, error: String(error).slice(0, 300), url: page.url() });
    return false;
  } finally {
    await context.close();
  }
}

function pickFlow() {
  let n = Math.random() * FLOWS.reduce((sum, f) => sum + f.weight, 0);
  return FLOWS.find((f) => (n -= f.weight) < 0) || FLOWS[0];
}

const browser = await chromium.launch();
if (ONCE) {
  let ok = true;
  for (const flow of FLOWS) ok = (await runFlow(browser, flow)) && ok;
  await browser.close();
  process.exit(ok ? 0 : 1);
}
log({ started: true, base: BASE, model: MODEL, intervalMinutes: INTERVAL_MINUTES });
for (;;) {
  await runFlow(browser, pickFlow());
  const minutes = INTERVAL_MINUTES * (0.7 + Math.random() * 0.6);
  await new Promise((resolve) => setTimeout(resolve, minutes * 60000));
}

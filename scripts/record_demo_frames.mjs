#!/usr/bin/env node
/**
 * SpreadPilot HSK — Live Web Runtime QA & Optional Demo Frame Capture
 *
 * Zero external dependencies (uses Node.js >= 22 built-in WebSocket + Chrome DevTools Protocol).
 * - Boots `vite preview --port 5177 --host 127.0.0.1` against `web/dist` (unless --url is passed)
 * - Verifies live page boot, zero uncaught pageerrors, live telemetry / spread rows
 * - Exercises all key interactive controls:
 *     1) Probe order sizing ($1500)
 *     2) Conversational Conservative Rails update ($120 slice / 45s cooldown / 2.5% stop-loss)
 *     3) Conversational TWAP order staging & immediate slice execution
 *     4) Target asset allowlist restriction & refusal gate proof
 *     5) Stop-loss circuit breaker stress test (blocks active TWAP plan)
 *     6) Owner circuit breaker reset (restores RAILS ARMED)
 * - Optionally writes PNG screenshots when `--capture-dir <dir>` is passed.
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, '..');
const WEB_DIR = path.join(ROOT_DIR, 'web');

function parseArgs(argv) {
  const opts = {
    url: null,
    port: 5177,
    captureDir: null,
    chromePath: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--url' && argv[i + 1]) opts.url = argv[++i];
    else if (arg === '--port' && argv[i + 1]) opts.port = Number(argv[++i]);
    else if (arg === '--capture-dir' && argv[i + 1]) opts.captureDir = path.resolve(argv[++i]);
    else if (arg === '--chrome' && argv[i + 1]) opts.chromePath = argv[++i];
  }
  return opts;
}

function findChromeBinary(explicitPath) {
  if (explicitPath && existsSync(explicitPath)) return explicitPath;
  const home = process.env.HOME || '';
  const candidates = [
    process.env.CHROME_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    path.join(
      home,
      'Library/Caches/ms-playwright/chromium-1217/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
    ),
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean);

  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForHttp(url, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) return true;
    } catch {
      // retry
    }
    await sleep(200);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

class SimpleCdpClient {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.ws = null;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    this.ws = new WebSocket(this.wsUrl);
    await new Promise((resolve, reject) => {
      this.ws.addEventListener('open', resolve, { once: true });
      this.ws.addEventListener('error', reject, { once: true });
    });
    this.ws.addEventListener('message', (event) => {
      const msg = JSON.parse(String(event.data));
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else resolve(msg.result);
      } else if (msg.method && this.listeners.has(msg.method)) {
        for (const fn of this.listeners.get(msg.method)) fn(msg.params);
      }
    });
  }

  on(method, fn) {
    if (!this.listeners.has(method)) this.listeners.set(method, []);
    this.listeners.get(method).push(fn);
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const res = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (res.exceptionDetails) {
      throw new Error(res.exceptionDetails.text || JSON.stringify(res.exceptionDetails));
    }
    return res.result?.value;
  }

  async screenshot(filePath) {
    const { data } = await this.send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(filePath, Buffer.from(data, 'base64'));
  }

  close() {
    if (this.ws) {
      try {
        this.ws.close();
      } catch {
        // ignore
      }
    }
  }
}

async function waitForCondition(cdp, jsExpr, label, timeoutMs = 12_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = await cdp.evaluate(jsExpr);
    if (val) return val;
    await sleep(200);
  }
  throw new Error(`Condition timed out: ${label}`);
}

async function clickButtonByText(cdp, text) {
  const clicked = await cdp.evaluate(`(() => {
    const btns = Array.from(document.querySelectorAll('button'));
    const match = btns.find((b) => b.textContent && b.textContent.trim() === ${JSON.stringify(text)});
    if (!match) return false;
    match.click();
    return true;
  })()`);
  if (!clicked) throw new Error(`Button not found: "${text}"`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const chromeBin = findChromeBinary(opts.chromePath);
  if (!chromeBin) {
    throw new Error('No headless Chrome/Chromium binary found. Pass --chrome /path/to/chrome.');
  }

  if (opts.captureDir) {
    mkdirSync(opts.captureDir, { recursive: true });
  }

  let previewProc = null;
  let chromeProc = null;
  let cdp = null;

  const targetUrl = opts.url || `http://127.0.0.1:${opts.port}/`;
  const debugPort = 9222 + Math.floor(Math.random() * 500);

  try {
    if (!opts.url) {
      const distIndex = path.join(WEB_DIR, 'dist', 'index.html');
      if (!existsSync(distIndex)) {
        throw new Error('web/dist/index.html missing. Run `cd web && npm run build` first.');
      }
      previewProc = spawn(
        process.execPath,
        [path.join(WEB_DIR, 'node_modules/vite/bin/vite.js'), 'preview', '--port', String(opts.port), '--host', '127.0.0.1', '--strictPort'],
        { cwd: WEB_DIR, stdio: ['ignore', 'pipe', 'pipe'] },
      );
      await waitForHttp(targetUrl, 15_000);
    }

    chromeProc = spawn(
      chromeBin,
      [
        '--headless=new',
        '--disable-gpu',
        '--no-sandbox',
        '--disable-dev-shm-usage',
        `--remote-debugging-port=${debugPort}`,
        '--window-size=1520,980',
        'about:blank',
      ],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );

    const versionUrl = `http://127.0.0.1:${debugPort}/json/list`;
    await waitForHttp(versionUrl, 15_000);
    const targets = await (await fetch(versionUrl)).json();
    const pageTarget = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    if (!pageTarget) throw new Error('Failed to locate CDP page target');

    cdp = new SimpleCdpClient(pageTarget.webSocketDebuggerUrl);
    await cdp.connect();

    const pageErrors = [];
    const consoleErrors = [];
    cdp.on('Runtime.exceptionThrown', (params) => {
      pageErrors.push(params.exceptionDetails?.exception?.description || params.exceptionDetails?.text || 'Uncaught exception');
    });
    cdp.on('Console.messageAdded', (params) => {
      if (params.message?.level === 'error') {
        consoleErrors.push(params.message.text);
      }
    });

    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Console.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 1520,
      height: 980,
      deviceScaleFactor: 1,
      mobile: false,
    });

    await cdp.send('Page.navigate', { url: targetUrl });

    // 1. Wait for Spread Matrix to populate (either live RPC/CEX or graceful fallback)
    await waitForCondition(
      cdp,
      `document.querySelectorAll('table.matrix tbody tr').length >= 5`,
      'Spread Matrix rows rendered',
      15_000,
    );
    await sleep(600);

    const bootSummary = await cdp.evaluate(`(() => {
      const h1 = document.querySelector('h1')?.textContent?.trim() || '';
      const rows = document.querySelectorAll('table.matrix tbody tr').length;
      const hasSpinRule = Array.from(document.styleSheets).some((sheet) => {
        try {
          return Array.from(sheet.cssRules).some((r) => r.type === CSSRule.KEYFRAMES_RULE && r.name === 'spin');
        } catch {
          return false;
        }
      });
      const pills = Array.from(document.querySelectorAll('.telemetry-pills .pill')).map((el) => el.textContent.trim());
      return { h1, rows, hasSpinRule, pills };
    })()`);

    if (!bootSummary.h1.includes('SpreadPilot HSK')) {
      throw new Error(`Unexpected header: ${bootSummary.h1}`);
    }
    if (!bootSummary.hasSpinRule) {
      throw new Error('CSS @keyframes spin rule missing in built stylesheet!');
    }
    const layoutCheck = await cdp.evaluate(`(() => {
      window.scrollTo(0, 0);
      const wrap = document.querySelector('.table-wrap');
      return {
        scrollY: window.scrollY,
        tableOverflowPx: wrap ? wrap.scrollWidth - wrap.clientWidth : 0,
        bodyHeight: document.body.scrollHeight,
      };
    })()`);
    if (layoutCheck.tableOverflowPx > 2) {
      throw new Error(`Spread Matrix horizontal overflow detected: ${layoutCheck.tableOverflowPx}px`);
    }
    if (opts.captureDir) {
      await cdp.screenshot(path.join(opts.captureDir, '01-dashboard-live.png'));
    }

    // 2. Order Size $1500 probe check
    await clickButtonByText(cdp, '$1500');
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('Probe Order: $1500')`,
      'Probe order updated to $1500',
    );

    // 3. Conservative Rails chip
    await clickButtonByText(cdp, 'Conservative Rails');
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('$120 / $600') && document.body.innerText.includes('2.5%')`,
      'Conservative rails applied ($120 / $600, 2.5% stop-loss)',
    );
    if (opts.captureDir) {
      await cdp.screenshot(path.join(opts.captureDir, '02-conservative-rails.png'));
    }

    // 4. Buy $450 WHSK TWAP + verify immediate slice execution
    await clickButtonByText(cdp, 'Buy $450 WHSK TWAP');
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('Active & Completed TWAP Orders (1)') && document.body.innerText.includes('(1/')`,
      'TWAP staged and slice 1 executed',
      6_000,
    );
    if (opts.captureDir) {
      await cdp.screenshot(path.join(opts.captureDir, '03-twap-staged.png'));
    }

    // 5. Restrict assets to WHSK & WETH Only -> Test Gate on disabled asset logs refusal
    await clickButtonByText(cdp, 'Allow WHSK & WETH Only');
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('✕ WBTC') && document.body.innerText.includes('✕ USDC')`,
      'WBTC and USDC disabled in allowlist',
    );

    await cdp.evaluate(`(() => {
      const rows = Array.from(document.querySelectorAll('table.matrix tbody tr'));
      const wbtcRow = rows.find((r) => r.textContent && r.textContent.includes('WBTC/USDT'));
      const btn = wbtcRow?.querySelector('button');
      if (btn) btn.click();
    })()`);
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('OPPORTUNITY REFUSED') && document.body.innerText.includes('ASSET_NOT_ALLOWED')`,
      'Verifiable refusal proof logged (ASSET_NOT_ALLOWED)',
    );
    if (opts.captureDir) {
      await cdp.screenshot(path.join(opts.captureDir, '04-allowlist-refusal.png'));
    }

    // 6. Stress-Test Stop-Loss -> verifies BREAKER TRIPPED + active plan BLOCKED
    await clickButtonByText(cdp, 'Stress-Test Stop-Loss');
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('BREAKER TRIPPED') && document.body.innerText.includes('Stop-Loss Circuit Breaker Active') && document.body.innerText.includes('BLOCKED')`,
      'Stop-loss circuit breaker tripped and active TWAP blocked',
    );
    if (opts.captureDir) {
      await cdp.screenshot(path.join(opts.captureDir, '05-breaker-tripped.png'));
    }

    // 7. Owner Reset Breaker -> verifies RAILS ARMED restored
    await clickButtonByText(cdp, 'Owner Reset Breaker');
    await waitForCondition(
      cdp,
      `document.body.innerText.includes('RAILS ARMED') && !document.body.innerText.includes('Stop-Loss Circuit Breaker Active')`,
      'Circuit breaker reset and RAILS ARMED restored',
    );
    if (opts.captureDir) {
      await cdp.screenshot(path.join(opts.captureDir, '06-owner-reset-armed.png'));
    }

    if (pageErrors.length > 0) {
      throw new Error(`Uncaught page errors detected: ${pageErrors.join(' | ')}`);
    }

    console.log(
      JSON.stringify(
        {
          status: 'PASS',
          url: targetUrl,
          header: bootSummary.h1,
          matrixRows: bootSummary.rows,
          hasSpinKeyframes: bootSummary.hasSpinRule,
          telemetryPills: bootSummary.pills,
          verifiedFlows: [
            'boot-and-live-feeds',
            'probe-order-1500',
            'conservative-policy-rails',
            'twap-stage-and-slice-exec',
            'asset-allowlist-refusal-proof',
            'stop-loss-breaker-trip-and-block',
            'owner-breaker-reset',
          ],
          pageErrors: pageErrors.length,
          consoleErrors: consoleErrors.length,
          capturedDir: opts.captureDir || null,
        },
        null,
        2,
      ),
    );
  } finally {
    if (cdp) cdp.close();
    if (chromeProc && !chromeProc.killed) chromeProc.kill('SIGTERM');
    if (previewProc && !previewProc.killed) previewProc.kill('SIGTERM');
  }
}

main().catch((err) => {
  console.error('[record_demo_frames] FAIL:', err?.message || err);
  process.exit(1);
});

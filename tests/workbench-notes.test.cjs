/**
 * [INPUT]: 真实首页 HTML/JS/CSS、Playwright 与受控 HTTP/WS 替身。
 * [OUTPUT]: 保存/丢包恢复/刷新/同号重试/身份切换/存储失败/文本安全回归及双尺寸截图。
 * [POS]: G1 手机交互隔离测试；不启动桌面 App、不使用生产凭据、不证明真实手机部署。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '..');
const screenshots = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketdesk-notes-ui-'));
const contentType = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.svg': 'image/svg+xml', '.png': 'image/png' };
async function main() {
  const browser = await chromium.launch({ headless: true, channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const page = await context.newPage();
    const errors = [], posts = [], desktopWrites = [], receipts = new Map();
    let gate = false, lose = false, miss = false, wrong = false, subject = 'a'.repeat(64);
    page.on('pageerror', error => errors.push(error.stack || String(error)));
    await page.context().addInitScript(() => {
      if (!localStorage.getItem('voicedeck.pair-token')) localStorage.setItem('voicedeck.pair-token', 'test-pair');
      class Socket {
        static OPEN = 1;
        constructor() { this.readyState = 0; this.bufferedAmount = 0; setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 1); }
        send(raw) { const m = JSON.parse(raw); if (m.t === 'auth') setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'auth_ok', session: 'test', controller: true, absolutePointerV1: true }) }), 1); }
        close() { this.readyState = 3; }
      }
      window.WebSocket = Socket;
    });
    await page.context().route('**/*', async route => {
      const req = route.request(), url = new URL(req.url()), p = url.pathname;
      const ok = (value, status = 200) => route.fulfill({ status, json: value });
      if (p.startsWith('/api/v1/workbench')) {
        assert.match(req.headers().authorization || '', /^Bearer test-/);
        if (p.endsWith('/capabilities')) return gate
          ? ok({ capabilities: [{ capabilityId: 'note.create', bindingId: 'workbench-note-default', authorizationRef: 'pocketdesk:test:' + subject }] })
          : ok({ error: 'Workbench Bridge 尚未准入' }, 503);
        if (p.endsWith('/notes')) {
          const body = req.postDataJSON(); posts.push(body);
          if (miss) return route.abort('failed');
          const receipt = { protocolVersion: 1, requestId: body.requestId, operationId: 'note-' + body.requestId,
            invocationId: 'invoke-' + body.requestId, bindingId: 'workbench-note-default', capabilityId: 'note.create',
            capabilityVersion: '1', state: 'succeeded', artifacts: [{ type: 'note', id: String(receipts.size + 1) }] };
          if (wrong) return ok({ ...receipt, requestId: 'wrong-id' });
          receipts.set(body.requestId, { receipt, body, subject });
          if (lose) return route.abort('failed');
          return ok(receipt);
        }
        if (p.includes('/requests/')) {
          const entry = receipts.get(p.split('/').pop());
          return entry && entry.subject === subject ? ok(entry.receipt) : ok({ error: '请求不存在' }, 404);
        }
        if (p.includes('/artifacts/')) {
          const id = p.split('/').pop(), entry = [...receipts.values()].find(e => e.receipt.artifacts[0].id === id && e.subject === subject);
          return entry ? ok({ id, title: entry.body.title, content: entry.body.body }) : ok({ error: '成果不存在' }, 404);
        }
        throw new Error('Unexpected bridge path ' + p);
      }
      if (p.startsWith('/api/')) {
        if (req.method() === 'POST' && ['/api/live-input', '/api/send', '/api/v1/tasks'].includes(p)) desktopWrites.push(p);
        if (p === '/api/status') return ok({ targets: [{ id: 'wb', name: 'WorkBuddy' }], shortcuts: [], accessibility: true, theme: 'classic', frontmostName: '测试编辑器' });
        if (p === '/api/recipients') return ok({ order: ['__sprite__', 'wb'] });
        if (p === '/api/v1/phone-files') return ok({ files: [], revision: 'test' });
        if (p === '/api/screen/state') return ok({ locked: false });
        if (p === '/api/screen/displays') return ok({ displays: [], streamPort: 46389 });
        if (p === '/api/icon') return route.fulfill({ status: 404, body: '' });
        return ok({ ok: true });
      }
      const file = path.join(root, 'Web', p === '/' ? 'index.html' : p);
      if (!fs.existsSync(file)) return route.fulfill({ status: 404, body: '' });
      return route.fulfill({ body: fs.readFileSync(file), contentType: contentType[path.extname(file)] || 'application/octet-stream' });
    });
    const settled = () => page.waitForFunction(() => document.getElementById('workbench-notes').getAttribute('aria-busy') === 'false');
    const click = async id => { await page.locator('#' + id).click(); await settled(); };
    const status = () => page.locator('#workbench-note-status').textContent();
    const journals = () => page.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('pocketdesk.workbench-note.v1:')).map(k => JSON.parse(localStorage.getItem(k))));
    const select = async () => { await page.locator('[data-target-id="__sprite__"]').click(); await settled(); };
    await page.goto('http://pocketdesk.test/'); await select();
    assert.equal(await page.locator('#workbench-note-save').isDisabled(), true);
    assert.match(await status(), /尚未准入/); assert.equal(posts.length, 0);
    gate = true; await click('workbench-note-recover');
    assert.equal(await page.locator('#workbench-note-save').isDisabled(), true, '空白不能保存');
    const first = '给新版本留一份验收清单\n<img src=x onerror=alert(1)>\n断线也不能重复创建。';
    await page.locator('#text').fill(first);
    await click('workbench-note-save');
    assert.equal(posts.length, 1); assert.equal(await page.locator('#text').inputValue(), first);
    assert.match(await status(), /已存到/); assert.equal(await page.locator('#workbench-note-save').isDisabled(), true);
    assert.equal((await journals())[0].body, undefined, '确认后清除持久副本正文');
    await click('workbench-note-view');
    assert.match(await page.locator('#workbench-note-content').textContent(), /<img src=x/);
    assert.equal(await page.locator('#workbench-note-content img').count(), 0, '成果只呈现文本');

    lose = true; await page.locator('#text').fill('已写入但响应丢失'); await click('workbench-note-save');
    assert.equal(posts.length, 2); assert.match(await status(), /已存到/); lose = false;
    miss = true; await page.locator('#text').fill('断线前的原始正文'); await click('workbench-note-save');
    assert.equal(posts.length, 3); assert.match(await status(), /尚未查到/);
    const original = posts.at(-1); assert.equal((await journals()).find(item => item.state === 'pending').body, original.body);
    await page.locator('#workbench-note-snapshot summary').click();
    assert.equal(await page.locator('#workbench-note-original').textContent(), original.body);
    await page.locator('#text').fill('下一件事，不能套用旧请求');
    await page.reload(); await select();
    assert.equal(posts.length, 3, '刷新只查询，不重放');
    assert.match(await status(), /尚未查到/);
    await page.locator('#text').fill('下一件事，不能套用旧请求');
    miss = false; await click('workbench-note-retry');
    assert.deepEqual(posts.at(-1), original, '重试使用持久快照和原编号');
    assert.equal(await page.locator('#text').inputValue(), '下一件事，不能套用旧请求');
    assert.match(await status(), /已存到/);

    await page.evaluate(() => {
      window.originalSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function (key, value) { if (key.startsWith('pocketdesk.workbench-note.v1:')) throw new Error('测试：手机存储已满'); return window.originalSetItem.call(this, key, value); };
    });
    const count = posts.length; await click('workbench-note-save');
    assert.equal(posts.length, count, '未持久保存编号时禁止副作用'); assert.match(await status(), /存储已满/);
    await page.evaluate(() => { Storage.prototype.setItem = window.originalSetItem; pendingImages = [{ id: 'test' }]; });
    await click('workbench-note-save'); assert.match(await status(), /先移除附件/); assert.equal(posts.length, count);
    await page.evaluate(() => { pendingImages = []; });
    wrong = true; await click('workbench-note-save'); assert.match(await status(), /尚未查到/);
    assert.ok((await journals()).some(item => item.state === 'pending'), '错配回执不能当成功'); wrong = false;
    await click('workbench-note-retry'); assert.match(await status(), /已存到/);
    subject = 'b'.repeat(64);
    await page.evaluate(() => { localStorage.setItem('voicedeck.pair-token', 'test-new-pair'); window.pocketdeskWorkbenchNotes.render(); });
    assert.equal(await page.locator('#workbench-note-view').isVisible(), false);
    await click('workbench-note-recover');
    assert.equal(await page.locator('#workbench-note-view').isVisible(), false, '新主体不继承旧记录');
    assert.equal(posts.length, count + 2, '身份恢复不自动写');

    await page.locator('#text').fill('下一版小精灵验收\n每次交办都能查到请求、执行状态和最终成果。');
    await click('workbench-note-save'); await click('workbench-note-view');
    assert.deepEqual(errors, []);
    for (const width of [320, 390, 1100]) {
      await page.setViewportSize({ width, height: 900 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, '不能横向溢出');
      const sizes = await page.locator('#workbench-notes button:visible').evaluateAll(nodes => nodes.map(n => n.getBoundingClientRect().height));
      assert.ok(sizes.every(h => h >= 44), '所有操作区至少 44px');
      if (width !== 320 && !process.env.NO_SCREENSHOTS) await page.screenshot({ path: path.join(screenshots, width === 390 ? 'mobile.png' : 'desktop.png'), fullPage: true });
    }
    // 两标签页并发的确定性时序：B 的读取快照停在 A 写日志前，模拟双方均读到空。
    // 恢复依赖每个请求的独立键，不依赖跨页 read→set 恰巧按顺序执行。
    const second = await page.context().newPage();
    second.on('pageerror', error => errors.push(error.stack || String(error)));
    await second.goto('http://pocketdesk.test/');
    await second.locator('[data-target-id="__sprite__"]').click();
    await second.waitForFunction(() => document.getElementById('workbench-notes').getAttribute('aria-busy') === 'false');
    await second.evaluate(() => {
      const known = new Map(Object.keys(localStorage).map(k => [k, localStorage.getItem(k)]));
      const original = Storage.prototype.getItem;
      Storage.prototype.getItem = function (key) {
        return key.startsWith('pocketdesk.workbench-note.v1:') ? (known.get(key) ?? null) : original.call(this, key);
      };
      window.restoreJournalReads = () => { Storage.prototype.getItem = original; };
    });
    miss = true; await page.locator('#text').fill('标签页 A 的断线原文'); await click('workbench-note-save');
    const lost = posts.at(-1);
    miss = false;
    await second.locator('#text').fill('标签页 B 的另一份正文'); await second.locator('#workbench-note-save').click();
    await second.waitForFunction(() => document.getElementById('workbench-notes').getAttribute('aria-busy') === 'false');
    await second.evaluate(() => window.restoreJournalReads());
    assert.notEqual(posts.at(-1).requestId, lost.requestId);
    assert.ok((await journals()).some(item => item.requestId === lost.requestId && item.state === 'pending'), 'B 成功不能覆盖 A 未知日志');
    await page.reload(); await select();
    assert.equal(await page.locator('#workbench-note-original').textContent(), lost.body);
    const beforeRetry = posts.length; await click('workbench-note-retry');
    assert.equal(posts.length, beforeRetry + 1); assert.deepEqual(posts.at(-1), lost);
    assert.ok((await journals()).every(item => item.state === 'succeeded'));
    await second.close();
    assert.deepEqual(errors, []); assert.deepEqual(desktopWrites, [], '随手记流程不触发旧 Agent 或桌面写入');
    const server = fs.readFileSync(path.join(root, 'Sources/Server.swift'), 'utf8');
    for (const asset of ['workbench-notes.js', 'workbench-notes.css']) assert.ok(server.includes('"' + asset + '"'), '新增资源必须注册');
    console.log('PASS: G1 手机全页流程、双标签页独立日志、原文预览、回执丢失、刷新只读恢复、原快照重试、身份隔离、存储门禁、附件拒绝、文本安全、响应式及零桌面副作用');
    if (!process.env.NO_SCREENSHOTS) console.log('截图（模拟后端，非生产/真机）：' + screenshots);
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });

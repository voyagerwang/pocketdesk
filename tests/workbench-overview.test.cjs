/**
 * [INPUT]: 真实手机首页、Playwright 与隔离 HTTP/WS 替身。
 * [OUTPUT]: G2 只读、授权/分页/成果/记忆、身份迟到、清理、文本安全及双尺寸截图。
 * [POS]: 不启动桌面服务、不读取生产数据、不声明真机验收完成。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '..');
const screenshots = fs.mkdtempSync(path.join(os.tmpdir(), 'pocketdesk-overview-ui-'));
async function main() {
  const browser = await chromium.launch({ headless: true, channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const page = await context.newPage(), errors = [], writes = [], reads = [];
    let allowed = false, pending = null, hold = false, wrong = false, empty = false;
    const envelope = projection => ({ protocolVersion: 1, authority: 'workbench', scopeRef: 'workbench:owner', generatedAt: '2026-09-22T02:03:04Z', projection });
    const task = { id: '20260922-1', objective: '整理发布验收清单 <img src=x onerror=alert(1)>', statusLabel: '需要处理', statusDetail: 'Codex 连接中断，未确认完成', executor: 'codex', attempt: 2, updatedAt: '2026-09-22T02:01:00Z', projectName: '工作台' };
    const tasks = { ...envelope('task_page'), tasks: [task], nextCursor: 20 };
    page.on('pageerror', e => errors.push(e.stack || String(e)));
    await context.addInitScript(() => {
      if (!localStorage.getItem('voicedeck.pair-token')) localStorage.setItem('voicedeck.pair-token', 'test-pair');
      class Socket {
        static OPEN = 1;
        constructor() { this.readyState = 0; this.bufferedAmount = 0; setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 1); }
        send(raw) { const m = JSON.parse(raw); if (m.t === 'auth') setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'auth_ok', session: 'test', controller: true, absolutePointerV1: true }) }), 1); }
        close() { this.readyState = 3; }
      }
      window.WebSocket = Socket;
    });
    await context.route('**/*', async route => {
      const req = route.request(), p = new URL(req.url()).pathname;
      const ok = (json, status = 200) => route.fulfill({ json, status });
      if (p.startsWith('/api/v1/workbench/views/')) {
        reads.push(p); assert.equal(req.method(), 'GET'); assert.match(req.headers().authorization || '', /^Bearer test-/);
        if (!allowed) return ok({ error: 'not authorized' }, 403);
        if (hold) { pending = route; return; }
        if (p.endsWith('/memories')) return ok({ ...envelope('memory_page'), instructions: '明确偏好，不自动记住普通聊天', entries: [{ content: '回答简洁 <script>bad()</script>', status: 'disabled', kind: 'preference', source: 'manual', updatedAt: task.updatedAt }], executionPreference: { executor: 'workbuddy', requestedModel: null, requestedCostPolicy: 'free_only', updatedAt: task.updatedAt }, hasMore: false });
        if (p.includes('/task-result/')) return ok({ ...envelope('task_result'), taskId: task.id, attempt: wrong ? 1 : 2, content: '# 当前轮成果\n<script>bad()</script>', truncated: true, reviewed: false });
        if (p.endsWith('/tasks/20')) return ok({ ...tasks, tasks: [{ ...task, id: '20260922-0', objective: '较早任务' }], nextCursor: null });
        return ok(empty ? { ...tasks, tasks: [], nextCursor: null } : tasks);
      }
      if (p.startsWith('/api/')) {
        if (req.method() === 'POST' && ['/api/live-input', '/api/send', '/api/v1/tasks', '/api/v1/workbench/notes'].includes(p)) writes.push(p);
        if (p === '/api/status') return ok({ targets: [{ id: 'wb', name: 'WorkBuddy' }], shortcuts: [], accessibility: true, theme: 'classic', frontmostName: '测试编辑器' });
        if (p === '/api/recipients') return ok({ order: ['__sprite__', 'wb'] });
        if (p === '/api/v1/phone-files') return ok({ files: [], revision: 'test' });
        if (p === '/api/screen/state') return ok({ locked: false });
        if (p === '/api/screen/displays') return ok({ displays: [], streamPort: 46389 });
        if (p === '/api/icon') return route.fulfill({ status: 404, body: '' });
        if (p.endsWith('/capabilities')) return ok({ error: 'G1未启用' }, 503);
        return ok({ ok: true });
      }
      const file = path.join(root, 'Web', p === '/' ? 'index.html' : p);
      if (!fs.existsSync(file)) return route.fulfill({ status: 404, body: '' });
      const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.svg': 'image/svg+xml', '.png': 'image/png' };
      return route.fulfill({ body: fs.readFileSync(file), contentType: types[path.extname(file)] || 'application/octet-stream' });
    });
    const panel = page.locator('#workbench-overview'), status = page.locator('#workbench-overview-status'), list = page.locator('#workbench-overview-list');
    const settled = () => page.waitForFunction(() => document.getElementById('workbench-overview').getAttribute('aria-busy') === 'false');
    const click = async selector => {
      await page.locator(selector).click();
      // details 的 toggle 在布局后派发，不能把派发前的 idle 当作读取完成。
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await settled();
    };
    await page.goto('http://pocketdesk.test/');
    await page.locator('[data-target-id="__sprite__"]').click();
    assert.equal(reads.length, 0, '未展开不读取私密投影');
    await click('#workbench-overview summary');
    assert.match(await status.textContent(), /机主只读授权/); assert.equal(await list.textContent(), '');
    allowed = true; await click('#workbench-overview-refresh');
    assert.match(await list.textContent(), /第 2 轮/); assert.equal(await list.locator('img').count(), 0);
    assert.match(await status.textContent(), /非实时/);
    await click('#workbench-overview-list button');
    assert.match(await page.locator('#workbench-overview-result').textContent(), /尚未验收/);
    assert.equal(await page.locator('#workbench-overview-result script').count(), 0);
    assert.match(await page.locator('#workbench-overview-result').textContent(), /仅展示前 100,000/);
    wrong = true; await click('#workbench-overview-list button');
    assert.match(await status.textContent(), /轮次已变化/); assert.equal(await list.textContent(), '');
    wrong = false; await click('#workbench-overview-refresh');
    await click('#workbench-overview-more'); assert.match(await list.textContent(), /较早任务/);
    assert.equal(await page.locator('#workbench-overview-more').isVisible(), false);
    await click('[data-workbench-view="memories"]');
    assert.match(await list.textContent(), /执行规则（独立于普通记忆）/); assert.match(await list.textContent(), /已停用/);
    assert.equal(await list.locator('script').count(), 0);
    assert.equal(await page.evaluate(() => Object.keys(localStorage).filter(k => k.includes('overview')).length), 0);
    await click('#workbench-overview summary'); assert.equal(await list.textContent(), '', '收起清除私密正文');
    await click('#workbench-overview summary');
    await page.evaluate(() => window.dispatchEvent(new Event('offline'))); await settled();
    assert.match(await status.textContent(), /离线/); assert.equal(await list.textContent(), '');
    await click('[data-workbench-view="tasks"]');
    // 旧配对的迟到回包不可进入新身份，跨代际时即使 fetch 没中止也必须隔离。
    hold = true; await page.locator('#workbench-overview-refresh').click();
    await page.waitForFunction(() => document.getElementById('workbench-overview').getAttribute('aria-busy') === 'true');
    while (!pending) await new Promise(resolve => setTimeout(resolve, 5));
    await page.evaluate(() => { localStorage.setItem('voicedeck.pair-token', 'test-other'); window.pocketdeskWorkbenchOverview.render(); });
    hold = false; await pending.fulfill({ json: tasks }); pending = null; await settled();
    assert.equal(await list.textContent(), ''); assert.match(await status.textContent(), /配对已变化/);
    await click('#workbench-overview-refresh');
    allowed = false; await click('#workbench-overview-refresh'); assert.equal(await list.textContent(), '', '撤权后不显示缓存');
    allowed = true; empty = true; await click('#workbench-overview-refresh'); assert.match(await list.textContent(), /暂无/);
    empty = false; await click('#workbench-overview-refresh');
    for (const width of [320, 390, 1100]) {
      await page.setViewportSize({ width, height: 900 });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${width}px 不得横向溢出`);
      const sizes = await panel.locator('button:visible').evaluateAll(elements => elements.map(el => el.getBoundingClientRect().height));
      assert(sizes.every(height => height >= 44), '触控目标至少 44px');
      if (!process.env.NO_SCREENSHOTS && width !== 320) {
        await panel.scrollIntoViewIfNeeded();
        await page.screenshot({ path: path.join(screenshots, width === 390 ? 'mobile.png' : 'desktop.png'), fullPage: true });
      }
    }
    assert.deepEqual(writes, []); assert.deepEqual(errors, []);
    console.log('G2 手机隔离回归通过；零任务/笔记/桌面写入。截图：' + screenshots);
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });

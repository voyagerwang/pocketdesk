/**
 * [INPUT]: 真实 agent-client/agent-panel 脚本，最小 DOM 与只在内存中的任务 API 替身。
 * [OUTPUT]: 验证按类型主动作、同任务重试和双击门禁、草稿优先补充、首页/全屏归属一致、换件事收起旧卡、无下一步时不凑文案，以及模型文字安全呈现。
 * [POS]: tests 的手机恢复交互回归；不连接真实服务、不触发桌面输入，实际布局由浏览器验收覆盖。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
  constructor(tag = 'div') {
    this.tagName = tag;
    this.children = [];
    this.attributes = {};
    this.dataset = {};
    this.events = {};
    this.hidden = false;
    this._text = '';
    this.classes = new Set();
    this.classList = { toggle: (name, enabled) => enabled ? this.classes.add(name) : this.classes.delete(name) };
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set innerHTML(_) { throw new Error('恢复文字不得解析为 HTML'); }
  append(...children) { this.children.push(...children); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] || null; }
  addEventListener(name, listener) { this.events[name] = listener; }
  click() { return this.events.click(); }
}

async function main() {
  const nodes = Object.fromEntries(['agent-panel', 'agent-status', 'agent-result', 'agent-sources',
    'agent-abandon', 'agent-continue', 'agent-primary', 'agent-action-error', 'agent-supplement', 'agent-new',
    'agent-compose-context', 'agent-compose-label', 'agent-compose-switch',
    'agent-compose-recover', 'agent-screen-context', 'agent-screen-label', 'agent-screen-switch',
    'agent-screen-recover', 'agent-screen-question', 'text', 'kb-proxy',
    'agent-page', 'agent-page-label', 'agent-page-clear'].map(id => [id, new Element()]));
  const orb = new Element();
  let draft = '', focused = 0;
  const calls = [];
  const tasks = {
    failed: { id: 'failed', status: 'failed', revision: 3, text: '上一句补充',
      error: '<img src=x onerror=alert(1)> 未找到目标窗口',
      messages: [{ role: 'user', text: '把完整报告交给个人工作台' }, { role: 'user', text: '上一句补充' }],
      sources: [{ url: 'javascript:alert(1)', title: '<script>danger</script>' }],
      recovery: { kind: 'clarification', headline: '需要你说明目标', nextStep: '请补充应用或窗口名称。', primaryAction: { kind: 'input', title: '补充信息' } } },
    capability: { id: 'capability', status: 'failed', text: '跨窗口合并重复标签', error: '当前仅支持分别清理各窗口。',
      recovery: { kind: 'capabilityLimit', headline: '当前能力有边界', primaryAction: { kind: 'input', title: '调整要求' } } },
    unconfirmed: { id: 'unconfirmed', status: 'submitted', revision: 4, text: '给电脑发送任务',
      result: '发送已尝试，接收还未核实。', recovery: { kind: 'unconfirmed', headline: '接收待核实', primaryAction: { kind: 'input', title: '核对结果' } } },
    retry: { id: 'retry', status: 'failed', revision: 2, text: '关闭客厅灯', error: '暂时没有连接上。',
      recovery: { kind: 'executionFailure', headline: '暂时没完成', primaryAction: { kind: 'retry', title: '再试一次' }, inputLabel: '补充说明' } },
    legacy: { id: 'legacy', status: 'failed', statusText: '未完成', text: '旧任务', error: '当时执行未成功。' },
    done: { id: 'done', status: 'succeeded', text: '已完成任务', result: '真实结果' }
  };
  tasks.pending = { ...tasks.retry, id: 'pending' };
  let resolveRetry;
  let lookupConfirmed = false;
  const sandbox = {
    Date, JSON, Math, URL,
    setTimeout: () => 0, clearTimeout: () => {},
    localStorage: { getItem: () => 'test-token' },
    sessionStorage: { getItem: () => null, setItem: () => {} },
    location: { href: 'http://phone.test/' },
    submittingDraft: false,
    liveValue: () => draft,
    document: { getElementById: id => nodes[id], createElement: tag => new Element(tag), querySelector: () => orb },
    window: { pocketdeskControlInfo: () => ({ session: 'test-controller' }),
      pocketdeskIsSpriteSelected: () => true, pocketdeskFocusCompose: () => { focused += 1; } },
    fetch: async (url, options) => {
      calls.push({ url, options });
      if (url === '/api/v1/tasks/retry/actions') return new Promise(resolve => { resolveRetry = resolve; });
      if (url === '/api/v1/tasks/pending/actions') throw new Error('连接中断');
      if (url.startsWith('/api/v1/tasks/by-request/')) {
        if (!lookupConfirmed) throw new Error('暂时无法核对');
        return { ok: true, status: 200, text: async () => JSON.stringify({ task: { id: 'pending', status: 'running', revision: 3 } }) };
      }
      const task = url.endsWith('/actions')
        ? { id: 'unconfirmed', status: 'accepted', revision: 5 }
        : tasks[url.split('/').pop()];
      return { ok: true, status: 200, text: async () => JSON.stringify({ task }) };
    }
  };
  vm.createContext(sandbox);
  for (const file of ['agent-client.js', 'agent-panel.js'])
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Web', file), 'utf8'), sandbox);
  const agent = sandbox.window.pocketdeskAgent, panel = sandbox.window.pocketdeskAgentPanel;
  await agent.resume('failed');
  panel.init();
  assert.equal(nodes['agent-panel'].hidden, false);
  assert.match(nodes['agent-status'].textContent, /需要你说明目标/);
  assert.match(nodes['agent-result'].textContent, /刚才：把完整报告交给个人工作台/, '补充期间显示原目标，不以最新解释冒充原任务');
  assert.match(nodes['agent-result'].textContent, /<img src=x onerror=alert\(1\)> 未找到目标窗口/, '失败原因直接可见且作为纯文字');
  assert.match(nodes['agent-result'].textContent, /请补充应用或窗口名称/);
  assert.equal(nodes['agent-result'].children.some(child => child.tagName === 'details'), false, '恢复原因不藏进结果折叠');
  assert.equal(nodes['agent-sources'].children[0].children[1].tagName, 'span', '不可信来源地址不能变为可执行链接');
  assert.equal(nodes['agent-primary'].textContent, '补充信息');
  assert.equal(nodes['agent-supplement'].hidden, true, '主动作已是输入时不重复补充按钮');
  assert.equal(nodes['agent-compose-label'].textContent, nodes['agent-screen-label'].textContent);

  draft = '我指的是报告页面';
  panel.render();
  assert.equal(nodes['agent-panel'].hidden, false, '解释输入时原任务和输入归属仍可见');
  assert.equal(nodes['agent-compose-context'].hidden, false);
  nodes['agent-compose-switch'].click();
  assert.equal(draft, '我指的是报告页面', '选新任务保留草稿');
  assert.equal(agent.current().id, 'failed', '选新任务不删除原任务');
  assert.equal(nodes['agent-panel'].hidden, true, '换件事后旧失败卡立即收起');
  assert.equal(nodes['agent-compose-label'].textContent, '说件新事情');
  assert.equal(nodes['agent-screen-switch'].textContent, '返回刚才');
  nodes['agent-screen-switch'].click();
  assert.equal(draft, '我指的是报告页面', '选补充保留草稿');
  assert.match(nodes['agent-compose-label'].textContent, /接着说.*把完整报告交给个人工作台/);
  assert.equal(nodes['agent-panel'].classes.has('is-editing'), true, '进入补充后任务卡收紧');
  assert.equal(nodes['agent-panel'].classes.has('is-question'), true, '澄清问题在收紧态仍须保留');
  assert.match(nodes['agent-screen-question'].textContent, /未找到目标窗口/, '全屏编辑器旁保留要回答的问题');
  assert.equal(focused, 2, '两个动作均复用现有原生输入框聚焦路径');

  await agent.resume('capability');
  draft = ''; panel.render();
  assert.equal(nodes['agent-primary'].textContent, '调整要求', '能力限制不会承诺再次执行即可修复');
  assert.match(nodes['agent-result'].textContent, /当前仅支持分别清理各窗口/);
  await agent.resume('legacy');
  assert.equal(nodes['agent-primary'].textContent, '补充信息', '旧任务没有恢复结构时保守保留输入入口');
  assert.equal(nodes['agent-result'].children.length, 2, '没有实际下一步时不凑通用说明');
  await agent.resume('unconfirmed');
  assert.equal(nodes['agent-primary'].textContent, '核对结果');
  await nodes['agent-primary'].click();
  assert.equal(calls.filter(call => call.options?.method === 'POST').length, 0, '未知发送仅聚焦输入，不自动重发');
  await agent.send('刚才的任务收到没有？');
  const post = calls.find(call => call.options?.method === 'POST');
  assert.equal(post.url, '/api/v1/tasks/unconfirmed/actions');
  assert.equal(JSON.parse(post.options.body).action, 'supplement', '未知发送不另建任务盲重发');

  await agent.resume('retry');
  draft = '实际是卧室灯'; panel.render();
  const previousPosts = calls.filter(call => call.options?.method === 'POST').length;
  await nodes['agent-primary'].click();
  assert.equal(calls.filter(call => call.options?.method === 'POST').length, previousPosts, '已有草稿时转补充，不能忽略正文重试');
  assert.equal(draft, '实际是卧室灯');
  draft = ''; await agent.resume('legacy'); await agent.resume('retry');
  const retrying = nodes['agent-primary'].click();
  assert.equal(nodes['agent-primary'].disabled, true, '请求开始同步锁定主动作');
  assert.equal(nodes['agent-compose-switch'].disabled, true);
  await nodes['agent-primary'].click();
  assert.equal(calls.filter(call => call.url === '/api/v1/tasks/retry/actions').length, 1, '双击不产生第二次请求');
  const retryBody = JSON.parse(calls.find(call => call.url === '/api/v1/tasks/retry/actions').options.body);
  assert.equal(retryBody.action, 'supplement');
  assert.equal(retryBody.text, '继续处理刚才的请求');
  resolveRetry({ ok: true, status: 200, text: async () => JSON.stringify({ task: { id: 'retry', status: 'accepted', revision: 3 } }) });
  await retrying;

  await agent.resume('pending');
  await nodes['agent-primary'].click();
  assert.equal(agent.hasPendingRetry(), true);
  draft = '我想补充其他线索'; panel.render();
  assert.equal(nodes['agent-compose-recover'].hidden, false, '已有新草稿仍保留核对上次提交入口');
  assert.equal(nodes['agent-screen-recover'].hidden, false);
  assert.equal(nodes['agent-compose-switch'].hidden, true, '未知接收期间先核对，不能换件事绕过票据');
  assert.match(nodes['agent-compose-label'].textContent, /输入内容会保留/);
  lookupConfirmed = true;
  await nodes['agent-compose-recover'].click();
  assert.equal(draft, '我想补充其他线索', '核对仅处理上次提交，不消费当前草稿');
  assert.equal(calls.filter(call => call.url === '/api/v1/tasks/pending/actions').length, 1, '核对发现已接收，不再POST');
  assert.equal(agent.current().status, 'running');

  await agent.resume('done');
  draft = '下一项'; panel.render();
  assert.equal(nodes['agent-panel'].hidden, true, '正常完成后的新草稿仍隐藏旧结果');
  draft = ''; panel.render();
  assert.equal(nodes['agent-panel'].hidden, false);
  assert.equal(nodes['agent-supplement'].hidden, true);
  assert.equal(nodes['agent-new'].hidden, true);
  assert.equal(nodes['agent-compose-context'].hidden, true);
  assert.equal(nodes['agent-result'].children[1].tagName, 'details', '正常完成保留结果折叠');
}

main().then(() => console.log('agent recovery: 主动作/双击门禁/草稿保护/双输入归属/能力边界/未知发送/XSS 全部通过'))
  .catch(error => { console.error(error); process.exit(1); });

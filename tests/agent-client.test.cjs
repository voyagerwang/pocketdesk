/**
 * [INPUT]: 读取 Web/agent-client.js 源码，在 vm 沙箱里注入最小 window/localStorage/fetch 替身。
 * [OUTPUT]: 断言默认续接与明确换件事、服务端明确重试及未知结果拒绝、同任务稳定票据/丢包查账和忙碌门禁、旧查询隔离；保留有界轮询并检查双输入归属落点。
 * [POS]: tests 的 Web 客户端测试；不启动浏览器、不连真实服务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
'use strict';
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'Web', 'agent-client.js'), 'utf8');
const panelSource = fs.readFileSync(path.join(__dirname, '..', 'Web', 'agent-panel.js'), 'utf8');
const indexSource = fs.readFileSync(path.join(__dirname, '..', 'Web', 'index.html'), 'utf8');

function makeClient(handler) {
  const calls = [];
  const sandbox = {
    console,
    JSON,
    Math,
    Date,
    setTimeout: () => 0,          // 轮询定时器不真跑：本测试只断言节奏计算
    clearTimeout: () => {},
    fetch: async (url, options) => {
      calls.push({ url, options });
      return handler(url, options, calls.length);
    },
    localStorage: { getItem: () => 'test-token', setItem: () => {} },
    location: { href: 'https://phone.local/' },
    window: { pocketdeskControlInfo: () => ({ session: "controller-test" }) },
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { agent: sandbox.window.pocketdeskAgent, calls };
}

function okJSON(payload) {
  return { ok: true, status: 200, text: async () => JSON.stringify(payload) };
}

async function main() {
  // 1) 提交：必须带 requestId 与正文，并附上配对 token
  {
    const { agent, calls } = makeClient(() => okJSON({ task: { id: 't-1', status: 'accepted', revision: 1 } }));
    const task = await agent.submit('总结这一页', { url: 'https://a.test', title: 'A' });
    assert.strictEqual(task.id, 't-1', '应返回服务端任务');
    const body = JSON.parse(calls[0].options.body);
    assert.ok(body.requestId, '提交必须带 requestId：超时后靠它找回原任务');
    assert.strictEqual(body.text, '总结这一页');
    assert.strictEqual(body.context.url, 'https://a.test');
    assert.strictEqual(calls[0].options.headers.Authorization, 'Bearer test-token', '任务接口必须带 Bearer');
  }
  
  // 2) 提交失败先按同一 requestId 查账，绝不盲发新任务
  {
    let first = true;
    const { agent, calls } = makeClient((url) => {
      if (url === '/api/v1/tasks' && first) {
        first = false;
        // 模拟请求已落到 Mac、但回包丢了
        return { ok: false, status: 502, text: async () => '{"error":"bad gateway"}' };
      }
      if (url.startsWith('/api/v1/tasks/by-request/')) {
        return okJSON({ task: { id: 't-existing', status: 'running', revision: 2 } });
      }
      return okJSON({ task: { id: 't-new', status: 'accepted', revision: 1 } });
    });
    const task = await agent.submit('同一句话', null);
    assert.strictEqual(task.id, 't-existing', '回包丢失时应找回原任务，而不是创建第二个');
    assert.ok(calls.some(c => c.url.startsWith('/api/v1/tasks/by-request/')), '失败后必须发查账请求');
  }
  
  // 3) 查账也没有时才把错误抛出去，让界面显示真实原因
  {
    const { agent } = makeClient((url) => {
      if (url === '/api/v1/tasks') return { ok: false, status: 500, text: async () => '{"error":"服务端炸了"}' };
      return { ok: false, status: 404, text: async () => '{"error":"这个请求没有对应任务。"}' };
    });
    let thrown = null;
    try { await agent.submit('x', null); } catch (error) { thrown = error; }
    assert.ok(thrown, '查账也失败时应抛出错误');
    assert.match(thrown.message, /服务端炸了/, '错误信息应是服务端人话');
  }
  
  // 4) 轮询节奏：2s 起、1.5 倍退避、上限 10s（方案 §9 默认值）
  {
    const { agent } = makeClient(() => okJSON({ task: { id: 't', status: 'accepted' } }));
    const c = agent._constants;
    assert.strictEqual(c.POLL_START, 2000, '轮询起始 2s');
    assert.strictEqual(c.POLL_MAX, 10000, '轮询上限 10s');
    assert.strictEqual(c.POLL_FACTOR, 1.5, '退避系数 1.5');
    agent._resetPoll();
    assert.strictEqual(agent._pollInterval(), 2000, '重置后回到 2s');
  }
  
  // 5) 活动状态判定：只有终态才允许追问
  {
    const { agent } = makeClient(() => okJSON({ task: { id: 't', status: 'accepted' } }));
    await agent.submit('x', null);
    assert.strictEqual(agent.isActive(), true, 'accepted 属于活动状态');
  }

  // 6) 结果待核对仍是活动任务：不能停轮询，也不能允许并行新建。
  {
    const { agent } = makeClient(() => okJSON({ task: { id: 'verify', status: 'verifying', revision: 3 } }));
    await agent.submit('open', null);
    assert.strictEqual(agent.isActive(), true, 'verifying 必须属于活动状态');
  }

  // 7) 页面刷新后从 Mac 任务事实源找回最新活动任务，再拉完整快照。
  {
    const { agent, calls } = makeClient((url) => {
      if (url === '/api/v1/tasks?cursor=0') return okJSON({ tasks: [
        { id: 'done', status: 'succeeded' },
        { id: 'pending', status: 'running' }
      ] });
      if (url === '/api/v1/tasks/pending') return okJSON({ task: { id: 'pending', status: 'running' } });
      throw new Error('unexpected ' + url);
    });
    const task = await agent.recoverActive();
    assert.strictEqual(task.id, 'pending', '应找回进行中任务');
    assert.ok(calls.some(c => c.url === '/api/v1/tasks/pending'), '必须拉完整快照');
  }

  // 正常完成之后直接发送仍创建新任务。
  for (const status of ['succeeded', 'abandoned']) {
    const { agent, calls } = makeClient((url) => url === '/api/v1/tasks/old'
      ? okJSON({ task: { id: 'old', status } })
      : okJSON({ task: { id: 'new', status: 'accepted' } }));
    await agent.resume('old');
    await agent.send('打开 Codex');
    assert.equal(calls[1].url, '/api/v1/tasks');
    assert.equal(JSON.parse(calls[1].options.body).controlSession, 'controller-test');
  }
  {
    const { agent, calls } = makeClient(() => okJSON({ task: { id: 'old', status: 'running' } }));
    await agent.resume('old');
    await assert.rejects(agent.send('第二项'), /正在执行/);
    assert.equal(calls.length, 1, '执行中不能产生第二条请求');
  }
  for (const status of ['failed', 'needsInput', 'submitted']) {
    const { agent, calls } = makeClient(() => okJSON({ task: { id: 'old', status, revision: 2, updatedAt: 1 } }));
    await agent.resume('old');
    assert.equal(agent.inputMode(), 'supplement', '未完成默认解释原任务');
    await agent.send('我指的是第二个窗口');
    assert.equal(calls[1].url, '/api/v1/tasks/old/actions', '补充直接续接原任务，不受旧候选时效影响');
    const body = JSON.parse(calls[1].options.body);
    assert.equal(body.action, 'supplement');
    assert.equal(body.text, '我指的是第二个窗口');
    assert.equal(body.expectedRevision, 2);
    assert.equal(body.controlSession, 'controller-test', '补充沿用当前控制凭证');
    assert.ok(body.requestId, '补充必须有可查账的幂等票据');
    assert.ok(!('previousTaskId' in body), '明确补充不能重新进入输入关系分类');
  }
  for (const status of ['failed', 'needsInput', 'submitted']) {
    const { agent, calls } = makeClient((url) => url === '/api/v1/tasks/old'
      ? okJSON({ task: { id: 'old', status, revision: 2 } })
      : okJSON({ task: { id: 'new', status: 'accepted' } }));
    await agent.resume('old');
    agent.chooseInput('new');
    assert.equal(agent.current().id, 'old', '选择新任务时旧任务与结果仍保留');
    assert.equal(agent.inputMode(), 'new');
    await agent.send('打开日历');
    assert.equal(calls[1].url, '/api/v1/tasks', '明确新任务有独立入口');
    assert.equal(agent.current().id, 'new');
  }
  {
    const { agent } = makeClient(() => okJSON({ task: { id: 'old', status: 'failed', revision: 2 } }));
    await agent.resume('old');
    agent.chooseInput('new');
    await agent.refresh();
    assert.equal(agent.inputMode(), 'new', '轮询同一任务不能覆盖明确输入归属');
    agent.chooseInput('supplement');
    assert.equal(agent.inputMode(), 'supplement', '发送前仍可改回补充解释');
  }
  {
    const { agent, calls } = makeClient((url) => {
      if (url === '/api/v1/tasks/old') return okJSON({ task: { id: 'old', status: 'failed', revision: 2 } });
      if (url.endsWith('/actions')) throw new Error('回包丢失');
      if (url.startsWith('/api/v1/tasks/by-request/')) return okJSON({ task: { id: 'old', status: 'running', revision: 3 } });
      throw new Error('unexpected ' + url);
    });
    await agent.resume('old');
    const task = await agent.send('不是飞书，是微信');
    assert.equal(task.id, 'old', '补充回包丢失后恢复同一任务');
    const body = JSON.parse(calls[1].options.body);
    assert.equal(calls[2].url, '/api/v1/tasks/by-request/' + body.requestId);
    assert.equal(calls.filter(c => c.options?.method === 'POST').length, 1, '丢包只查账，不重派');
  }
  {
    let attempts = 0;
    const { agent, calls } = makeClient((url) => {
      if (url === '/api/v1/tasks/old') return okJSON({ task: { id: 'old', status: 'failed', revision: 2 } });
      if (url.endsWith('/actions')) {
        attempts += 1;
        if (attempts === 1) throw new Error('断线');
        return okJSON({ task: { id: 'old', status: 'accepted', revision: 3 } });
      }
      return { ok: false, status: 404, text: async () => '{"error":"没有对应请求"}' };
    });
    await agent.resume('old');
    await assert.rejects(agent.send('具体指手机窗口'), /断线/);
    await assert.rejects(agent.send('另一段解释'), /上一段内容是否收到还未核实/, '未知接收状态不把新正文塞进旧票据');
    await agent.send('具体指手机窗口');
    const posts = calls.filter(c => c.options?.method === 'POST').map(c => JSON.parse(c.options.body));
    assert.equal(posts.length, 2);
    assert.equal(posts[0].requestId, posts[1].requestId, '再次发送同一补充重用原票据');
    assert.equal(posts[0].text, posts[1].text);
  }
  {
    const { agent, calls } = makeClient((url) => {
      if (url === '/api/v1/tasks/old') return okJSON({ task: { id: 'old', status: 'failed', revision: 2 } });
      return { ok: false, status: 409, text: async () => '{"error":"任务已被更新"}' };
    });
    await agent.resume('old');
    await assert.rejects(agent.send('解释'), /任务已被更新/);
    assert.equal(agent.current().id, 'old', '拒绝后保留原任务');
    assert.equal(calls.length, 2, '明确拒绝不查出旧任务冒充成功，不自动重发');
    agent.chooseInput('new');
    await assert.rejects(agent.send('独立请求'), /任务已被更新/);
    const posts = calls.filter(c => c.options?.method === 'POST').map(c => JSON.parse(c.options.body));
    assert.notEqual(posts[0].requestId, posts[1].requestId, '明确拒绝后新正文使用独立票据');
  }
  {
    let release;
    const { agent } = makeClient((url) => {
      if (url === '/api/v1/tasks') return okJSON({ task: { id: 'new', status: 'accepted' } });
      if (release) return new Promise(resolve => { release.resolve = resolve; });
      return okJSON({ task: { id: 'old', status: 'succeeded' } });
    });
    await agent.resume('old');
    release = {};
    const refreshing = agent.refresh();
    await agent.send('新任务');
    release.resolve(okJSON({ task: { id: 'old', status: 'succeeded' } }));
    await refreshing;
    assert.equal(agent.current().id, 'new', '旧查询不能覆盖新任务');
  }
  // 显式重试仍是原任务补充；丢包后换件事不丢票据，返回重试复用原票据。
  {
    let tries = 0;
    const { agent, calls } = makeClient((url) => {
      if (url === '/api/v1/tasks/retry') return okJSON({ task: { id: 'retry', status: 'failed', revision: 4,
        recovery: { kind: 'executionFailure', primaryAction: { kind: 'retry', title: '再试一次' } } } });
      if (url.endsWith('/actions')) {
        if (++tries === 1) throw new Error('连接中断');
        return okJSON({ task: { id: 'retry', status: 'accepted', revision: 5 } });
      }
      return { ok: false, status: 404, text: async () => '{}' };
    });
    await agent.resume('retry');
    const failing = agent.retry();
    assert.equal(agent.isRetrying(), true);
    assert.throws(() => agent.chooseInput('new'), /正在提交/);
    await assert.rejects(agent.retry(), /正在提交/);
    await assert.rejects(failing, /连接中断/);
    assert.equal(agent.isRetrying(), false);
    assert.equal(agent.hasPendingRetry(), true);
    assert.throws(() => agent.chooseInput('new'), /先核对上次提交/);
    await assert.rejects(agent.send('新的补充'), /上一段内容是否收到还未核实/);
    agent.restoreInput();
    assert.equal(agent.hasInputChoice(), false, '空草稿返回时恢复原动作入口');
    await agent.retry();
    const posts = calls.filter(call => call.options?.method === 'POST').map(call => ({ url: call.url, body: JSON.parse(call.options.body) }));
    assert.equal(posts.length, 2);
    assert.equal(posts[0].url, '/api/v1/tasks/retry/actions');
    assert.equal(posts[0].body.action, 'supplement');
    assert.equal(posts[0].body.text, '继续处理刚才的请求');
    assert.equal(posts[0].body.requestId, posts[1].body.requestId);
    assert.equal(posts[0].body.controlSession, 'controller-test');
  }
  // 同任务旧轮询迟到不能覆盖刚接收的补充；提交中禁止更改输入归属。
  {
    let reads = 0, releaseGet, releasePost;
    const { agent } = makeClient((url) => {
      if (url.endsWith('/actions')) return new Promise(resolve => { releasePost = resolve; });
      if (++reads === 1) return okJSON({ task: { id: 'same', status: 'needsInput', revision: 4 } });
      return new Promise(resolve => { releaseGet = resolve; });
    });
    await agent.resume('same');
    const stale = agent.refresh();
    const sending = agent.send('选择第二项');
    assert.equal(agent.isSubmitting(), true);
    assert.throws(() => agent.chooseInput('new'), /正在提交/);
    assert.throws(() => agent.restoreInput(), /正在提交/);
    releasePost(okJSON({ task: { id: 'same', status: 'accepted', revision: 5 } }));
    await sending;
    releaseGet(okJSON({ task: { id: 'same', status: 'needsInput', revision: 4 } }));
    await stale;
    assert.equal(agent.current().status, 'accepted');
    assert.equal(agent.current().revision, 5);
  }
  for (const recovery of [undefined, { kind: 'clarification' }, { kind: 'unconfirmed', primaryAction: { kind: 'retry' } }]) {
    const { agent, calls } = makeClient(() => okJSON({ task: { id: 'blocked', status: 'failed', recovery } }));
    await agent.resume('blocked');
    await assert.rejects(agent.retry(), /请先补充信息/);
    assert.equal(calls.length, 1, '旧服务或未知结果不能推测安全重试');
  }
  // 补充已被接收但回包丢失时，轮询可能先返回 running；核对仍须可用。
  {
    let readCount = 0, postCount = 0, lookupCount = 0;
    const { agent, calls } = makeClient((url) => {
      if (url.endsWith('/actions')) {
        if (++postCount === 1) throw new Error('回包丢失');
        return okJSON({ task: { id: 'poll-race', status: 'accepted', revision: 5 } });
      }
      if (url.includes('/by-request/')) {
        if (++lookupCount === 1) throw new Error('查账中断');
        return { ok: false, status: 404, text: async () => '{}' };
      }
      return okJSON({ task: ++readCount === 1
        ? { id: 'poll-race', status: 'needsInput', revision: 4,
            recovery: { kind: 'prerequisite', primaryAction: { kind: 'retry' } } }
        : { id: 'poll-race', status: 'running', revision: 5 } });
    });
    await agent.resume('poll-race');
    await assert.rejects(agent.retry(), /回包丢失/);
    await agent.refresh();
    assert.equal(agent.current().status, 'running');
    await agent.retry();
    const bodies = calls.filter(call => call.url.endsWith('/actions')).map(call => JSON.parse(call.options.body));
    assert.deepEqual(bodies[0], bodies[1], '恢复原提交不使用轮询更新后的revision或新正文');
    assert.equal(agent.current().revision, 5);
  }
  for (const id of ['agent-primary', 'agent-supplement', 'agent-new', 'agent-compose-context', 'agent-screen-context'])
    assert.ok(indexSource.includes('id="' + id + '"'), '恢复操作及输入归属必须有可见落点：' + id);

  // 8) 父层面板默认 hidden 时，渲染必须有显式解除路径；只显示内层 approval 没用。
  assert.match(indexSource, /id="agent-panel"[^>]*hidden/, 'HTML 启动时默认隐藏任务卡');
  assert.match(panelSource, /el\.panel\.hidden\s*=\s*!task/, '渲染任务后必须显式解除父层 hidden');
}

main().then(() => {
  console.log('agent client: 补充归属/新任务出口/幂等票据/丢包查账/冲突拒绝/轮询隔离 全部通过');
}).catch(error => {
  console.error(error);
  process.exit(1);
});

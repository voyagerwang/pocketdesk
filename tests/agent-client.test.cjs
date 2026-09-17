/**
 * [INPUT]: 读取 Web/agent-client.js 源码，在 vm 沙箱里注入最小 window/localStorage/fetch 替身。
 * [OUTPUT]: 断言终态直接新建、待补充续接、旧回执隔离及小精灵任务客户端的提交去重、失败查账、轮询退避、待确认活动态与刷新找回，并静态锁住任务面板会解除父层 hidden。
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

  // 终态之后直接发送必须创建新任务，不能进入旧任务的补充次数限制。
  for (const status of ['succeeded', 'failed', 'abandoned']) {
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
  {
    const { agent, calls } = makeClient(() => okJSON({ task: { id: 'old', status: 'needsInput', revision: 2 } }));
    await agent.resume('old');
    await agent.send('选择第一个');
    assert.equal(calls[1].url, '/api/v1/tasks/old/actions', '待补充继续原任务');
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
  assert.ok(!indexSource.includes('id="agent-new"'), '无需新任务按钮');

  // 8) 父层面板默认 hidden 时，渲染必须有显式解除路径；只显示内层 approval 没用。
  assert.match(indexSource, /id="agent-panel"[^>]*hidden/, 'HTML 启动时默认隐藏任务卡');
  assert.match(panelSource, /el\.panel\.hidden\s*=\s*!task/, '渲染任务后必须显式解除父层 hidden');
}

main().then(() => {
  console.log('agent client: 提交去重/失败查账/轮询退避/活动判定 全部通过');
}).catch(error => {
  console.error(error);
  process.exit(1);
});

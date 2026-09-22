/**
 * [INPUT]: 读取 Web/agent-client.js 源码，在 vm 沙箱里注入最小 window/localStorage/fetch 替身。
 * [OUTPUT]: 断言缺事件时按修订读回终态、跨刷新查账/存储门禁、并发与配对隔离、新建/续接及恢复代际；静态锁住面板解除 hidden。
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

function makeClient(handler, storage = new Map()) {
  const calls = [], timers = [];
  let pairing = 'test-token';
  const sandbox = {
    console,
    JSON,
    Math,
    Date,
    crypto: require('node:crypto').webcrypto,
    Uint32Array,
    AbortController,
    setTimeout: callback => { timers.push(callback); return timers.length; }, // 不自动触发；专项显式推进 tick
    clearTimeout: () => {},
    fetch: async (url, options) => {
      if (url === '/api/v1/tasks/identity') return okJSON({ protocolVersion: 1,
        journalScope: 'pocketdesk:' + require('node:crypto').createHash('sha256').update(pairing).digest('hex') });
      calls.push({ url, options });
      const response = await handler(url, options, calls.length);
      const originalText = response.text;
      response.text = async () => {
        const payload = JSON.parse(await originalText());
        if (payload.task && payload.task.requestId === undefined) {
          if (url === '/api/v1/tasks') payload.task.requestId = JSON.parse(options.body).requestId;
          else if (url.startsWith('/api/v1/tasks/by-request/')) payload.task.requestId = decodeURIComponent(url.split('/').pop());
        }
        return JSON.stringify(payload);
      };
      return response;
    },
    localStorage: { get length() { return storage.size; }, key: n => [...storage.keys()][n] || null,
      getItem: key => key === 'voicedeck.pair-token' ? pairing : storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    location: { href: 'https://phone.local/' },
    window: { pocketdeskControlInfo: () => ({ session: "controller-test" }) },
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { agent: sandbox.window.pocketdeskAgent, calls, timers, storage, localStorage: sandbox.localStorage, setPairing: value => { pairing = value; } };
}

async function until(ready) {
  for (let n = 0; n < 100 && !ready(); n++) await Promise.resolve();
  assert(ready(), 'expected async request to start');
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

  // 事件可能没落盘，状态不能只靠事件存在来推进；旧服务缺修订也只读补快照。
  for (const taskRevision of [2, undefined]) {
    const client = makeClient(url => {
      if (url === '/api/v1/tasks') return okJSON({ task: { id: 'revision-task', status: 'accepted', revision: 1 } });
      if (url.includes('/events?')) return okJSON({ events: [], needRefresh: false, taskRevision });
      return okJSON({ task: { id: 'revision-task', status: 'succeeded', revision: 2, result: '真实快照成果' } });
    });
    await client.agent.submit('事件丢失', null);
    await client.timers.findLast(callback => callback.name === 'tick')();
    assert.equal(client.agent.current().status, 'succeeded');
    assert.equal(client.agent.current().result, '真实快照成果');
    assert.equal(client.calls.filter(call => call.options.method === 'POST').length, 1);
  }

  // 未确认旧请求与新正文必须分开，不能把旧成功当作新正文已接收。
  {
    let recovered = false;
    const { agent, calls } = makeClient(url => {
      if (url === '/api/v1/tasks') throw new Error('模拟断线');
      return recovered ? okJSON({ task: { id: 'original', status: 'running' } })
        : { ok: false, status: 404, text: async () => '{"error":"尚未找到"}' };
    });
    await assert.rejects(agent.submit('原正文', null), /模拟断线/);
    const original = JSON.parse(calls[0].options.body);
    agent.detach();
    await assert.rejects(agent.submit('新正文', null), /仍未知/);
    assert.equal(calls.filter(c => c.url === '/api/v1/tasks').length, 1);
    await assert.rejects(agent.submit('原正文', null), /模拟断线/);
    assert.deepEqual(JSON.parse(calls.findLast(c => c.url === '/api/v1/tasks').options.body), original);
    recovered = true;
    await assert.rejects(agent.submit('新正文', null), /本次修改后的正文未发送/);
    assert.equal(agent.current().id, 'original');
  }
  {
    let release;
    const { agent, calls } = makeClient(() => new Promise(resolve => { release = resolve; }));
    const first = agent.submit('并发同文', null), second = agent.submit('并发同文', null);
    await assert.rejects(agent.submit('另一个请求', null), /前一条提交/);
    await until(() => release);
    release(okJSON({ task: { id: 'single', status: 'accepted' } }));
    assert.equal((await first).id, 'single'); assert.equal((await second).id, 'single');
    assert.equal(calls.length, 1);
  }
  {
    let release;
    const { agent, setPairing } = makeClient(url => url === '/api/v1/tasks'
      ? new Promise(resolve => { release = resolve; })
      : { ok: false, status: 404, text: async () => '{}' });
    const pending = agent.submit('旧配对请求', null);
    await until(() => release);
    setPairing('new-pair'); release(okJSON({ task: { id: 'wrong-owner', status: 'accepted' } }));
    await assert.rejects(pending, /配对已变化/); assert.equal(agent.current(), null);
  }

  // 全新 JS 实例模拟刷新：按持久编号只读查账，不能恢复到无关的最新任务。
  {
    const first = makeClient(() => { throw new Error('离线'); });
    await assert.rejects(first.agent.submit('刷新前原文', { url: 'https://original.test' }), /离线/);
    const body = JSON.parse(first.calls[0].options.body);
    const refreshed = makeClient(url => {
      assert.equal(url, '/api/v1/tasks/by-request/' + body.requestId);
      return okJSON({ task: { id: 'original', requestId: body.requestId, status: 'succeeded' } });
    }, first.storage);
    await refreshed.agent.recoverActive();
    assert.equal(refreshed.agent.current().id, 'original');
    assert.equal(refreshed.calls.filter(c => c.options.method === 'POST').length, 0);
    assert(![...first.storage.values()].some(raw => raw.includes('刷新前原文')), '确认后清除正文副本');
  }
  {
    const first = makeClient(() => { throw new Error('离线'); });
    await assert.rejects(first.agent.submit('必须同一正文', { url: 'https://original.test', observedAt: 1 }), /离线/);
    const original = JSON.parse(first.calls[0].options.body);
    const refreshed = makeClient(url => url === '/api/v1/tasks'
      ? okJSON({ task: { id: 'retry-original', status: 'accepted' } })
      : { ok: false, status: 404, text: async () => '{}' }, first.storage);
    await refreshed.agent.recoverActive();
    assert.equal(refreshed.calls.length, 1); assert(refreshed.calls[0].url.includes('/by-request/'));
    await assert.rejects(refreshed.agent.send('改过的新正文'), /仍未知/);
    refreshed.agent.bindPage({ url: 'https://now-different.test', observedAt: 9 });
    await refreshed.agent.send('必须同一正文');
    assert.deepEqual(JSON.parse(refreshed.calls.find(c => c.url === '/api/v1/tasks').options.body), original, '刷新重试仍用原网页/控制会话');
  }
  {
    const client = makeClient(() => okJSON({ task: { id: 'must-not-run', status: 'accepted' } }));
    client.localStorage.setItem = () => { throw new Error('QuotaExceeded'); };
    await assert.rejects(client.agent.submit('不能丢关联', null), /本次未发送/);
    assert.equal(client.calls.length, 0, '恢复记录落不了盘不得发副作用');
  }
  {
    const client = makeClient(url => url === '/api/v1/tasks'
      ? okJSON({ task: { id: 'wrong', requestId: 'wrong-request', status: 'accepted' } })
      : { ok: false, status: 404, text: async () => '{}' });
    await assert.rejects(client.agent.submit('正确请求', null), /编号不匹配/);
    assert.equal(client.agent.current(), null);
    assert([...client.storage.values()].some(raw => JSON.parse(raw).state === 'pending'));
  }
  {
    const old = makeClient(() => { throw new Error('离线'); });
    await assert.rejects(old.agent.submit('旧主体正文', null));
    const fresh = makeClient(() => okJSON({ tasks: [] }), old.storage);
    fresh.setPairing('different-owner'); await fresh.agent.recoverActive();
    assert(!fresh.calls.some(c => c.url.includes('/by-request/')), '新配对不查旧主体记录');
    assert([...old.storage.values()].some(raw => raw.includes('旧主体正文')), '切换配对不能删除旧主体待确认记录');
  }

  // 8) 父层面板默认 hidden 时，渲染必须有显式解除路径；只显示内层 approval 没用。
  {
    let release;
    const client = makeClient(url => url === '/api/v1/tasks?cursor=0'
      ? new Promise(resolve => { release = resolve; })
      : okJSON({ task: { id: 'new', status: 'accepted' } }));
    const restoring = client.agent.recoverActive();
    await until(() => release);
    await client.agent.submit('刚提交的新任务', null);
    release(okJSON({ tasks: [{ id: 'old', status: 'running' }] }));
    await restoring;
    assert.equal(client.agent.current().id, 'new');
    assert(!client.calls.some(c => c.url === '/api/v1/tasks/old'), '过时的启动恢复不得查回并覆盖新任务');
  }
  {
    let release;
    const client = makeClient(() => new Promise(resolve => { release = resolve; }));
    const restoring = client.agent.resume('old');
    await until(() => release); client.agent.detach();
    release(okJSON({ task: { id: 'old', status: 'running' } }));
    await restoring;
    assert.equal(client.agent.current(), null, '解绑后迟到查询不得重新认领任务');
  }
  {
    const client = makeClient(() => { throw new Error('offline'); });
    await assert.rejects(client.agent.submit('坏日志测试', null));
    client.storage.set([...client.storage.keys()][0], '{');
    const refreshed = makeClient(() => { throw new Error('不得调用'); }, client.storage);
    await assert.rejects(refreshed.agent.send('新内容'), /恢复记录无法读取/);
    assert.equal(refreshed.calls.length, 0);
  }
  {
    const client = makeClient(() => okJSON({ task: { id: 'confirmed', status: 'succeeded' } }));
    await client.agent.submit('已确认任务', null);
    const refreshed = makeClient(url => {
      assert.equal(url, '/api/v1/tasks/confirmed');
      return okJSON({ task: { id: 'confirmed', status: 'succeeded' } });
    }, client.storage);
    await refreshed.agent.recoverActive();
    assert.equal(refreshed.agent.current().id, 'confirmed', '终态也按明确编号恢复而非找最新');
    assert.equal(refreshed.calls.length, 1);
  }
  {
    let client;
    client = makeClient(() => {
      client.localStorage.setItem = () => { throw new Error('storage unavailable'); };
      client.localStorage.removeItem = () => { throw new Error('storage unavailable'); };
      return okJSON({ task: { id: 'accepted-with-cleanup-failure', status: 'accepted' } });
    });
    const accepted = await client.agent.submit('清理失败仍已接收', null);
    assert.equal(accepted.id, 'accepted-with-cleanup-failure', '本机清理失败不能把真实接收变成失败');
    const original = JSON.parse(client.calls[0].options.body);
    const refreshed = makeClient(url => {
      assert.equal(url, '/api/v1/tasks/by-request/' + original.requestId);
      return okJSON({ task: { id: accepted.id, requestId: original.requestId, status: 'accepted' } });
    }, client.storage);
    await refreshed.agent.recoverActive();
    assert.equal(refreshed.calls.length, 1, '残留日志下次仍只查原编号');
    assert(![...client.storage.values()].some(raw => raw.includes('清理失败仍已接收')));
  }

  assert.match(indexSource, /id="agent-panel"[^>]*hidden/, 'HTML 启动时默认隐藏任务卡');
  assert.match(panelSource, /el\.panel\.hidden\s*=\s*!task/, '渲染任务后必须显式解除父层 hidden');
}

main().then(() => {
  console.log('agent client: 提交去重/失败查账/轮询退避/活动判定 全部通过');
}).catch(error => {
  console.error(error);
  process.exit(1);
});

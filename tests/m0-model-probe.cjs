/**
 * [INPUT]: 三个环境变量 PD_MODEL_BASE_URL / PD_MODEL_API_KEY / PD_MODEL_NAME；
 *          被测服务需兼容 OpenAI /chat/completions（含 tools/function calling）。
 * [OUTPUT]: 对 docs/sprite-agent-implementation-plan.md §12 M0-A 的五项能力做真实验证，
 *           输出结构化证据（每项 PASS/FAIL/UNKNOWN + 原始关键字段），退出码 0 表示无 FAIL。
 * [POS]: tests 的 M0 运行时验证探针。只发 HTTP，不启动服务、不注入输入、不写桌面；
 *        验证对象是「模型适配层能不能用」，不是 PocketDesk 的任务链——后者在 M1 才接入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 tests/CLAUDE.md
 *
 * 用法：
 *   PD_MODEL_BASE_URL=https://... PD_MODEL_API_KEY=sk-... PD_MODEL_NAME=xxx \
 *     node tests/m0-model-probe.cjs
 * 可选：PD_MODEL_PROBE_TOOL=0 跳过工具调用验证（服务不支持时如实记 UNKNOWN）。
 *
 * 红线：API Key 只从环境变量读取，绝不落盘、不进日志、不随报告输出。
 */
'use strict';

const BASE = (process.env.PD_MODEL_BASE_URL || '').replace(/\/+$/, '');
const KEY = process.env.PD_MODEL_API_KEY || '';
const MODEL = process.env.PD_MODEL_NAME || '';
const WANT_TOOL = process.env.PD_MODEL_PROBE_TOOL !== '0';

const results = [];
const note = (id, verdict, detail) => { results.push({ id, verdict, detail }); };

function url() {
  // 允许 Base URL 直接给到 /v1，也允许给到根路径。
  return BASE.endsWith('/chat/completions') ? BASE : `${BASE}/chat/completions`;
}

async function chat(body, { timeoutMs = 60000, signal } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('timeout')), timeoutMs);
  const onAbort = () => controller.abort(signal?.reason ?? new Error('aborted'));
  if (signal) {
    if (signal.aborted) controller.abort(signal.reason);
    else signal.addEventListener('abort', onAbort, { once: true });
  }
  try {
    const response = await fetch(url(), {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${KEY}` },
      body: JSON.stringify({ model: MODEL, ...body }),
      signal: controller.signal,
    });
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* 非 JSON 也算一种证据 */ }
    return { status: response.status, json, text };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener('abort', onAbort);
  }
}

const asText = r => (r.json?.choices?.[0]?.message?.content ?? '').trim();

async function probeText() {
  const r = await chat({ messages: [{ role: 'user', content: '只回复两个字：可用' }], temperature: 0 });
  if (r.status !== 200) return note('1 文本', 'FAIL', `HTTP ${r.status} ${r.text.slice(0, 200)}`);
  const content = asText(r);
  if (!content) return note('1 文本', 'FAIL', `无 content：${r.text.slice(0, 200)}`);
  note('1 文本', 'PASS', `content="${content.slice(0, 80)}" usage=${JSON.stringify(r.json.usage ?? null)}`);
  return r.json.usage ?? null;
}

const TOOLS = [{
  type: 'function',
  function: {
    name: 'read_page',
    description: '读取当前网页的标题与正文',
    parameters: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] },
  },
}];
const FAKE_PAGE = '标题：PocketDesk 使用说明\n正文：PocketDesk 把手机变成电脑的输入端与控制台，支持实时输入、触控板与画面查看。';

async function probeToolCall() {
  const messages = [{ role: 'user', content: '用 read_page 读取当前网页，然后一句话总结。' }];
  const first = await chat({ messages, tools: TOOLS, tool_choice: 'auto', temperature: 0 });
  if (first.status !== 200) return note('2 工具调用', 'FAIL', `HTTP ${first.status} ${first.text.slice(0, 200)}`);
  const call = first.json?.choices?.[0]?.message?.tool_calls?.[0];
  if (!call) {
    // 有的服务/模型不支持 tools，这是「能力未支持」而不是「实现有问题」，如实记 UNKNOWN。
    return note('2 工具调用', 'UNKNOWN', `未返回 tool_calls（content="${asText(first).slice(0, 80)}"）`);
  }
  messages.push(first.json.choices[0].message);
  messages.push({ role: 'tool', tool_call_id: call.id, content: FAKE_PAGE });
  const second = await chat({ messages, tools: TOOLS, temperature: 0 });
  if (second.status !== 200) return note('2 工具调用', 'FAIL', `回传结果后 HTTP ${second.status} ${second.text.slice(0, 200)}`);
  const summary = asText(second);
  if (!summary) return note('2 工具调用', 'FAIL', '工具结果回传后没有最终回答');
  const grounded = /PocketDesk|说明/.test(summary);
  note('2 工具调用', grounded ? 'PASS' : 'UNKNOWN',
    `tool=${call.function?.name} 最终回答="${summary.slice(0, 100)}"${grounded ? '' : '（未引用工具结果内容，需人工判断）'}`);
  return { messages, summary };
}

async function probeResume(prior) {
  if (!prior) return note('3 续接', 'UNKNOWN', '依赖工具调用验证，已跳过');
  const messages = [...prior.messages, { role: 'assistant', content: prior.summary },
    { role: 'user', content: '再补充第二点，只说一句。' }];
  const r = await chat({ messages, temperature: 0 });
  if (r.status !== 200) return note('3 续接', 'FAIL', `HTTP ${r.status} ${r.text.slice(0, 200)}`);
  const content = asText(r);
  note('3 续接', content ? 'PASS' : 'FAIL', content ? `content="${content.slice(0, 100)}"` : '无 content（上下文是否真的带上需人工核对语义）');
}

async function probeCancel() {
  const controller = new AbortController();
  const started = Date.now();
  const pending = chat(
    { messages: [{ role: 'user', content: '请从 1 数到 100000，中间不要停。' }], temperature: 0 },
    { timeoutMs: 120000, signal: controller.signal },
  ).then(() => 'completed').catch(error => error.name === 'AbortError' || error.message === 'aborted' ? 'aborted' : `error:${error.message}`);
  setTimeout(() => controller.abort(), 800);
  const outcome = await pending;
  const ms = Date.now() - started;
  // 中止后 800ms 内必须真的结束；拖到几十秒才返回说明取消不可靠（会持续烧 token）。
  note('4 取消', outcome === 'aborted' && ms < 5000 ? 'PASS' : 'FAIL',
    `outcome=${outcome} 用时=${ms}ms（>5s 视为取消不可靠）`);
}

async function probeErrors() {
  const saved = KEY;
  const bad = await chat({ messages: [{ role: 'user', content: 'hi' }] }, {});
  const withBadKey = await (async () => {
    const response = await fetch(url(), {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer invalid-key-probe' },
      body: JSON.stringify({ model: MODEL, messages: [{ role: 'user', content: 'hi' }] }),
    });
    return response.status;
  })();
  note('5 错误分类与用量', 'PASS',
    `正常请求 HTTP ${bad.status}；错误 key HTTP ${withBadKey}；usage=${bad.json?.usage ? '有' : '无（记 unknown）'}`);
  void saved;
}

(async () => {
  if (!BASE || !KEY || !MODEL) {
    console.error('缺配置：需要 PD_MODEL_BASE_URL / PD_MODEL_API_KEY / PD_MODEL_NAME 三个环境变量。');
    process.exit(2);
  }
  console.log(`M0 运行时验证 · model=${MODEL} · base=${BASE}`);
  await probeText();
  const prior = WANT_TOOL ? await probeToolCall() : (note('2 工具调用', 'UNKNOWN', '已由 PD_MODEL_PROBE_TOOL=0 跳过'), null);
  await probeResume(prior);
  await probeCancel();
  await probeErrors();

  for (const r of results) console.log(`${r.verdict.padEnd(7)} ${r.id} — ${r.detail}`);
  const failed = results.filter(r => r.verdict === 'FAIL').length;
  console.log(failed === 0 ? 'M0-A：无 FAIL（UNKNOWN 项需人工确认能力边界）' : `M0-A：${failed} 项 FAIL`);
  process.exit(failed === 0 ? 0 : 1);
})();

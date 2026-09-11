"""
[INPUT]: 需要本机已安装并运行 PocketDesk（HTTP 46387 / HTTPS 46487）与系统 python3 的 Playwright。
         不连手机、不连真实电脑输入：所有 /api/live-input 都在页面里打桩，桌面不会被写入任何字符。
[OUTPUT]: 运行时回归两件事——
          A. 跨弹窗恢复：打断 → 冻结 → 只读探测自我续期 → recoverable 才恢复；冻结期零写入重试、禁止体感发送。
          B. 连续轮次：提交一轮后，下一轮重新建立草稿身份并继续实时同步，未被冻结、状态回到 active。
[POS]: tests 的运行时回归（静态契约见 live-recovery.test.cjs）。纯静态测试抓不到"恢复链自己断掉"这类
       时序缺陷，所以这一层必须真在浏览器里跑一遍。真机（iPhone/安卓）行为另行验收。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
用法：/usr/bin/python3 tests/live-recovery.runtime.py
"""
import json
import sys

from playwright.sync_api import sync_playwright

BASE = "https://127.0.0.1:46487/"

STUB = r"""
window.__liveLog = [];
function mkResp(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
}
const __realFetch = window.fetch.bind(window);
window.fetch = async (input, init) => {
  const url = typeof input === 'string' ? input : ((input && input.url) || '');
  if (url.includes('/api/activate')) return mkResp({ ok: true, locate: 'unchanged' }, 200);
  if (url.includes('/api/send')) return mkResp({ ok: true, outcome: 'sent', detail: 'stub' }, 200);
  if (!url.includes('/api/live-input')) return __realFetch(input, init);
  let body = {};
  try { body = JSON.parse((init && init.body) || '{}'); } catch (e) {}
  const isProbe = body.probe === true;
  window.__liveLog.push({ probe: isProbe, submit: body.submit === true, text: body.text,
                          draftId: body.draftId, mode: window.__fault.mode, t: performance.now() });
  const m = window.__fault.mode;
  if (isProbe) {
    if (m === 'recover' || m === 'recovered') {
      window.__fault.mode = 'recovered';
      return mkResp({ ok: true, state: 'recoverable', committed: false, outcome: 'buffered', detail: '', mode: 'replace' }, 200);
    }
    const note = '请在电脑上点一下原输入框即可继续；手机文字已保留。';
    return mkResp({ ok: true, state: 'needs-user-focus', committed: false, outcome: 'buffered',
                    detail: note, note, mode: 'unknown' }, 200);
  }
  if (body.submit === true) {
    return mkResp({ ok: true, committed: true, outcome: 'sent', detail: 'stub', mode: 'replace', state: 'committed' }, 200);
  }
  if (m === 'fail-once') {
    window.__fault.mode = 'frozen';
    return mkResp({ ok: false, state: 'interrupted', error: '注入：输入焦点被弹窗打断，已冻结。' }, 422);
  }
  if (m === 'frozen') {
    return mkResp({ ok: false, state: 'interrupted', error: '注入：仍在冻结。' }, 422);
  }
  return mkResp({ ok: true, committed: false, outcome: 'buffered', detail: 'stub', mode: 'replace', state: 'active' }, 200);
};
"""

results = {}
may_fail = 0


def check(name, cond, hard=True):
    global may_fail
    print(("PASS " if cond else "FAIL ") + name)
    if not cond and hard:
        may_fail += 1


with sync_playwright() as p:
    browser = p.chromium.launch()

    # ---------- A. 跨弹窗恢复 ----------
    ctx = browser.new_context(ignore_https_errors=True)
    ctx.add_init_script("window.__fault = { mode: 'fail-once' };\n" + STUB)
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(BASE, wait_until="load")
    pg.wait_for_timeout(1800)
    pg.click("#targets .target")
    pg.wait_for_timeout(900)
    pg.click("#text")
    pg.fill("#text", "hello world")
    pg.wait_for_timeout(1200)
    results["A_flag_after_fail"] = pg.evaluate("document.querySelector('#live-flag')?.dataset.state")
    results["A_motion_send_allowed"] = pg.evaluate("window.pocketdeskCanMotionSend()")
    pg.fill("#text", "hello world!")          # 冻结期继续输入：不得产生任何写入
    pg.wait_for_timeout(700)
    pg.evaluate("window.__fault.mode = 'frozen'")
    pg.wait_for_timeout(3800)                  # 观察恢复链是否自我续期（真机缺陷就死在这里）
    log = pg.evaluate("window.__liveLog")
    results["A_probes"] = sum(1 for e in log if e["probe"])
    results["A_writes_during_freeze"] = sum(1 for e in log if not e["probe"] and not e["submit"])
    results["A_note"] = pg.evaluate("document.querySelector('#screen-input-status')?.textContent")
    pg.evaluate("window.__fault.mode = 'recover'")
    pg.wait_for_timeout(3000)
    log = pg.evaluate("window.__liveLog")
    results["A_flag_after_recover"] = pg.evaluate("document.querySelector('#live-flag')?.dataset.state")
    last_probe = max([i for i, e in enumerate(log) if e["probe"]], default=-1)
    last_write = max([i for i, e in enumerate(log) if not e["probe"] and not e["submit"]], default=-1)
    results["A_write_after_last_probe"] = last_write > last_probe
    results["A_writes_text"] = [e["text"] for e in log if not e["probe"] and not e["submit"]]
    results["A_text_final"] = pg.evaluate("document.querySelector('#text').value")
    results["A_errors"] = errs[:5]
    ctx.close()

    # ---------- B. 连续轮次 ----------
    ctx2 = browser.new_context(ignore_https_errors=True)
    ctx2.add_init_script("window.__fault = { mode: 'normal' };\n" + STUB)
    pg2 = ctx2.new_page()
    errs2 = []
    pg2.on("pageerror", lambda e: errs2.append(str(e)))
    pg2.goto(BASE, wait_until="load")
    pg2.wait_for_timeout(1800)
    pg2.click("#targets .target")
    pg2.wait_for_timeout(900)
    pg2.click("#text")
    pg2.fill("#text", "第一轮内容")
    pg2.wait_for_timeout(600)
    pg2.evaluate("window.pocketdeskComposeSend()")
    pg2.wait_for_timeout(1500)
    results["B_text_after_send"] = pg2.evaluate("document.querySelector('#text').value")
    pg2.click("#text")
    pg2.fill("#text", "第二轮内容")
    pg2.wait_for_timeout(800)
    log2 = pg2.evaluate("window.__liveLog")
    results["B_round2_paused"] = pg2.evaluate("livePaused")
    results["B_round2_submitting"] = pg2.evaluate("submittingDraft")
    results["B_round2_live_state"] = pg2.evaluate("liveState")
    results["B_round2_flag"] = pg2.evaluate("document.querySelector('#live-flag')?.dataset.state")
    results["B_round2_motion_ok"] = pg2.evaluate("window.pocketdeskCanMotionSend()")
    results["B_round2_writes"] = [e["text"] for e in log2 if not e["probe"] and not e["submit"]]
    d_round1 = next((e["draftId"] for e in log2 if e["text"] == "第一轮内容" and not e["submit"]), None)
    d_round2 = pg2.evaluate("liveDraftId")
    results["B_draft_identity_changed"] = bool(d_round1) and d_round2 != d_round1
    results["B_errors"] = errs2[:5]
    ctx2.close()
    browser.close()

print(json.dumps(results, ensure_ascii=False, indent=2))

check("A 打断后进入冻结态(error)", results["A_flag_after_fail"] == "error")
check("A 冻结时禁止体感发送", results["A_motion_send_allowed"] is False)
check("A 冻结期无任何写入重试", results["A_writes_during_freeze"] == 1)
check("A 恢复链自我续期(>=3 次探针)", results["A_probes"] >= 3)
check("A 冻结时给出人话提示", "点一下原输入框" in (results["A_note"] or ""))
check("A recoverable 后回到 on", results["A_flag_after_recover"] == "on")
check("A 仅在恢复之后才出现新写入", results["A_write_after_last_probe"] is True)
check("A 恢复后写入携带最新全文", results["A_writes_text"][-1] == results["A_text_final"])
check("A 无页面异常", not results["A_errors"])

check("B 提交后输入框已清空", results["B_text_after_send"] == "")
check("B 第二轮重新实时同步", "第二轮内容" in results["B_round2_writes"])
check("B 第二轮换用新草稿身份", results["B_draft_identity_changed"])
check("B 第二轮未被冻结", results["B_round2_paused"] is False and results["B_round2_submitting"] is False)
check("B 第二轮状态回到 active", results["B_round2_live_state"] == "active")
check("B 第二轮状态提示为 on", results["B_round2_flag"] == "on")
check("B 第二轮允许体感发送", results["B_round2_motion_ok"] is True)
check("B 无页面异常", not results["B_errors"])

print("\nRESULT:", "ALL PASS" if may_fail == 0 else f"HAS {may_fail} FAILURE(S)")
sys.exit(0 if may_fail == 0 else 1)

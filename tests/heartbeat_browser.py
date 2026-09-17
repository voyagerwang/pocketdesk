"""
[INPUT]: 依赖 Playwright 与本机已安装的 PocketDesk HTTP 服务；只放行 GET 与 /api/pair，其余写接口一律拦截（不注入任何桌面输入）。
[OUTPUT]: 锁定手机页心跳失败的分级与归因——<15s 琥珀色"正在自动重试"、≥15s 升红并报出中断时长与重试入口、
          手机离线单独归因、恢复时报出中断时长、四种失败原因各给一句不同的话；并验证轻点提示立刻补拍。
[POS]: tests 的真实浏览器连接态回归；起因是 2026-09-18 用户遇到"明明连着却提示已断开"——
        旧实现把 401、手机离线、电脑端 HTTP 异常、页面脚本错误四种原因全说成同一句"请确认同一 Wi-Fi，或重新扫码"。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import re
from playwright.sync_api import sync_playwright

PAIR = re.compile(r'/api/pair')

state = {'block_pair': False, 'pair_attempts': 0}


def gate(route):
    req = route.request
    if PAIR.search(req.url):
        state['pair_attempts'] += 1
        if state['block_pair']:
            route.abort('connectionrefused')
            return
        route.continue_()
        return
    if req.method != 'GET':
        route.abort()
        return
    route.continue_()


def msg(page):
    return page.locator('#message').inner_text().strip()


def cls(page):
    return page.locator('#message').get_attribute('class') or ''


def pill(page):
    return page.locator('#connection').inner_text().strip()


with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.route('**/api/**', gate)
    page.goto('http://127.0.0.1:46387/')
    page.wait_for_load_state('networkidle')

    # --- 阶段 1：健康（本实例是观看者，控制权仍在手机上：顶部应显示"需接管"而非"未连接"）---
    page.wait_for_function("var t=document.querySelector('#connection').textContent; t.indexOf('连接中')<0 && t.indexOf('未连接')<0", timeout=15000)
    print('阶段1 健康: pill=%s' % pill(page))
    assert cls(page) != 'error', '启动后不该挂红色报错'

    # --- 阶段 2：电脑端 HTTP 打不通（网络还在、控制通道还在）<15 秒：琥珀色示警 + 在重试 ---
    state['block_pair'] = True
    page.wait_for_function("document.querySelector('#message').textContent.indexOf('正在自动重试')>=0", timeout=15000)
    print('阶段2 刚失败: class=%s msg=%s' % (cls(page), msg(page)))
    assert cls(page) == 'warn', '首次判定失败应是琥珀色告警，不是红色报错'
    assert '手机可能不在同一 Wi-Fi' not in msg(page), '控制通道还在时不该武断说成不在同一 Wi-Fi'
    assert pill(page) == '未连接', '顶部状态必须同步改口'

    # --- 阶段 3：持续不通 ≥15 秒：升红，并给出中断时长与重试入口 ---
    page.wait_for_function("document.querySelector('#message').className==='error'", timeout=20000)
    long_msg = msg(page)
    print('阶段3 持续不通: msg=%s' % long_msg)
    assert '已中断' in long_msg and '轻点此处立即重试' in long_msg, '持续不通必须给出中断时长与重试入口'

    # 点提示立刻补拍一次（不等补拍节拍）
    before = state['pair_attempts']
    page.locator('#message').click()
    page.wait_for_timeout(900)
    assert state['pair_attempts'] > before, '轻点提示应立刻发起一次重试'

    # --- 阶段 4：手机离线（系统级 offline 事件）---
    page.context.set_offline(True)
    page.wait_for_function("document.querySelector('#message').textContent.indexOf('手机当前没有网络')>=0", timeout=5000)
    print('阶段4 手机离线: class=%s msg=%s' % (cls(page), msg(page)))
    assert cls(page) == 'error'

    # --- 阶段 5：回网 + 服务恢复：立刻补拍并报出中断时长（不刷新页面）---
    state['block_pair'] = False
    page.context.set_offline(False)
    page.wait_for_function("document.querySelector('#message').textContent.indexOf('已重新连接到电脑')>=0", timeout=15000)
    recovered = msg(page)
    print('阶段5 恢复: pill=%s msg=%s' % (pill(page), recovered))
    assert '中断' in recovered, '恢复提示应报出中断时长，否则用户无法判断刚才到底断没断'
    page.wait_for_function("var t=document.querySelector('#connection').textContent; t.indexOf('未连接')<0 && t.indexOf('连接中')<0", timeout=15000)
    assert not errors, '页面不应有未捕获异常：%s' % errors

    # --- 阶段 6：分类器本身要把四种原因分开（直接问它，不制造故障）---
    branches = page.evaluate("""() => ({
      expired:  heartbeatAdvice({ httpStatus: 401 }),
      server:   heartbeatAdvice({ httpStatus: 502 }),
      script:   heartbeatAdvice(new TypeError('cannot read x')),
      network:  heartbeatAdvice(Object.assign(new Error('Failed to fetch'), { isNetwork: true })),
    })""")
    print('阶段6 分类器: %s' % branches)
    assert '重新扫码' in branches['expired'], '401 必须指向重新扫码'
    assert '电脑端服务返回异常' in branches['server'], '非 401 的 HTTP 失败必须说成电脑端问题'
    assert '页面内部出错' in branches['script'] and '不是网络问题' in branches['script'], '脚本错误必须与断链区分开'
    assert 'Wi-Fi' in branches['network'] or '控制通道' in branches['network'], '网络失败要说清是哪种不通'
    assert len(set(branches.values())) == 4, '四种原因必须给出四句不同的话，否则等于没分类'

    # --- 阶段 7：从健康状态直接掉网：第一句话必须是琥珀色的"没有网络"，不是红色报错 ---
    page.reload()
    page.wait_for_function("var t=document.querySelector('#connection').textContent; t.indexOf('连接中')<0 && t.indexOf('未连接')<0", timeout=15000)
    page.context.set_offline(True)
    page.wait_for_function("document.querySelector('#message').textContent.indexOf('没有网络')>=0", timeout=8000)
    fresh = msg(page)
    print('阶段7 刚掉网: class=%s msg=%s' % (cls(page), fresh))
    assert cls(page) == 'warn', '刚掉网应是琥珀色示警（Android 唤醒瞬间会有假离线），不是立刻红色报错'
    assert 'Wi-Fi' in fresh, '掉网必须指明回家路径（同一 Wi-Fi）'
    page.context.set_offline(False)
    page.wait_for_function("document.querySelector('#message').textContent.indexOf('已重新连接到电脑')>=0", timeout=15000)
    print('阶段7 回网: msg=%s' % msg(page))

    print('心跳分级验证：全部通过')
    browser.close()

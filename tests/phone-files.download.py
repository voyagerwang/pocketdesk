"""
[INPUT]: 生产手机脚本与 loopback Swift fixture（命令参数），Playwright Chromium。
[OUTPUT]: 真实点击接收和下载产生浏览器下载事件，并保存后逐字节核验；不阻止默认链接行为。
[POS]: 手机UI到HTTP下载的联合回归，只有合成文件；不代替Via/安卓系统下载器真机验证。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import subprocess
import sys
import tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pd-browser-download-') as root:
    process=subprocess.Popen([sys.argv[1],root],stdout=subprocess.PIPE,text=True)
    try:
        port=int(process.stdout.readline())
        with sync_playwright() as p:
            browser=p.chromium.launch(headless=True)
            page=browser.new_page(accept_downloads=True)
            page.goto(f'http://127.0.0.1:{port}/')
            page.set_content('<section id="phone-files"><p id="phone-files-notice"></p><div id="phone-files-list"></div></section>')
            page.evaluate("window.authHeaders=()=>({Authorization:'Bearer fixture-token'});window.pairToken=()=> 'fixture-token'")
            page.add_script_tag(path=str(ROOT/'Web/phone-files.js'))
            row=page.locator('article').filter(has_text='测试 文件.txt')
            row.get_by_role('button',name='接收',exact=True).click()
            with page.expect_download() as event:
                row.get_by_role('link',name='点击下载',exact=True).click()
            download=event.value
            assert download.failure() is None
            assert download.suggested_filename=='测试 文件.txt'
            path=Path(root)/'received.txt';download.save_as(path)
            assert path.read_bytes()=='hello 手机\n'.encode()
            browser.close()
        print('Real browser download PASS: click -> attachment event -> saved exact bytes')
    finally:
        process.terminate();process.wait(timeout=5)

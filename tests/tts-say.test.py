#!/usr/bin/env python3
"""tts-say.py 的换路回归。

[INPUT]: 真实 scripts/tts-say.py 模块，注入假的 edge_tts（不联网、不出声）。
[OUTPUT]: 验证系统代理那条路失败时换直连重试一次、直连成功后 10 分钟内先走直连、两条都失败才报错且带两条原因，
          以及直连只在这一句期间设置 no_proxy、结束后恢复原环境。
[POS]: 小E神经音色桥的网络边界回归；不访问微软服务、不写正式缓存。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import importlib.util
import os
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

seen_routes = []
fail_routes = set()


class FakeCommunicate:
    def __init__(self, text, voice, rate="+0%", pitch="+0Hz", connect_timeout=10):
        self.text = text

    async def stream(self):
        direct = os.environ.get("no_proxy") == "*"
        seen_routes.append("direct" if direct else "proxy")
        if ("direct" if direct else "proxy") in fail_routes:
            raise OSError("TLS handshake reset")
        yield {"type": "audio", "data": b"\x00" * 600}


sys.modules["edge_tts"] = types.SimpleNamespace(Communicate=FakeCommunicate)
spec = importlib.util.spec_from_file_location("tts_say", ROOT / "scripts" / "tts-say.py")
tts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tts)

checks = 0


def check(value, label):
    global checks
    checks += 1
    if not value:
        raise SystemExit("FAIL: " + label)


os.environ.pop("no_proxy", None)
os.environ.pop("NO_PROXY", None)

# 代理正常：只走一次系统代理。
audio = tts.synth("你好", "zh-CN-XiaoxiaoNeural", "+0%", "+0Hz")
check(audio and seen_routes == ["proxy"], "代理正常时只走系统代理")
check("no_proxy" not in os.environ, "没有残留直连环境")

# 代理掐断 TLS：换直连成功，并记住直连。
seen_routes.clear(); fail_routes.add("proxy")
audio = tts.synth("关灯了", "zh-CN-XiaoxiaoNeural", "+0%", "+0Hz")
check(audio and seen_routes == ["proxy", "direct"], "系统代理失败后换直连重试一次")
check(tts.ROUTE["direct_until"] > 0, "直连成功后记住直连")
check("no_proxy" not in os.environ and "NO_PROXY" not in os.environ, "直连只在这一句期间设置 no_proxy")

# 记住期间先走直连，不再白撞代理。
seen_routes.clear()
tts.synth("还在弄", "zh-CN-XiaoxiaoNeural", "+0%", "+0Hz")
check(seen_routes == ["direct"], "记住期间先走直连")

# 两条都失败：报错并带两条原因，Swift 侧据此退回本机音色。
seen_routes.clear(); fail_routes.update({"direct", "proxy"})
try:
    tts.synth("失败", "zh-CN-XiaoxiaoNeural", "+0%", "+0Hz")
    check(False, "两条都失败应报错")
except RuntimeError as error:
    message = str(error)
    check("直连" in message and "系统代理" in message, "错误里带两条路的原因")
check(seen_routes == ["direct", "proxy"], "两条路各试一次")

# 用户原本设置的 no_proxy 不被改写。
fail_routes.clear(); os.environ["no_proxy"] = "example.test"
tts.ROUTE["direct_until"] = 0.0
tts.synth("原环境", "zh-CN-XiaoxiaoNeural", "+0%", "+0Hz")
check(os.environ.get("no_proxy") == "example.test", "恢复用户原有的 no_proxy")

print(f"tts-say route fallback: {checks} checks passed")

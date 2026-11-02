"""
[INPUT]: 音箱识别出的单句中文文本与当前时刻。
[OUTPUT]: 只在明确的“到点用音乐叫我”说法上给出绝对时刻与回执；取消说法给出取消指令；其余一律返回 None 交回工作台。
[POS]: 音箱通道的闹钟意图拦截；确定性规则、不调模型，避免远端助手口头答应却什么都没定。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import re
import time

_DIGITS = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
           "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}

# 必须有“叫醒我”这类明确要求，避免把“八点开会”“看看八点的日程”当成闹钟。
_WAKE = re.compile(r"(叫醒|叫起|唤醒|叫|喊|闹钟|闹铃|提醒我起)")
_STOP = re.compile(r"(?:(?:停|停下|停止|关闭|关掉|掐掉|静音)[^。！？]{0,4}(?:播放|音乐|闹钟|闹铃|叫|响))"
                   r"|(?:(?:播放|音乐|闹钟|闹铃)[^。！？]{0,4}(?:关掉|关闭|停掉|掐掉|停|关))")
_QUIET = re.compile(r"^(?:停|停下|停下吧|停一下|别响了|别叫了|安静|安静点|闭嘴|关了|关掉)[。！!\s]*$")
_CANCEL = re.compile(r"(?:(取消|撤销|删掉|删了).{0,8}(闹钟|闹铃|叫醒|叫我)"
                     r"|(闹钟|闹铃).{0,8}(取消|撤销|删掉|删了))")


def number(text):
    """只吃 0–99 的中文或阿拉伯数字；解析不出就返回 None，绝不猜。"""
    text = text.strip()
    if not text:
        return None
    if text.isdigit():
        value = int(text)
        return value if 0 <= value <= 99 else None
    if text == "半":
        return 30
    if "十" in text:
        head, _, tail = text.partition("十")
        tens = 1 if head == "" else _DIGITS.get(head)
        ones = 0 if tail == "" else _DIGITS.get(tail)
        if tens is None or ones is None:
            return None
        return tens * 10 + ones
    if len(text) == 1:
        return _DIGITS.get(text)
    return None


def _format(now, due):
    local = time.localtime(due)
    clock = time.strftime("%H:%M", local)
    if time.strftime("%Y-%m-%d", local) != time.strftime("%Y-%m-%d", time.localtime(now)):
        return time.strftime("%m月%d日 %H:%M", local)
    return clock


def alarm_intent(text, now=None):
    """返回 (due, reply) 表示登记，返回 ("cancel", reply) 表示取消，None 表示不接管。"""
    now = time.time() if now is None else now
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    if _STOP.search(raw) or _QUIET.match(raw):
        return ("stop", "好，音乐停了。")
    if _CANCEL.search(raw):
        return ("cancel", "好，把还没响的那条闹钟取消了。")
    if not _WAKE.search(raw):
        return None

    minutes = re.search(r"(半|[0-9]{1,3}|[零〇一二两三四五六七八九十]{1,3})\s*个?\s*分钟\s*(?:之?后|以后|内)", raw)
    hours = re.search(r"(半|[0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\s*个?\s*(?:小时|钟头)\s*(?:之?后|以后|内)", raw)
    if minutes or hours:
        value = number(minutes.group(1)) if minutes else None
        if hours:
            unit = hours.group(1)
            # “半小时”是 30 分钟，不是 30 小时；这里按词本身算，不做二次推断。
            value = 30 if unit == "半" else (number(unit) or 0) * 60
        if not value or value <= 0 or value > 43200:
            return None
        due = now + value * 60
        return (due, "好，%s 用音乐叫你。" % _format(now, due))

    clock = re.search(r"(?:(明早|明天早上|明天上午|明天|今早|今天早上|今天上午|早上|上午|下午|晚上|傍晚)\s*)?"
                      r"([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\s*[点時时](?:\s*([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\s*分)?", raw)
    if not clock:
        return None
    hour = number(clock.group(2))
    minute = number(clock.group(3)) if clock.group(3) else 0
    if hour is None or minute is None or minute > 59:
        return None
    heading = clock.group(1) or ""
    if any(word in heading for word in ("下午", "晚上", "傍晚")) and hour < 12:
        hour += 12
    if any(word in heading for word in ("明早", "明天")) and hour < 12:
        pass
    if hour > 23:
        return None
    local = time.localtime(now)
    target = time.mktime((local.tm_year, local.tm_mon, local.tm_mday, hour, minute, 0, 0, 0, -1))
    tomorrow = "明" in heading
    if tomorrow or target <= now + 30:
        target = time.mktime(time.localtime(time.mktime((local.tm_year, local.tm_mon, local.tm_mday + 1,
                                                         hour, minute, 0, 0, 0, -1))))
    if target <= now + 30 or target - now > 30 * 86400:
        return None
    return (target, "好，%s 用音乐叫你。" % _format(now, target))

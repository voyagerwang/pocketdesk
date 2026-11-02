"""
[INPUT]: 音箱识别出的中文单句与当前时刻；纯函数，不碰设备。
[OUTPUT]: 验证“几分钟后/半小时后/明早八点”这类到点叫醒被接住，日程问答、待办、没有叫醒动词的说法一律不接管。
[POS]: 音箱通道闹钟意图的口径回归；不启动守护进程、不连音箱。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
from datetime import datetime
import sys
from pathlib import Path
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/xiaoai"))
from intent import alarm_intent, number


class AlarmIntentTests(unittest.TestCase):
    def setUp(self):
        # 固定在北京时间 2026-11-02 00:47，让“明早”“今天下午”有确定答案。
        self.now = time.mktime((2026, 11, 2, 0, 47, 0, 0, 0, -1))

    def due_minutes(self, text):
        result = alarm_intent(text, self.now)
        self.assertIsNotNone(result, text)
        due, reply = result
        self.assertIsInstance(due, float, text)
        self.assertTrue(reply.endswith("用音乐叫你。"), reply)
        return round((due - self.now) / 60)

    def test_relative_minutes(self):
        self.assertEqual(self.due_minutes("五分钟后叫我"), 5)
        self.assertEqual(self.due_minutes("三分钟后用音乐叫我"), 3)
        self.assertEqual(self.due_minutes("20分钟后叫醒我"), 20)
        self.assertEqual(self.due_minutes("半小时后叫我"), 30)

    def test_hours(self):
        self.assertEqual(self.due_minutes("一个小时后叫我"), 60)
        self.assertEqual(self.due_minutes("两小时后叫醒我"), 120)

    def test_clock_next_morning(self):
        result = alarm_intent("明早八点叫我", self.now)
        due, _ = result
        when = datetime.fromtimestamp(due)
        self.assertEqual((when.month, when.day, when.hour, when.minute), (11, 3, 8, 0))

    def test_clock_afternoon(self):
        due, _ = alarm_intent("今天下午三点喊我", self.now)
        when = datetime.fromtimestamp(due)
        self.assertEqual((when.day, when.hour), (2, 15))

    def test_past_clock_rolls_to_next_day(self):
        due, _ = alarm_intent("八点叫我", self.now)
        when = datetime.fromtimestamp(due)
        self.assertEqual((when.day, when.hour, when.minute), (2, 8, 0))

    def test_cancel(self):
        self.assertEqual(alarm_intent("取消闹钟", self.now)[0], "cancel")
        # “把那条闹钟关掉”算停止：还没响的那条由 stop 顺手取消，已经响的那条直接掐掉。
        self.assertEqual(alarm_intent("把明早那个闹钟关掉", self.now)[0], "stop")

    def test_stop(self):
        for text in ("关闭播放", "停", "别响了", "停下吧", "把音乐关掉", "安静点", "停止播放闹钟"):
            self.assertEqual(alarm_intent(text, self.now)[0], "stop", text)

    def test_non_alarm_text_is_left_alone(self):
        for text in ("帮我记个待办", "八点开会", "今天下午三点的日程是什么", "两分钟后",
                     "明早八点提醒我开会", "打开窗帘", "放首歌", "关掉微信", ""):
            self.assertIsNone(alarm_intent(text, self.now), text)

    def test_numbers(self):
        self.assertEqual(number("五"), 5)
        self.assertEqual(number("十二"), 12)
        self.assertEqual(number("二十三"), 23)
        self.assertEqual(number("半"), 30)
        self.assertEqual(number("7"), 7)
        self.assertIsNone(number("第七"))
        self.assertIsNone(number("三三"))


if __name__ == "__main__":
    unittest.main()

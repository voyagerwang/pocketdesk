"""
[INPUT]: 唯一OH2、已有米家授权、受限工作台地址、用户级launchd及同目录运行文件。
[OUTPUT]: 显式设备/默认目标配置、只读探测、单次播报、唤醒音乐安装与试播、可撤销后台安装；凭据不进入参数、日志或源码。
[POS]: 可选音箱通道的运维入口；部署到私有快照，无需重启PocketDesk或另一台电脑。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

from aiohttp import ClientSession, ClientTimeout

# Python隔离模式不自动加入脚本目录，只加载本次发布的可信同目录模块。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bridge import TARGETS, Workbench
from audio import ALARM_MAX_BYTES
from speaker import SEED, STATE, SessionAccount, Speaker, account_hash, read_private, save_private
import scope as permission_scope

LABEL = "dev.pocketdesk.xiaoai"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
FILES = ("bridge.py", "speaker.py", "audio.py", "scope.py", "intent.py", "manage.py", "requirements.txt", "CLAUDE.md")


async def bind(args):
    # 权限冻结后只复用原绑定，永不枚举账号音箱或按名称选择替代品。
    config = read_private(STATE / "config.json")
    await permission_scope.verify_member(config)
    if args.name and args.name != config.get("name"):
        raise PermissionError("设备绑定已冻结，禁止选择其他音箱")
    async with ClientSession(timeout=ClientTimeout(total=20), trust_env=False) as session:
        account = SessionAccount(session, config["account"])
        config["defaultTarget"] = args.default
        existing = STATE / "config.json"
        if existing.exists():
            old = read_private(existing)
            if old.get("deviceID") != config["deviceID"] or old.get("account") != config["account"]:
                raise RuntimeError("已有不同音箱绑定；请先停用并保留旧台账，不能静默换设备")
        # 先验证目标入口，失败不发布配置；TTS sid 单独取得，不借用米家 serviceToken。
        await Workbench(session, TARGETS).check(args.default)
        await account.login("xiaomiio")
        save_private(existing, config)
        print("OH2已绑定，默认目标：" + ("另一台电脑（8786）" if args.default == "remote" else "本机（8787）"))


async def probe(args):
    config = read_private(STATE / "config.json")
    async with Speaker(config) as speaker, ClientSession(trust_env=False) as session:
        records = await speaker.records()
        await Workbench(session, config["targets"]).check(config["defaultTarget"])
        if args.command == "say":
            await speaker.say(args.text)
            print("音箱已接受播报指令；是否实际听到仍需现场确认。")
        else:
            print(json.dumps({"speaker": "OH2", "recognitionReadable": True,
                              "recentRecordCount": len(records), "defaultTarget": config["defaultTarget"],
                              "workbenchReady": True, "sleepMode": await speaker.sleep_mode()}, ensure_ascii=False))


async def alarm(args):
    config = read_private(STATE / "config.json")
    if args.off:
        config.pop("alarmFile", None)
        save_private(STATE / "config.json", config)
        print("唤醒音乐已撤销；重新运行install生效。")
        return
    if args.file:
        source = Path(args.file).expanduser()
        if source.is_symlink() or not source.is_file():
            raise RuntimeError("唤醒音乐文件不可读")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", source.name):
            raise RuntimeError("唤醒音乐文件名只允许字母、数字、点、横线")
        size = source.stat().st_size
        if not 0 < size <= ALARM_MAX_BYTES:
            raise RuntimeError("唤醒音乐需在8MiB以内")
        data = source.read_bytes()
        header = data[:3]
        # 只接受MP3：音箱取的就是 .mp3 单文件URL，换容器在设备上声不声音无法保证。
        if header != b"ID3" and not (header[:2] == b"\xff\xfb" or header[:2] == b"\xff\xf3"):
            raise RuntimeError("唤醒音乐需为MP3")
        folder = STATE / "audio" / "alarm"
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        folder.chmod(0o700)
        target = folder / source.name
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        target.chmod(0o600)
        config["alarmFile"] = source.name
        save_private(STATE / "config.json", config)
        print("唤醒音乐已保存为 " + source.name + "；重新运行install后到点播放。")
        return
    if args.test:
        config = read_private(STATE / "config.json")
        name = config.get("alarmFile")
        if not isinstance(name, str) or not name:
            raise RuntimeError("还没有安装唤醒音乐")
        async with Speaker(config) as speaker:
            if await speaker.sleep_mode():
                print("音箱处于睡眠模式，未播放；不自动唤醒。")
                return
            await speaker.audio.play_alarm(STATE / "audio" / "alarm" / name)
        print("音箱实际取过这段音频：请现场确认是否真的听到音乐。")
        return
    raise RuntimeError("请指定 --file、--test 或 --off")


async def restore_sleep():
    config = read_private(STATE / "config.json")
    backup = read_private(STATE / "audio-state-before.json")
    matches = [p for p in backup["properties"] if str(p.get("did")) == config["miotDID"]
               and p.get("siid") == 5 and p.get("piid") == 3 and type(p.get("value")) is bool]
    if len(matches) != 1:
        raise RuntimeError("睡眠原状态备份不匹配，未修改")
    async with Speaker(config) as speaker:
        if await speaker.sleep_mode() != matches[0]["value"]:
            await speaker.set_sleep(matches[0]["value"])
    print("音箱原睡眠状态已读回确认；程序不会再自动解除睡眠。")


def install():
    config = read_private(STATE / "config.json")
    permission_scope.local(config)
    if config.get("defaultTarget") not in TARGETS:
        raise RuntimeError("默认目标配置无效")
    runtime = STATE / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    runtime.chmod(0o700)
    # 从已验证源码发布独立快照；launchd不依赖用户仓库的后续编辑。
    for name in FILES:
        source = Path(__file__).resolve().parent / name
        target = runtime / name
        if source != target:
            shutil.copyfile(source, target)
        target.chmod(0o600)
    python = STATE / "venv/bin/python"
    if not python.exists():
        raise RuntimeError("请先安装独立Python依赖")
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    document = {"Label": LABEL, "ProgramArguments": [str(python), "-I", "-B", str(runtime / "manage.py"), "daemon"],
                "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30, "Umask": 0o077,
                "WorkingDirectory": str(runtime), "StandardOutPath": str(STATE / "service.log"),
                "StandardErrorPath": str(STATE / "service-error.log")}
    PLIST.write_bytes(plistlib.dumps(document))
    PLIST.chmod(0o600)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(PLIST)], capture_output=True)
    subprocess.run(["launchctl", "enable", f"gui/{os.getuid()}/{LABEL}"], check=True)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(PLIST)], check=True)
    print("OH2语音入口已安装。后台启动状态需用status/probe核对。")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="PocketDesk OH2语音入口")
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("bind")
    setup.add_argument("--name")
    setup.add_argument("--default", choices=TARGETS, default="remote")
    sub.add_parser("probe")
    say = sub.add_parser("say")
    say.add_argument("text")
    sub.add_parser("install")
    sub.add_parser("stop")
    sub.add_parser("status")
    sub.add_parser("daemon")
    sub.add_parser("restore-sleep")
    music = sub.add_parser("alarm")
    music.add_argument("--file")
    music.add_argument("--test", action="store_true")
    music.add_argument("--off", action="store_true")
    target = sub.add_parser("default")
    target.add_argument("target", choices=TARGETS)
    voice = sub.add_parser("voice")
    voice.add_argument("voice", choices=("native", "system"))
    args = parser.parse_args()
    if args.command == "bind":
        asyncio.run(bind(args))
    elif args.command in ("probe", "say"):
        asyncio.run(probe(args))
    elif args.command == "install":
        install()
    elif args.command == "alarm":
        asyncio.run(alarm(args))
    elif args.command == "restore-sleep":
        asyncio.run(restore_sleep())
    elif args.command == "stop":
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(PLIST)], capture_output=True)
        subprocess.run(["launchctl", "disable", f"gui/{os.getuid()}/{LABEL}"], check=True)
        print("OH2语音入口已停用，重启电脑也不自动恢复；记录与配置保留。")
    elif args.command == "default":
        config = read_private(STATE / "config.json")
        config["defaultTarget"] = args.target
        save_private(STATE / "config.json", config)
        print("默认目标已保存；重新运行install生效。")
    elif args.command == "voice":
        config = read_private(STATE / "config.json")
        config["speechOutput"] = "native" if args.voice == "native" else "audio"
        save_private(STATE / "config.json", config)
        print("音色选择已保存；重新运行install生效。")
    elif args.command == "status":
        status = STATE / "status.json"
        print(json.dumps(read_private(status) if status.exists() else {"phase": "not_started"}, ensure_ascii=False))
    else:
        from bridge import main as daemon
        asyncio.run(daemon())


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as error:
        # 避免第三方异常中泄漏用户语音、账号、设备标识或URL凭据。
        print("操作未完成：" + type(error).__name__ + "。请检查连接状态；未自动重发。", file=sys.stderr)
        sys.exit(1)

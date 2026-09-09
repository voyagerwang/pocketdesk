#!/usr/bin/env swift
/**
 * [INPUT]: 依赖 ApplicationServices 的 AXUIElement/AXValue 与 AppKit 的 NSRunningApplication；读系统级 kAXFocusedUIElementAttribute 拿到用户当前聚焦的元素。
 * [OUTPUT]: LIVE_INPUT_PROPOSAL.md 里 P0 兼容性验证的探针：对**用户明确选定的那个输入框**做 AX 能力探测，
 *           输出 应用/bundleID/pid、role/subrole、值长度、AXValue 可读/可写、选区可读写、写入→读回→恢复的结果。
 *           **一律不输出正文内容**（只给长度），避免把用户正在写的文字打到终端上。
 *           默认只读、绝不改动目标框；加 `--write` 才做一次「写测试串 → 读回比对 → 恢复原值」。
 * [POS]: scripts/ 的独立一次性探针，不并入 PocketDesk 应用本体，验证完即可删。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 *
 * 用法：
 *   swiftc scripts/ax-probe.swift -o /tmp/ax-probe -framework AppKit
 *   /tmp/ax-probe                 # 只读探测（安全）
 *   /tmp/ax-probe --write         # 额外做写入/读回/恢复测试（请在空白测试框里跑）
 *   /tmp/ax-probe --delay 10      # 自定义准备时间（默认 5 秒）
 */
import AppKit
import Foundation

// MARK: - 参数

let writeTest = CommandLine.arguments.contains("--write")
let delay: UInt32 = {
    guard let i = CommandLine.arguments.firstIndex(of: "--delay"),
          i + 1 < CommandLine.arguments.count,
          let value = UInt32(CommandLine.arguments[i + 1]) else { return 5 }
    return value
}()

// MARK: - 授权

// 没有辅助功能授权时 AX 一律返回失败，探测结果全是假的——先把它挡在门口。
// 注意：本机可能已经为 PocketDesk.app 授过权，但这是**另一个二进制**，需要单独授权一次。
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
guard trusted else {
    print("""
    ❌ 没有辅助功能授权，探测无法进行。

       系统应该已经弹出授权窗口；若没看到，请到：
       系统设置 → 隐私与安全性 → 辅助功能 → 把刚编译出来的 ax-probe 勾上，
       然后重新运行本命令。
    """)
    exit(1)
}

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
    attr(element, name).flatMap { $0 as? String }
}

func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
    var flag: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, name as CFString, &flag) == .success else { return false }
    return flag.boolValue
}

/// 值长度：只给长度，绝不把内容打出来。
func valueLength(_ element: AXUIElement) -> Int? {
    attr(element, kAXValueAttribute as String).flatMap { $0 as? String }?.utf16.count
}

func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let raw = attr(element, kAXSelectedTextRangeAttribute as String),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &range) == true else { return nil }
    return range
}

func roleDescription(_ element: AXUIElement) -> String {
    let role = stringAttr(element, kAXRoleAttribute as String) ?? "(读不到 role)"
    guard let subrole = stringAttr(element, kAXSubroleAttribute as String), !subrole.isEmpty else { return role }
    return "\(role) / \(subrole)"
}

// MARK: - 等待用户把焦点放到目标输入框

print("""
╭──────────────────────────────────────────────────────────╮
│ PocketDesk P0 探针：AX 兼容性验证                          │
╰──────────────────────────────────────────────────────────╯

请在 \(delay) 秒内，**在电脑上点一下你要测试的那个输入框**
（ChatGPT / 飞书 / 原生文本框…，点完就别再动鼠标和键盘）。
\(writeTest ? "本次带 --write：会往框里写测试串再恢复，请务必用空白测试框。" : "本次为只读探测，不会改动任何内容。")
""")
for remaining in stride(from: delay, to: 0, by: -1) {
    FileHandle.standardError.write("  \(remaining)…".data(using: .utf8)!)
    fflush(stderr)
    sleep(1)
}
FileHandle.standardError.write("\n".data(using: .utf8)!)

// MARK: - 取系统级聚焦元素

let systemWide = AXUIElementCreateSystemWide()
guard let focused = attr(systemWide, kAXFocusedUIElementAttribute as String),
      CFGetTypeID(focused) == AXUIElementGetTypeID() else {
    print("❌ 读不到当前聚焦元素（可能没有任何应用拿着键盘焦点）。")
    exit(2)
}
let element = focused as! AXUIElement

var pid: pid_t = 0
AXUIElementGetPid(element, &pid)
let app = NSRunningApplication(processIdentifier: pid)

// MARK: - 只读探测

print("""
──────── 探测结果 ────────
系统版本   \(ProcessInfo.processInfo.operatingSystemVersionString)
应用       \(app?.localizedName ?? "(未知)")  [pid \(pid)]
bundleID   \(app?.bundleIdentifier ?? "(无)")
role       \(roleDescription(element))
──────── AX 能力 ────────
AXValue 可读        \(attr(element, kAXValueAttribute as String) != nil ? "是" : "否")
AXValue 可写        \(isSettable(element, kAXValueAttribute as String) ? "✅ 是" : "❌ 否")
当前值长度          \(valueLength(element).map(String.init) ?? "(读不到)")
选区可读            \(selectedRange(element) != nil ? "是" : "否")
选区范围可写        \(isSettable(element, kAXSelectedTextRangeAttribute as String) ? "是" : "否")
选区文本可写        \(isSettable(element, kAXSelectedTextAttribute as String) ? "是" : "否（SDK 声明为只读，属正常）")
""")

// role 只是必要条件：AXWebArea 说明点到的是页面容器而不是输入框本身。
// kAXWebAreaRole 在 Swift 里没有导出，直接用字面量。
if let role = stringAttr(element, kAXRoleAttribute as String), role == "AXWebArea" {
    print("""
    ⚠️  聚焦的是 AXWebArea（页面容器），不是输入框本身。
       请在目标页面里再点一下真正的输入框（让它拿到光标）后重跑。
    """)
}

// MARK: - 写入 / 读回 / 恢复（仅 --write）

guard writeTest else {
    print("""
    （只读模式结束。要验证「能不能写进去并读回」，请在一个空白测试框里重跑：
       /tmp/ax-probe --write ）
    """)
    exit(0)
}

print("──────── 写入 → 读回 → 恢复 ────────")
let original = attr(element, kAXValueAttribute as String).flatMap { $0 as? String }
let testText = "PocketDesk-P0-\(Int(Date().timeIntervalSince1970) % 100_000)"

let setError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, testText as CFString)
print("写入测试串      \(setError == .success ? "✅ AXUIElementSetAttributeValue 返回 success" : "❌ 失败：\(setError.rawValue)")")

Thread.sleep(forTimeInterval: 0.15)   // AX 生效是异步的，写立刻读会读到旧值
let readBack = attr(element, kAXValueAttribute as String).flatMap { $0 as? String }
let matched = readBack == testText
let readBackLength = readBack.map { String($0.utf16.count) } ?? "nil"
print("读回比对        \(matched ? "✅ 读回与写入完全一致" : "❌ 不一致（读回 \(readBackLength) 字符，期望 \(testText.utf16.count)）——整框写入对该控件不可靠")")

// 恢复：写测试串是侵入动作，必须把原值放回去，且再读一次确认。
let restoreError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (original ?? "") as CFString)
Thread.sleep(forTimeInterval: 0.15)
let restored = attr(element, kAXValueAttribute as String).flatMap { $0 as? String }
print("恢复原值        \(restoreError == .success ? "✅ 已写回" : "❌ 失败：\(restoreError.rawValue)")")
print("恢复后校验      \(restored == (original ?? "") ? "✅ 与原始内容一致" : "⚠️  不一致——请检查测试框内容，必要时手动撤销")")

print("""
──────── 说明 ────────
本探针不验证「失焦后是否保留」「撤销是否正常」「提交后正文是否一致」——
这三项有副作用或需要人眼判断，请按 LIVE_INPUT_PROPOSAL.md 第 10 节手工过一遍：
  1) 写完后 Cmd+Tab 切走再切回来，看内容还在不在；
  2) 在框里 Cmd+Z 撤销，看是不是一步撤回到原始内容；
  3) 只有确认不会发给真实联系人的前提下，才测试真实提交。
""")

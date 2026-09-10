/**
 * [INPUT]: 依赖 CGSession、Carbon 键盘布局和 Secure Event Input、已认证控制租约。
 * [OUTPUT]: 提供一次性锁屏挑战与串行密码按键提交；不记录密码，不使用剪贴板，不自动重试。
 * [POS]: Sources 的锁屏专用输入边界；只有 HTTPS 路由可调用，与普通草稿执行完全隔离。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Carbon

final class LockScreenInput {
    static let shared = LockScreenInput()
    private let queue = DispatchQueue(label: "dev.voicedeck.lock-input")
    private let mutex = NSLock()
    private var challenge: (id: String, session: String, epoch: UInt64, expires: Double)?
    private var epoch: UInt64 = 0
    private var busy = false
    private var lastAttempt = -Double.infinity
    private var observers: [NSObjectProtocol] = []
    private init() {
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.mutex.lock(); self.epoch &+= 1; self.challenge = nil; self.mutex.unlock()
            })
        }
    }
    static var locked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }
    static var state: String {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return "unknown" }
        if d["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
        return d[kCGSessionLoginDoneKey as String] as? Bool == true ? "unlocked" : "unknown"
    }
    private func allowed() -> Bool { Self.locked && IsSecureEventInputEnabled() && AXIsProcessTrusted() }
    func cancel() { mutex.lock(); epoch &+= 1; challenge = nil; mutex.unlock() }

    func prepare(session: String) -> [String: Any] {
        mutex.lock(); defer { mutex.unlock() }
        guard !busy, allowed(), ProcessInfo.processInfo.systemUptime - lastAttempt >= 5 else {
            return ["error": "锁屏输入暂不可用，请确认密码框已显示后重试。"]
        }
        let id = UUID().uuidString
        challenge = (id, session, epoch, ProcessInfo.processInfo.systemUptime + 30)
        return ["challenge": id]
    }

    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                completion: @escaping ([String: Any]) -> Void) {
        mutex.lock()
        guard !busy, let c = challenge, c.id == id, c.session == session, c.epoch == epoch,
              c.expires >= ProcessInfo.processInfo.systemUptime, !password.isEmpty, password.utf16.count <= 256 else {
            mutex.unlock(); completion(["error": "请求已失效，请重新打开解锁。"]); return
        }
        challenge = nil; busy = true; lastAttempt = ProcessInfo.processInfo.systemUptime
        mutex.unlock()
        queue.async {
            defer { self.mutex.lock(); self.busy = false; self.mutex.unlock() }
            let valid = { () -> Bool in
                self.mutex.lock(); let same = self.epoch == c.epoch; self.mutex.unlock()
                return same && self.allowed() && authorized()
            }
            guard valid() else { completion(["error": "锁屏或控制状态已变化，已停止输入。"]); return }
            guard let keys = Self.keys(for: password), let selectKey = Self.keys(for: "a")?.first else {
                completion(["error": "密码含当前电脑键盘布局无法输入的字符，本次未输入。"]); return
            }
            // 整段先验证可映射，再清空系统密码框；逐键重新检查锁屏及租约。
            let sequence: [(CGKeyCode, CGEventFlags)] = [(selectKey.0, selectKey.1.union(.maskCommand)), (51, [])] + keys + [(36, [])]
            for (key, flags) in sequence {
                guard valid(), let source = CGEventSource(stateID: .hidSystemState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
                    completion(["error": "状态已变化，输入已停止；不会自动重试。"]); return
                }
                down.flags = flags; up.flags = flags
                down.post(tap: .cghidEventTap); usleep(12_000); up.post(tap: .cghidEventTap)
            }
            completion(["sent": true]) // 系统解锁状态另行查询；发键不等于认证成功。
        }
    }

    private static func keys(for text: String) -> [(CGKeyCode, CGEventFlags)]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var map: [String: (CGKeyCode, CGEventFlags)] = [:]
        for (mods, flags) in [(0, CGEventFlags()), (shiftKey, .maskShift), (optionKey, .maskAlternate), (shiftKey | optionKey, [.maskShift, .maskAlternate])] {
            for key: UInt16 in 0..<51 {
                var dead: UInt32 = 0, count = 0
                var chars = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(mods >> 8), UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &count, &chars)
                if result == noErr && count > 0 {
                    let value = String(utf16CodeUnits: chars, count: count)
                    if value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), map[value] == nil { map[value] = (key, flags) }
                }
            }
        }
        var result: [(CGKeyCode, CGEventFlags)] = []
        for character in text { guard let key = map[String(character)] else { return nil }; result.append(key) }
        return result
    }
}

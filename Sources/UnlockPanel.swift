/**
 * [INPUT]: 依赖 AppKit 的 NSWindow/NSStackView/NSSecureTextField；消费 UnlockNativeHTTP（直连配对邀请）与 UnlockCoordinator（配对/撤销/开关）、UnlockCredentialStore（密码与凭据）、Util.qrPNG。
 * [OUTPUT]: 对外提供 UnlockPanelController（原生设置窗口：开关、密码保存/删除、分步配对二维码与链接、核对码确认、凭据撤销）。
 * [POS]: Sources 的快捷解锁的原生兼容管理入口；网页通过 ConsoleActions 的严格本机同源接口共享钥匙串与授权。
 * [REVIEW]: 配对确认失败不报成功，删除密码先撤销在途授权；敏感设置限本机原生或严格同源网页入口。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class UnlockPanelController: NSWindowController, NSWindowDelegate {
    static let shared = UnlockPanelController()

    private weak var coordinator: UnlockCoordinator?
    private weak var credentials: UnlockCredentialStore?
    private var native: UnlockNativeHTTP?

    private let enableSwitch = NSSwitch()
    private let passwordField = NSSecureTextField()
    private let passwordStatus = NSTextField(labelWithString: "")
    private let pairButton = NSButton(title: "添加解锁设备…", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制配对链接", target: nil, action: nil)
    private let pairInfo = NSTextField(wrappingLabelWithString: "")
    private let qrView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton(title: "确认配对", target: nil, action: nil)
    private let denyButton = NSButton(title: "拒绝", target: nil, action: nil)
    private let credentialsList = NSTextField(wrappingLabelWithString: "")
    private var activePairId: String?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "快捷解锁"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    func bind(coordinator: UnlockCoordinator, credentials: UnlockCredentialStore, native: UnlockNativeHTTP) {
        self.coordinator = coordinator
        self.credentials = credentials
        self.native = native
        native.onPairingCode = { [weak self] code, pairId in
            DispatchQueue.main.async { self?.showVerificationCode(code, pairId: pairId) }
        }
    }

    func show() {
        refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        // ① 功能开关
        let enableRow = NSStackView(views: [NSTextField(labelWithString: "启用快捷解锁"), enableSwitch])
        enableRow.orientation = .horizontal
        enableSwitch.controlSize = .large
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleEnabled)
        stack.addArrangedSubview(enableRow)

        // ② 系统密码（原生兼容入口，与网页共用钥匙串）
        stack.addArrangedSubview(NSTextField(labelWithString: "电脑登录密码（只保存在本机钥匙串，不上传）"))
        passwordField.placeholderString = "输入后点“保存密码”"
        passwordField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(passwordField)
        let savePassword = NSButton(title: "保存密码", target: self, action: #selector(savePassword))
        let deletePassword = NSButton(title: "删除密码", target: self, action: #selector(deletePassword))
        let passwordRow = NSStackView(views: [savePassword, deletePassword, passwordStatus])
        passwordRow.orientation = .horizontal
        stack.addArrangedSubview(passwordRow)

        // ③ 配对
        stack.addArrangedSubview(NSBox())
        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(beginPairing)
        stack.addArrangedSubview(pairButton)
        copyButton.target = self
        copyButton.action = #selector(copyInvitation)
        copyButton.isEnabled = false
        stack.addArrangedSubview(copyButton)
        pairInfo.stringValue = "先保存密码并开启快捷解锁，再点“添加解锁设备”。手机与电脑需连接同一 Wi-Fi。"
        stack.addArrangedSubview(pairInfo)
        qrView.isHidden = true
        codeLabel.isHidden = true
        confirmButton.isEnabled = false
        confirmButton.isHidden = true
        denyButton.isHidden = true
        qrView.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(qrView)
        codeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        stack.addArrangedSubview(codeLabel)
        let confirmRow = NSStackView(views: [confirmButton, denyButton])
        confirmRow.orientation = .horizontal
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmPairing)
        denyButton.bezelStyle = .rounded
        denyButton.target = self
        denyButton.action = #selector(denyPairing)
        stack.addArrangedSubview(confirmRow)

        // ④ 凭据管理
        stack.addArrangedSubview(NSBox())
        stack.addArrangedSubview(credentialsList)
        let revokeAll = NSButton(title: "撤销全部凭据", target: self, action: #selector(revokeAll))
        revokeAll.bezelStyle = .rounded
        stack.addArrangedSubview(revokeAll)
    }

    // MARK: - 动作

    @objc private func toggleEnabled() {
        guard let coordinator, let credentials else { return }
        if enableSwitch.state == .on {
            credentials.enabled = true

        } else {
            coordinator.disable()   // 立即作废在途挑战与授权

        }
        refresh()
    }

    @objc private func savePassword() {
        guard let credentials else { return }
        let password = passwordField.stringValue
        passwordField.stringValue = ""   // 立即清空原生框，缩短明文存活时间
        guard !password.isEmpty else { passwordStatus.stringValue = "请先输入密码。"; return }
        do {
            try credentials.savePassword(password)
            passwordStatus.stringValue = "已保存。"
        } catch {
            passwordStatus.stringValue = "保存失败。"
        }
        refresh()
    }

    @objc private func deletePassword() {
        coordinator?.cancelAuthorization()
        credentials?.deletePassword()
        passwordStatus.stringValue = "已删除。"
        refresh()
    }

    @objc private func beginPairing() {
        guard let credentials else { return }
        guard credentials.enabled else { pairInfo.stringValue = "请先启用快捷解锁。"; return }
        guard credentials.hasPassword else { pairInfo.stringValue = "请先保存电脑登录密码。"; return }
        guard let offer = native?.invitation(), offer["error"] == nil,
              let pairId = offer["pairId"] as? String,
              let bytes = try? JSONSerialization.data(withJSONObject: offer, options: [.sortedKeys]) else {
            pairInfo.stringValue = "请连接局域网，并确认本机安全通道已启动。"; return
        }
        activePairId = pairId
        codeLabel.stringValue = ""
        confirmButton.isEnabled = false
        denyButton.isEnabled = true
        denyButton.isHidden = false
        qrView.isHidden = false
        codeLabel.isHidden = true
        confirmButton.isHidden = true
        let invitation = "pocketdesk://pair#" + Base64URL.encode(bytes)
        pairInfo.stringValue = "在安卓 PocketDesk 点“扫码连接电脑”。无法扫码时可复制配对链接。链接 5 分钟有效。"
        if let png = Util.qrPNG(invitation) { qrView.image = NSImage(data: png) }
        pairButton.toolTip = invitation
        copyButton.isEnabled = true
    }

    @objc private func copyInvitation() {
        guard let invitation = pairButton.toolTip else { pairInfo.stringValue = "请先点击“添加解锁设备”生成配对链接。"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation, forType: .string)
        pairInfo.stringValue = "配对链接已复制。传到自己的手机，在 App 的“找不到配对码 / 无法扫码”中粘贴；5 分钟内有效。"
    }

    private func showVerificationCode(_ code: String, pairId: String) {
        guard pairId == activePairId else { return }
        codeLabel.isHidden = false
        confirmButton.isHidden = false
        codeLabel.stringValue = "核对码 \(code)"
        pairInfo.stringValue = "请确认手机上的核对码与上面完全一致，然后在电脑端点“确认配对”。"
        confirmButton.isEnabled = true
    }

    @objc private func confirmPairing() {
        guard let coordinator, let pairId = activePairId else { return }
        guard coordinator.confirmPairing(pairId: pairId) else {
            pairInfo.stringValue = "配对已失效，请重新发起。"; return
        }
        activePairId = nil
        pairButton.toolTip = nil
        copyButton.isEnabled = false
        codeLabel.stringValue = ""
        qrView.image = nil
        qrView.isHidden = true
        codeLabel.isHidden = true
        confirmButton.isHidden = true
        denyButton.isHidden = true
        confirmButton.isEnabled = false
        denyButton.isEnabled = false
        pairInfo.stringValue = "配对完成。"
        refresh()
    }

    @objc private func denyPairing() {
        guard let coordinator, let pairId = activePairId else { return }
        coordinator.denyPairing(pairId: pairId)
        activePairId = nil
        pairButton.toolTip = nil
        copyButton.isEnabled = false
        codeLabel.stringValue = ""
        qrView.image = nil
        qrView.isHidden = true
        codeLabel.isHidden = true
        confirmButton.isHidden = true
        denyButton.isHidden = true
        confirmButton.isEnabled = false
        denyButton.isEnabled = false
        pairInfo.stringValue = "已拒绝本次配对。"
        refresh()
    }

    @objc private func revokeAll() {
        guard let coordinator else { return }
        coordinator.revokeAll()
        refresh()
    }

    // MARK: - 状态刷新

    private func refresh() {
        guard let credentials else { return }
        enableSwitch.state = credentials.enabled ? .on : .off
        passwordStatus.stringValue = credentials.hasPassword ? "已保存。" : "未保存。"
        let rows = credentials.credentials.map { record -> String in
            let confirmed = record.confirmed ? "已确认" : "待确认"
            return "• \(record.label)（\(confirmed)）"
        }
        credentialsList.stringValue = rows.isEmpty ? "尚未配对任何解锁设备。" : rows.joined(separator: "\n")
        // 凭据逐条撤销按钮：用行内按钮列表替换说明文案（简单化：每条一个按钮）。
        if let stack = credentialsList.superview as? NSStackView {
            stack.views.filter { $0.identifier?.rawValue == "credential-row" }.forEach(stack.removeView)
            for (index, record) in credentials.credentials.enumerated() {
                let button = NSButton(title: "撤销「\(record.label)」", target: self, action: #selector(revokeOne(_:)))
                button.bezelStyle = .rounded
                button.identifier = NSUserInterfaceItemIdentifier("credential-row")
                button.tag = index   // 与 refresh 时 credentials 数组顺序一致；变更后立即重建
                stack.addArrangedSubview(button)
            }
        }
    }

    @objc private func revokeOne(_ sender: NSButton) {
        guard let coordinator, let credentials else { return }
        let all = credentials.credentials
        guard all.indices.contains(sender.tag) else { return }
        coordinator.revokeCredential(id: all[sender.tag].credentialId)
        refresh()
    }
}

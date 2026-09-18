/**
 * [INPUT]: 依赖 WebKit 与本地 Web/orb-desktop.html、原版 EmotionBall 资源；消费原生面板展示快照。
 * [OUTPUT]: SpriteOrbView 离线矢量表情视图；就绪后重放最新状态、隐藏停帧、渲染进程恢复，不获取键盘焦点。
 * [POS]: 桌面反馈的绘制适配边界；只向 JavaScript 传可见性/表情/代际/任务身份，不传正文、不注册原生操作桥。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import WebKit

final class SpriteOrbView: WKWebView, WKNavigationDelegate {
    private let resourceRoot: URL
    private var ready = false
    private var snapshot: [String: Any] = ["visible": false, "revision": 0, "emotion": "02", "reduced": false]
    private var lastPayload: String?

    init(webRoot: URL) {
        resourceRoot = webRoot.standardizedFileURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
        setValue(false, forKey: "drawsBackground")
        navigationDelegate = self
        reloadResources()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(visible: Bool, revision: Int, emotion: String, reduced: Bool, taskId: String = "") {
        snapshot = ["visible": visible, "revision": revision, "emotion": emotion, "reduced": reduced, "taskId": taskId]
        flush()
    }

    private func reloadResources() {
        ready = false
        lastPayload = nil
        loadFileURL(resourceRoot.appendingPathComponent("orb-desktop.html"), allowingReadAccessTo: resourceRoot)
    }

    private func flush() {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let payload = String(data: data, encoding: .utf8), payload != lastPayload else { return }
        lastPayload = payload
        evaluateJavaScript("window.pocketdeskDesktopOrb.update(\(payload))") { [weak self] _, error in
            if error != nil { self?.lastPayload = nil }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        flush()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reloadResources() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.standardizedFileURL
        decisionHandler(url?.isFileURL == true && url?.path == resourceRoot.appendingPathComponent("orb-desktop.html").path ? .allow : .cancel)
    }
}

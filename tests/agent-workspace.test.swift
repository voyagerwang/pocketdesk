/**
 * [INPUT]: AgentWorkspaceRequest/Policy、工作空间选择器与新任务导航的纯策略；AX 元素仅作身份替身，不读取桌面。
 * [OUTPUT]: 验证本地工作空间动作参数、准确/同名匹配、操作项隔离、模型/权限排除及名称/值选中核验；覆盖 WorkBuddy PopUpButton 与已选项目/分支/Worktree 行的身份和歧义、项目菜单双动作补证与可见语义发送按钮去重；覆盖 WorkBuddy 5.8.2 可见空白新页直接聚焦、共享空框和发送前原正文框的焦点候选过滤、物理框焦点一致性与正文门禁、草稿子文本与真实新增消息的接收证据隔离、侧栏导航回退、隐藏 AX 副本过滤与同物理控件双引用归一、延迟树就绪、唯一新建入口与真实草稿保护。
 * [POS]: WorkBuddy/ZCode 项目导航的无副作用回归；不启动应用、不发送任务、不修改真实草稿。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

@main struct AgentWorkspaceTests {
    static func main() {
        assert(AgentWorkspaceRequest.parse(#"{"app":"Workbody","action":"open_project","project":"PocketDesk"}"#)?.appKey == "workbuddy")
        assert(AgentWorkspaceRequest.parse(#"{"app":"Z code","action":"list_projects"}"#)?.appKey == "zcode")
        for arguments in [
            #"{"app":"WorkBuddy","action":"open_project"}"#,
            #"{"app":"WorkBuddy","action":"open_project","project":" "}"#,
            #"{"app":"WorkBuddy","action":"open_project","project":"PocketDesk","text":"不要发送"}"#,
            #"{"app":"WorkBuddy","action":"send_task","project":"PocketDesk","text":" "}"#,
            #"{"app":"WorkBuddy","action":"list_projects","project":"PocketDesk"}"#,
            #"{"app":"WorkBuddy","action":"new_task","unknown":true}"#,
            #"{"app":"Chrome","action":"open_project","project":"PocketDesk"}"#
        ] { assert(AgentWorkspaceRequest.parse(arguments) == nil, arguments) }
        assert(AgentWorkspaceRequest.parse(#"{"app":"WorkBuddy","action":"send_task","project":"PocketDesk","text":"完整任务\n保留约束"}"#)?.text == "完整任务\n保留约束")

        assert(AgentWorkspacePolicy.matches(" pocketdesk ", labels: ["PocketDesk", "PocketDesk-old"]) == [0])
        assert(AgentWorkspacePolicy.matches("PocketDesk", labels: ["PocketDesk", "POCKETDESK"]).count == 2)
        assert(AgentWorkspacePolicy.matches("打开本地文件夹", labels: ["打开本地文件夹"]).isEmpty)
        assert(!AgentWorkspacePolicy.isProject(" OPEN LOCAL FOLDER "))
        assert(!AgentWorkspacePolicy.isProject("不使用工作空间"))
        assert(AgentWorkspacePolicy.matches("café", labels: ["cafe\u{301}"]) == [0])
        assert(!AgentWorkspacePolicy.uniqueSelected("PocketDesk", labels: ["PocketDesk", "PocketDesk"], values: ["1", "0"]))

        var nextID: pid_t = 200000
        func node(_ role: String, _ label: String, value: String? = nil, names: [String] = [],
                  menu: Bool = false, enabled: Bool = true, placeholder: String = "",
                  selected: Bool = false, navigationVisible: Bool = true,
                  navigationFrame: CGRect? = nil, inComposer: Bool = false) -> AgentTaskComposer.Node {
            nextID += 1
            var result = AgentTaskComposer.Node(element: AXUIElementCreateApplication(nextID), role: role, label: label, value: value,
                placeholder: placeholder, selected: selected, enabled: enabled, inMenu: menu, accessibleNames: names)
            result.navigationVisible = navigationVisible
            result.navigationFrame = navigationFrame
            result.inComposer = inComposer
            return result
        }
        let editor = node("AXTextArea", "")
        let model = node("AXComboBox", "Select model", value: "PocketDesk", names: ["Select model"])
        let permission = node("AXComboBox", "允许完全访问")
        let more = node("AXComboBox", "更多操作")
        let workspace = node("AXComboBox", "PocketDesk")
        let selected = [editor, model, permission, more, workspace]
        assert(AgentWorkspaceComposer.selectionMatches("PocketDesk", profile: .workbuddy, nodes: selected))
        assert(!AgentWorkspaceComposer.selectionMatches("workbench", profile: .workbuddy, nodes: selected))
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: selected)?.label == "PocketDesk",
            "已选项目仍能重新打开选择器，不能把 Select model 当工作空间")
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: [editor, model, permission, more]) == nil,
            "同名模型值不是项目证据")
        let valueWorkspace = node("AXComboBox", "选择工作空间", value: "PocketDesk", names: ["选择工作空间"])
        assert(AgentWorkspaceComposer.selectionMatches("PocketDesk", profile: .workbuddy, nodes: [editor, valueWorkspace]))
        assert(!AgentWorkspaceComposer.selectionMatches("workbench", profile: .workbuddy, nodes: [editor, valueWorkspace]))
        let described = node("AXComboBox", "工作空间", names: ["工作空间", "PocketDesk"])
        assert(AgentWorkspaceComposer.selectionMatches("PocketDesk", profile: .workbuddy, nodes: [editor, described]))
        let childNamed = node("AXComboBox", "", names: ["PocketDesk"])
        let childPermission = node("AXComboBox", "", names: ["允许完全访问"])
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy,
            nodes: [editor, model, childNamed, childPermission])?.accessibleNames == ["PocketDesk"], "无自身标签时使用局部子文本名称，权限控件仍排除")
        assert(AgentWorkspaceComposer.selectionMatches("PocketDesk", profile: .workbuddy,
            nodes: [editor, model, childNamed, childPermission]))
        assert(!AgentWorkspaceComposer.selectionMatches("PocketDesk", profile: .workbuddy,
            nodes: [editor, workspace, node("AXComboBox", "PocketDesk")]), "重名选择器拒绝猜测")
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy,
            nodes: [editor, workspace, node("AXComboBox", "未知控件")]) == nil, "未知控件使回退歧义时停止")
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy,
            nodes: [editor, node("AXComboBox", "选择工作空间", enabled: false)]) == nil)
        assert(AgentWorkspaceComposer.selector(profile: .zcode,
            nodes: [node("AXPopUpButton", "选择项目")]) != nil)
        let options = AgentWorkspaceComposer.options([
            node("AXMenuItem", "PocketDesk", menu: true),
            node("AXMenuItem", "workbench", menu: true),
            node("AXMenuItem", "打开本地文件夹", menu: true),
            node("AXMenuItem", "NEW WORKSPACE", menu: true),
            node("AXMenuItem", "非菜单项目"),
            node("AXMenuItem", "禁用项目", menu: true, enabled: false)
        ])
        assert(options.map(\.label) == ["PocketDesk", "workbench"])

        // ---------- 5.8.2 项目 PopUpButton 与分支行 ----------
        let popupWorkspace = node("AXPopUpButton", "选择工作空间", navigationFrame: CGRect(x: 10, y: 120, width: 70, height: 24))
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: [editor, popupWorkspace])?.label == "选择工作空间")
        let hiddenPopup = node("AXPopUpButton", "选择工作空间", navigationVisible: false)
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: [editor, popupWorkspace, hiddenPopup])?.label == "选择工作空间",
            "窗口外的同名项目选择器不制造歧义")
        let duplicatePopup = node("AXPopUpButton", "选择工作空间", navigationFrame: popupWorkspace.navigationFrame)
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: [editor, popupWorkspace, duplicatePopup])?.label == "选择工作空间",
            "同角色同矩形的项目选择器包装归一")
        let rowEditor = node("AXTextArea", "", value: "", navigationFrame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let pickedWorkspace = node("AXPopUpButton", "PocketDesk", navigationFrame: popupWorkspace.navigationFrame)
        let branch = node("AXPopUpButton", "workbench", navigationFrame: CGRect(x: 95, y: 125, width: 50, height: 14))
        let worktree = node("AXCheckBox", "Worktree", navigationFrame: CGRect(x: 180, y: 120, width: 60, height: 24))
        let selectedRow = [rowEditor, model, pickedWorkspace, branch, worktree, permission]
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: selectedRow)?.label == "PocketDesk",
            "已选项目时用局部工作空间/分支/Worktree行识别真实选择器")
        assert(AgentWorkspaceComposer.selectionMatches("PocketDesk", profile: .workbuddy, nodes: selectedRow))
        assert(!AgentWorkspaceComposer.selectionMatches("workbench", profile: .workbuddy, nodes: selectedRow),
            "分支恰好与指定项目同名也不冒充选中工作空间")
        let extraPopup = node("AXPopUpButton", "未知控件", navigationFrame: CGRect(x: 155, y: 120, width: 20, height: 24))
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: selectedRow + [extraPopup], selectedName: "workbench") == nil,
            "局部行歧义不能再以同名分支的语义匹配降级放行")
        let invalidWorktree = node("AXCheckBox", "Worktree", navigationFrame: CGRect(x: 180, y: 170, width: 60, height: 24))
        assert(AgentWorkspaceComposer.selector(profile: .workbuddy, nodes: [rowEditor, pickedWorkspace, branch, invalidWorktree], selectedName: "workbench") == nil,
            "Worktree不在同排时不能把分支名当项目")
        let workspaceMenu = [node("AXMenu", ""), node("AXMenuItem", "PocketDesk", menu: true), node("AXMenuItem", "新建工作空间", menu: true),
            node("AXMenuItem", "打开本地文件夹", menu: true), node("AXMenuItem", "不使用工作空间", menu: true)]
        assert(AgentWorkspaceComposer.hasWorkspaceMenuEvidence(workspaceMenu))
        assert(!AgentWorkspaceComposer.hasWorkspaceMenuEvidence(workspaceMenu + [node("AXMenu", "branch")]),
            "工作空间菜单不能为同时出现的分支菜单提供项目权限")
        assert(AgentWorkspaceComposer.options(workspaceMenu).map(\.label) == ["PocketDesk"], "不使用工作空间不是项目选项")
        assert(!AgentWorkspaceComposer.hasWorkspaceMenuEvidence([node("AXMenuItem", "main", menu: true)]), "分支菜单不冒充工作空间")
        assert(!AgentWorkspaceComposer.hasWorkspaceMenuEvidence([node("AXMenuItem", "打开本地文件夹", menu: true)]), "单个相似动作不证明完整项目菜单")

        // ---------- 可见语义发送按钮 ----------
        let sendFrame = CGRect(x: 380, y: 75, width: 20, height: 20)
        let sendButton = node("AXButton", "发送", navigationFrame: sendFrame)
        let duplicateSend = node("AXButton", "发送", navigationFrame: sendFrame)
        assert(AgentTaskComposer.semanticSendButtons([sendButton, duplicateSend,
            node("AXButton", "发送", navigationVisible: false), node("AXButton", "发送", enabled: false)]).count == 1,
            "发送入口排除隐藏/禁用副本，同物理按钮引用归一")
        assert(AgentTaskComposer.semanticSendButtons([sendButton, node("AXButton", "发送", navigationFrame: CGRect(x: 350, y: 75, width: 20, height: 20))]).count == 2,
            "不同实际发送按钮保留歧义")
        assert(AgentTaskComposer.semanticSendButtons([node("AXButton", "发送设置"), node("AXPopUpButton", "发送")]).isEmpty,
            "近似名称和其他角色不提供发送授权")

        // ---------- 折叠侧栏与延迟 AX 树 ----------
        func navigation(_ snapshot: [AgentTaskComposer.Node], expanded: Bool = false,
                        profile: AgentAppProfile = .workbuddy) -> AgentTaskComposer.NativeNavigationStep {
            AgentTaskComposer.nativeNavigationStep(profile: profile, snapshot: snapshot, sidebarExpanded: expanded)
        }
        func expectWaiting(_ step: AgentTaskComposer.NativeNavigationStep, _ message: String) {
            guard case .waiting = step else { assertionFailure(message); return }
        }
        func expectReady(_ step: AgentTaskComposer.NativeNavigationStep, _ message: String) {
            guard case .ready = step else { assertionFailure(message); return }
        }
        func expectBlocked(_ step: AgentTaskComposer.NativeNavigationStep, _ message: String) {
            guard case .blocked(let reason) = step, !reason.isEmpty else { assertionFailure(message); return }
        }
        let expandSidebar = node("AXButton", "展开侧边栏")
        for expander in [expandSidebar, node("AXButton", "Expand sidebar"),
                         node("AXButton", "", names: ["展开侧边栏"])] {
            guard case .expandSidebar(let chosen) = navigation([expander]) else {
                assertionFailure("5.8.2 的完整展开名称必须识别"); return
            }
            assert(CFEqual(chosen.element, expander.element), "只能返回已识别的真实展开控件")
        }
        for ignored in [node("AXButton", "展开侧边栏", enabled: false),
                        node("AXButton", "收起侧边栏"), node("AXButton", "展开侧边栏快捷操作"),
                        node("AXButton", "展开设置"), node("AXLink", "展开侧边栏")] {
            expectWaiting(navigation([ignored]), "禁用、反向、近似名称与其他角色不能触发展开")
        }
        let hiddenExpand = node("AXButton", "展开侧边栏", navigationVisible: false)
        guard case .expandSidebar(let visibleExpand) = navigation([expandSidebar, hiddenExpand]) else {
            assertionFailure("隐藏侧栏中的同名 AX 副本不能造成展开歧义"); return
        }
        assert(CFEqual(visibleExpand.element, expandSidebar.element), "只选择窗口内可见的展开按钮")
        expectWaiting(navigation([hiddenExpand, node("AXButton", "Expand sidebar", navigationVisible: false)]),
            "全部展开入口隐藏时应等待真实可见入口")
        expectBlocked(navigation([expandSidebar, node("AXButton", "Expand sidebar")]), "多个可见展开入口仍拒绝猜测")
        let sharedExpandFrame = CGRect(x: 97, y: 49, width: 32, height: 32)
        let physicalExpand = node("AXButton", "展开侧边栏", navigationFrame: sharedExpandFrame)
        let duplicateExpand = node("AXButton", "展开侧边栏", navigationFrame: sharedExpandFrame)
        guard case .expandSidebar(let physicalChoice) = navigation([physicalExpand, duplicateExpand]) else {
            assertionFailure("同角色且矩形完全相同的双 AX 引用是一个物理展开按钮"); return
        }
        assert(CFEqual(physicalChoice.element, physicalExpand.element), "物理重复保留首个可见引用")
        expectBlocked(navigation([physicalExpand, node("AXButton", "展开侧边栏",
            navigationFrame: CGRect(x: 137, y: 49, width: 32, height: 32))]), "不同矩形仍是不同展开入口")
        expectBlocked(navigation([node("AXButton", "展开侧边栏"), node("AXButton", "展开侧边栏")]),
            "缺少矩形不能把不同 AX 引用合并")
        assert(AgentTaskComposer.uniqueNavigationControls([physicalExpand,
            node("AXLink", "展开侧边栏", navigationFrame: sharedExpandFrame)]).count == 2,
            "同一矩形的不同角色不能互相冒充")
        expectWaiting(navigation([expandSidebar], expanded: true), "已点击展开后只等待更新，不再次点击")
        expectWaiting(navigation([]), "激活后首次空 AX 树应等待")
        let newTask = node("AXTab", "新建任务", selected: true)
        expectReady(navigation([newTask], expanded: true), "侧栏展开后的稳定新建入口可以继续")
        for profile in [AgentAppProfile.codex, .zcode, .cola, .chatgpt, .cue] {
            expectWaiting(navigation([expandSidebar], profile: profile), "其他应用不能借用 WorkBuddy 展开按钮")
        }

        // ---------- 新建入口与新页证据 ----------
        for entry in [newTask, node("AXLink", "New task"),
                      node("AXTab", "", names: ["新建任务"]),
                      node("AXLink", "其他标签", names: ["New task"])] {
            let buttons = AgentTaskComposer.newTaskButtons(profile: .workbuddy, snapshot: [entry])
            assert(buttons.count == 1 && CFEqual(buttons[0].element, entry.element), "角色与完整可访问名称共同识别入口")
            expectReady(navigation([entry]), "唯一新建 AXTab/AXLink 可以继续导航")
        }
        assert(AgentTaskComposer.newTaskButtons(profile: .workbuddy, snapshot: [
            node("AXTab", "新建任务", enabled: false), node("AXStaticText", "新建任务"),
            node("AXButton", "新建任务说明")
        ]).isEmpty, "禁用入口、正文标题与近似名称不是可点击新建按钮")
        let hiddenNewTask = node("AXTab", "新建任务", selected: true, navigationVisible: false)
        let visibleNewButtons = AgentTaskComposer.newTaskButtons(profile: .workbuddy, snapshot: [newTask, hiddenNewTask])
        assert(visibleNewButtons.count == 1 && CFEqual(visibleNewButtons[0].element, newTask.element),
            "隐藏新建入口不能参与唯一候选核验")
        expectReady(navigation([newTask, hiddenNewTask]), "可见新建入口不受隐藏副本干扰")
        expectWaiting(navigation([hiddenNewTask, node("AXLink", "New task", navigationVisible: false)]),
            "全部新建入口隐藏时应等待可见入口")
        expectBlocked(navigation([newTask, node("AXLink", "New task")]), "多个可见新建入口仍拒绝猜测")
        let sharedNewFrame = CGRect(x: 100, y: 104, width: 144, height: 36)
        let physicalNewTask = node("AXTab", "新建任务", selected: true, navigationFrame: sharedNewFrame)
        let duplicateNewTask = node("AXTab", "新建任务", selected: true, navigationFrame: sharedNewFrame)
        let physicalNewButtons = AgentTaskComposer.newTaskButtons(profile: .workbuddy,
            snapshot: [physicalNewTask, duplicateNewTask])
        assert(physicalNewButtons.count == 1 && CFEqual(physicalNewButtons[0].element, physicalNewTask.element),
            "同物理新建控件的双 AX 引用不造成入口歧义")
        expectReady(navigation([physicalNewTask, duplicateNewTask]), "重复引用归一后仍可导航")

        let welcome = node("AXStaticText", "WorkBuddy, 我帮你")
        let hint582 = "今天帮你做些什么？\n@ 添加上下文，/ 调用技能与指令"
        let blank582 = node("AXTextArea", "", value: hint582, placeholder: hint582)
        let blank = node("AXTextArea", "", value: "\u{200B}\n")

        // ---------- 新页与焦点获取共用的可见空框候选 ----------
        for composer in [blank, blank582, node("AXTextArea", "", value: "")] {
            let candidates = AgentTaskComposer.visibleEmptyComposers(profile: .workbuddy, snapshot: [composer])
            assert(candidates.count == 1 && CFEqual(candidates[0].element, composer.element),
                "真实空值和完整已知占位可以成为可见输入候选")
        }
        for excluded in [node("AXTextArea", "", value: "这是草稿", placeholder: hint582),
                         node("AXTextArea", "", value: nil, placeholder: hint582),
                         node("AXTextArea", "", value: "", navigationVisible: false),
                         node("AXTextArea", "", value: "", enabled: false),
                         node("AXTextField", "", value: ""), node("AXComboBox", "", value: "")] {
            assert(AgentTaskComposer.visibleEmptyComposers(profile: .workbuddy, snapshot: [excluded]).isEmpty,
                "非空、不可读、隐藏、禁用及非正文输入角色不能成为焦点获取候选")
        }
        let editorFrame = CGRect(x: 440, y: 380, width: 600, height: 140)
        let physicalEditor = node("AXTextArea", "", value: "", navigationFrame: editorFrame)
        let duplicateEditor = node("AXTextArea", "", value: hint582, navigationFrame: editorFrame)
        let physicalEditors = AgentTaskComposer.visibleEmptyComposers(profile: .workbuddy,
            snapshot: [physicalEditor, duplicateEditor])
        assert(physicalEditors.count == 1 && CFEqual(physicalEditors[0].element, physicalEditor.element),
            "同角色精确同矩形的空框双 AX 引用只代表一个焦点目标")
        assert(AgentTaskComposer.visibleEmptyComposers(profile: .workbuddy, snapshot: [physicalEditor,
            node("AXTextArea", "", value: "", navigationFrame: CGRect(x: 440, y: 540, width: 600, height: 140))]).count == 2,
            "不同物理矩形的两个空框保持两个候选，调用方必须拒绝猜测")

        // ---------- 发送前只重获原正文框，不重写内容 ----------
        let preparedText = "这是派单测试。\n请只回复“收到测试消息”。"
        let preparedEditor = node("AXTextArea", "", value: preparedText, navigationFrame: editorFrame)
        let rebuiltEditor = node("AXTextArea", "", value: preparedText, navigationFrame: editorFrame)
        let otherEditorFrame = CGRect(x: 440, y: 540, width: 600, height: 140)
        func preparedCandidates(_ snapshot: [AgentTaskComposer.Node], bounds: CGRect?) -> [AgentTaskComposer.Node] {
            AgentTaskComposer.preparedWorkBuddyComposers(snapshot: snapshot, element: preparedEditor.element,
                bounds: bounds, text: preparedText)
        }
        func preparedCandidates(_ snapshot: [AgentTaskComposer.Node]) -> [AgentTaskComposer.Node] {
            preparedCandidates(snapshot, bounds: editorFrame)
        }
        for snapshot in [[preparedEditor], [rebuiltEditor], [preparedEditor, rebuiltEditor]] {
            let candidates = preparedCandidates(snapshot)
            assert(candidates.count == 1 && CFEqual(candidates[0].element, snapshot[0].element),
                "原 AX 引用或同角色精确原矩形的重建引用都能唯一绑定完整正文")
        }
        assert(preparedCandidates([preparedEditor], bounds: nil).count == 1,
            "原 AX 身份仍可核验时不依赖矩形回退")
        assert(preparedCandidates([rebuiltEditor], bounds: nil).isEmpty,
            "新 AX 引用缺少原矩形时不能凭相同正文猜测绑定")
        for excluded in [node("AXTextArea", "", value: preparedText + "\n追加内容", navigationFrame: editorFrame),
                         node("AXTextArea", "", value: nil, navigationFrame: editorFrame),
                         node("AXTextArea", "", value: preparedText, navigationFrame: otherEditorFrame),
                         node("AXTextArea", "", value: preparedText, navigationVisible: false, navigationFrame: editorFrame),
                         node("AXTextArea", "", value: preparedText, enabled: false, navigationFrame: editorFrame),
                         node("AXTextField", "", value: preparedText, navigationFrame: editorFrame),
                         node("AXComboBox", "", value: preparedText, navigationFrame: editorFrame)] {
            assert(preparedCandidates([excluded]).isEmpty,
                "全文变化、不可读、非原位置、隐藏、禁用或非正文角色不得重获派单焦点")
        }
        assert(preparedCandidates([rebuiltEditor,
            node("AXTextArea", "", value: preparedText, navigationFrame: otherEditorFrame)]).count == 1,
            "其他位置相同正文不参与原框候选")
        var movedOriginal = preparedEditor
        movedOriginal.navigationFrame = otherEditorFrame
        assert(preparedCandidates([movedOriginal, rebuiltEditor]).count == 2,
            "原引用与原位置重建引用落在不同物理位置时保留歧义，发送调用方必须拒绝")

        // ---------- AX 包装重建不冒充物理输入框变化 ----------
        assert(AgentTaskComposer.matchesWorkBuddyFocus(expected: physicalEditor, focused: duplicateEditor, text: nil),
            "原空框与相同物理矩形的已知空值 AX 包装可以证明焦点一致")
        assert(AgentTaskComposer.matchesWorkBuddyFocus(expected: preparedEditor, focused: rebuiltEditor, text: preparedText),
            "正文完全匹配时相同物理框的 AX 包装重建不造成假失焦")
        let geometryUnknown = node("AXTextArea", "", value: "")
        assert(AgentTaskComposer.matchesWorkBuddyFocus(expected: geometryUnknown, focused: geometryUnknown, text: nil),
            "原 AX 身份与空值均可核验时不依赖矩形")
        assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: geometryUnknown,
            focused: node("AXTextArea", "", value: ""), text: nil), "不同引用且矩形未知时不能猜同一输入框")
        let invalidEmptyFocus = [
            node("AXTextArea", "", value: "", navigationFrame: otherEditorFrame),
            node("AXTextField", "", value: "", navigationFrame: editorFrame),
            node("AXComboBox", "", value: "", navigationFrame: editorFrame),
            node("AXTextArea", "", value: "", navigationVisible: false, navigationFrame: editorFrame),
            node("AXTextArea", "", value: "", enabled: false, navigationFrame: editorFrame),
            node("AXTextArea", "", value: nil, navigationFrame: editorFrame),
            node("AXTextArea", "", value: "‘", navigationFrame: editorFrame),
            node("AXTextArea", "", value: hint582 + "新增草稿", navigationFrame: editorFrame)
        ]
        for invalid in invalidEmptyFocus {
            assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: physicalEditor, focused: invalid, text: nil),
                "真实别框、错误角色、隐藏/禁用/不可读或新增草稿不能证明空框焦点")
            assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: invalid, focused: physicalEditor, text: nil),
                "原绑定同样须满足角色、可见性、启用与空值门禁")
        }
        for invalid in [
            node("AXTextArea", "", value: preparedText + "\n用户修改", navigationFrame: editorFrame),
            node("AXTextArea", "", value: "", navigationFrame: editorFrame),
            node("AXTextArea", "", value: preparedText, navigationFrame: otherEditorFrame),
            node("AXTextArea", "", value: preparedText),
            node("AXTextArea", "", value: preparedText, navigationVisible: false, navigationFrame: editorFrame),
            node("AXTextArea", "", value: preparedText, enabled: false, navigationFrame: editorFrame),
            node("AXTextField", "", value: preparedText, navigationFrame: editorFrame)
        ] {
            assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: preparedEditor, focused: invalid, text: preparedText),
                "发送正文改变、清空、焦点换位或角色/可见性失效不能放行发送")
            assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: invalid, focused: preparedEditor, text: preparedText),
                "旧绑定正文与几何也须完整核验，不能只核实当前焦点")
        }
        let sameIdentityInvalidRole = AgentTaskComposer.Node(element: physicalEditor.element, role: "AXTextField",
            label: "", value: "", placeholder: "", selected: false, enabled: true)
        let sameIdentityDraft = AgentTaskComposer.Node(element: physicalEditor.element, role: "AXTextArea",
            label: "", value: "用户草稿", placeholder: "", selected: false, enabled: true)
        let sameIdentityChangedText = AgentTaskComposer.Node(element: preparedEditor.element, role: "AXTextArea",
            label: "", value: preparedText + "修改", placeholder: "", selected: false, enabled: true)
        assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: physicalEditor, focused: sameIdentityInvalidRole, text: nil),
            "CFEqual 原引用也不能绕过正文角色核验")
        assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: physicalEditor, focused: sameIdentityDraft, text: nil),
            "CFEqual 原引用也不能绕过真实草稿保护")
        assert(!AgentTaskComposer.matchesWorkBuddyFocus(expected: preparedEditor, focused: sameIdentityChangedText, text: preparedText),
            "CFEqual 原引用也不能绕过完整发送正文核验")

        // ---------- 草稿文本不计为已接收消息 ----------
        let draftChild = node("AXStaticText", "", value: preparedText, inComposer: true)
        let beforeSubmission = [node("AXTextArea", "", value: preparedText, inComposer: true), draftChild]
        let receivedMessage = node("AXStaticText", "", value: preparedText)
        let afterSubmission = [receivedMessage, blank]
        let beforeMessageCount = AgentTaskComposer.matchingMessages(beforeSubmission, text: preparedText)
        let afterMessageCount = AgentTaskComposer.matchingMessages(afterSubmission, text: preparedText)
        let afterEmptyComposer = AgentTaskComposer.visibleEmptyComposers(profile: .workbuddy, snapshot: afterSubmission).count == 1
        assert(beforeMessageCount == 0, "发送前 TextArea 内的同正文 StaticText 只是草稿，不计为已接收消息")
        assert(afterMessageCount == 1, "发送后撰写框外的完整正文才计为真实消息")
        assert(AgentTaskComposer.acceptsSubmission(originalCleared: false,
            newMessage: afterMessageCount > beforeMessageCount, emptyComposer: afterEmptyComposer, runningStarted: false),
            "新增完整正文消息与空输入框共同证明接收，不能因草稿子文本计数误报待核对")
        let existingBefore = AgentTaskComposer.matchingMessages([receivedMessage, draftChild], text: preparedText)
        let existingAfter = AgentTaskComposer.matchingMessages([receivedMessage, blank], text: preparedText)
        assert(existingBefore == 1 && existingAfter == 1, "旧消息在提交前后仍是同一份证据")
        assert(!AgentTaskComposer.acceptsSubmission(originalCleared: false,
            newMessage: existingAfter > existingBefore, emptyComposer: afterEmptyComposer, runningStarted: false),
            "旧已存在正文与陌生空框不能证明本次提交已接收")
        assert(AgentTaskComposer.matchingMessages([
            node("AXStaticText", preparedText + "\n其他内容"),
            node("AXStaticText", "这是派单测试。"), node("AXTextField", preparedText)
        ], text: preparedText) == 0, "近似文本、正文片段及非消息角色不提供接收证据")

        // ---------- 可见空白页优先直接聚焦 ----------
        let visibleWelcome = node("AXHeading", "WorkBuddy, 我帮你")
        let visibleWorkspace = node("AXPopUpButton", "选择工作空间")
        let directPage = [visibleWelcome, visibleWorkspace, blank582]
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy, snapshot: [visibleWelcome] + selectedRow).count == 1,
            "工作空间已显示项目名且旁边存在分支时，真实欢迎页仍可直接识别空白新任务，不依赖未选项目标签")
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy, snapshot: directPage).count == 1,
            "可见欢迎标题、工作空间选择器与唯一空框足以证明当前空白新页，不依赖侧栏选中")
        expectReady(navigation(directPage + [expandSidebar]), "当前已有可见空白页时直接聚焦，不先展开侧栏")
        expectReady(navigation([node("AXHeading", "", names: ["WorkBuddy, 我帮你"]),
            visibleWorkspace, blank582, expandSidebar]), "欢迎标题仅在辅助可访问名称中时仍能核验当前空白页并直接聚焦")
        expectReady(navigation(directPage + [node("AXTab", "新建任务"), node("AXLink", "New task")]),
            "直接聚焦已核验空白页时不受多个导航入口影响")
        expectBlocked(navigation([visibleWelcome, visibleWorkspace, blank, blank582, expandSidebar]),
            "多个可见空框仍拒绝直接聚焦，也不盲展开")
        let invalidDirectPages: [[AgentTaskComposer.Node]] = [
            [visibleWorkspace, blank582],
            [node("AXHeading", "WorkBuddy, 我帮你", navigationVisible: false), visibleWorkspace, blank582],
            [visibleWelcome, node("AXPopUpButton", "选择工作空间", navigationVisible: false), blank582],
            [visibleWelcome, visibleWorkspace, node("AXTextArea", "", value: hint582, navigationVisible: false)],
            [visibleWelcome, visibleWorkspace, node("AXTextArea", "", value: "‘", placeholder: hint582)],
            [visibleWelcome, visibleWorkspace, node("AXTextArea", "", value: "这是原有草稿", placeholder: hint582)],
            [visibleWelcome, model, permission, more, blank582],
            [visibleWelcome, node("AXComboBox", "Select model", value: "选择工作空间"), blank582],
            [visibleWelcome, node("AXComboBox", "允许完全访问", value: "选择工作空间"), blank582]
        ]
        for snapshot in invalidDirectPages {
            assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy, snapshot: snapshot).isEmpty,
                "不可见、不完整或真实草稿不能证明可直接使用的空白页，模型和权限值不能冒充工作空间")
            expectWaiting(navigation(snapshot), "无可用新页证据或导航入口时等待，不放行直接聚焦")
            guard case .expandSidebar(let fallback) = navigation(snapshot + [expandSidebar]) else {
                assertionFailure("无空白页证据时才使用已核验展开入口导航"); return
            }
            assert(CFEqual(fallback.element, expandSidebar.element), "回退只使用真实可见展开按钮")
        }

        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
            snapshot: [hiddenNewTask, welcome, blank]).isEmpty, "隐藏的新建选中副本不能证明可见空白新页")
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
            snapshot: [newTask, node("AXHeading", "WorkBuddy, 我帮你", navigationVisible: false), blank]).isEmpty,
            "可见的新建选中页签不能用隐藏欢迎标题证明当前旧会话空框是新任务")
        let namedNewTask = node("AXTab", "其他标签", names: ["新建任务"], selected: true)
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
            snapshot: [namedNewTask, welcome, blank]).count == 1, "辅助名称识别的新建入口也必须提供选中页证据")
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
            snapshot: [node("AXTab", "其他标签", names: ["新建任务"]), welcome, blank]).isEmpty,
            "辅助名称识别的入口未选中时仍拒绝空白新页")
        for composer in [blank582, blank] {
            let readyPage = [newTask, welcome, composer]
            let empty = AgentTaskComposer.emptyNewComposers(profile: .workbuddy, snapshot: readyPage)
            assert(empty.count == 1 && CFEqual(empty[0].element, composer.element), "5.8.2 已知占位与真实空值在新页证据成立后可用")
            expectReady(navigation(readyPage), "完整新页证据可继续")
            assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy, snapshot: [newTask, composer]).isEmpty,
                "只有 selected 新建入口仍不足以证明新页")
            assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
                snapshot: [node("AXTab", "新建任务"), welcome, composer]).isEmpty, "旧版静态欢迎语没有可见标题和选择器时仍须核验新建页选中")
        }
        for value in ["‘", hint582 + "\n这是用户草稿", "今天帮你做些什么？这是用户写的内容"] {
            let draft = node("AXTextArea", "", value: value, placeholder: hint582)
            assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
                snapshot: [newTask, welcome, draft]).isEmpty, "残留字符与包含提示的真实正文仍须保护")
        }
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
            snapshot: [newTask, welcome, node("AXTextArea", "", value: nil)]).isEmpty, "不可读输入框不冒充空白")
        assert(AgentTaskComposer.emptyNewComposers(profile: .workbuddy,
            snapshot: [newTask, welcome, node("AXTextArea", "", value: "", enabled: false)]).isEmpty, "禁用输入框不用于派单")
        expectBlocked(navigation([newTask, welcome, blank, blank582]), "多个空白新页输入框拒绝猜测")
        print("PASS WorkBuddy/ZCode workspace navigation policies")
    }
}

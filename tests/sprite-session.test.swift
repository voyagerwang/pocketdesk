/**
 * [INPUT]: 依赖 Foundation，消费 SpriteSession、SpriteFeedback、AgentModels。
 * [OUTPUT]: 覆盖刷新重连、提交身份隔离、同任务追问与显式重选；覆盖展示会话的代际/序号/版本去重（迟到输入不覆盖新版、旧会话不复活、提交清空竞态），
 *           以及投影的逐状态映射（执行中工具行、待补充、完成/派单不冒充、失败、放弃、断线标注）。
 * [POS]: tests 的桌面反馈逻辑测试；`swiftc -parse-as-library` 编译，不依赖 AppKit、不联网。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct SpriteSessionTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { print("  ok - \(label)") } else { failures += 1; print("  FAIL - \(label)") }
        }

        print("sprite session: 选择代际")

        do {
            let session = SpriteSession()
            session.select(generation: 5)
            check(session.current.selected, "选择后进入展示意图")
            session.deselect(generation: 4)
            check(session.current.selected, "旧代际的 deselect 不能取消更新的选择")
            session.deselect(generation: 5)
            check(!session.current.selected, "同代际 deselect 生效")
            session.select(generation: 3)
            check(!session.current.selected, "迟到的 select 不能复活已收起的球球")
        }

        print("sprite session: 草稿 latest-only")

        do {
            let session = SpriteSession()
            session.select(generation: 2)
            session.draft(generation: 2, seq: 10, version: 3, text: "第一版")
            session.draft(generation: 2, seq: 11, version: 4, text: "第二版")
            check(session.current.draft == "第二版", "最新草稿生效")
            session.draft(generation: 2, seq: 9, version: 2, text: "迟到的旧稿")
            check(session.current.draft == "第二版", "迟到帧不覆盖新版")
            session.draft(generation: 1, seq: 99, version: 9, text: "旧会话稿")
            check(session.current.draft == "第二版", "旧代际草稿被拒")
            session.deselect(generation: 2)
            session.draft(generation: 2, seq: 20, version: 5, text: "未选中时的稿")
            check(session.current.draft == "第二版", "未选中不接受草稿")
        }

        print("sprite session: 提交与清空竞态")

        do {
            let session = SpriteSession()
            session.select(generation: 1)
            session.draft(generation: 1, seq: 1, version: 7, text: "要发送的正文")
            session.submitting(version: 7, text: "要发送的正文", requestId: "req-1")
            check(session.current.submitting, "提交在途被记录")
            session.submitted(version: 7, taskId: "task-1")
            check(!session.current.submitting && session.current.draft.isEmpty, "版本匹配的提交回执清空草稿")
            check(session.current.lastTaskId == "task-1", "回执记录 taskId")

            // 旧提交的迟到回执不能清掉新输入。
            session.draft(generation: 1, seq: 2, version: 8, text: "新输入")
            session.submitting(version: 8, text: "新输入", requestId: "req-2")
            session.submitted(version: 8, taskId: "task-2")
            session.draft(generation: 1, seq: 3, version: 9, text: "提交收尾间隙的新稿")
            session.submitted(version: 8, taskId: "task-2")   // 重复/迟到回执
            check(session.current.draft == "提交收尾间隙的新稿", "迟到回执不清掉提交后新输入的草稿")

            // 提交失败保留正文。
            session.draft(generation: 1, seq: 4, version: 10, text: "失败的正文")
            session.submitting(version: 10, text: "失败的正文", requestId: "req-3")
            session.submitFailed(version: 10)
            check(!session.current.submitting && session.current.draft == "失败的正文", "提交失败保留草稿并结束提交态")

            // 显式清空只匹配当前版本。
            session.clear(generation: 1, seq: 5, version: 9)
            check(session.current.draft == "失败的正文", "旧版本的清空不动新草稿")
            session.clear(generation: 1, seq: 6, version: 10)
            check(session.current.draft.isEmpty, "当前版本的显式清空生效")
        }

        print("sprite feedback: 投影映射")

        func makeTask(status: TaskStatus, revision: Int = 1,
                      result: String? = nil, error: String? = nil,
                      toolName: String? = nil,
                      handoffTarget: String? = nil, handoffRequested: Bool? = nil) -> AgentTask {
            var task = AgentTask(subject: "subject", requestId: "req", status: status, text: "问题正文")
            task.revision = revision
            task.result = result
            task.error = error
            if let toolName { task.messages.append(TaskMessage(role: .tool, text: "…", toolName: toolName)) }
            if let handoffTarget {
                task.handoffTargetId = handoffTarget
                task.handoffTargetName = handoffTarget
            }
            task.handoffRequested = handoffRequested
            return task
        }

        do {
            // 空闲选中：安静状态行。
            let session = SpriteSession()
            session.select(generation: 1)
            var viewModel = SpriteFeedback.project(session: session.current, task: nil, rounds: [],
                                                   now: 1_000)
            check(viewModel.statusLine.isEmpty && viewModel.emotion == "02" && !viewModel.busy, "空闲无占位文字，原版待机")

            let emotions: [(TaskStatus, String)] = [(.accepted, "31"), (.running, "32"), (.verifying, "30"),
                (.needsInput, "11"), (.failed, "11"), (.abandoned, "11"), (.succeeded, "33")]
            for (status, emotion) in emotions {
                let model = SpriteFeedback.project(session: session.current, task: makeTask(status: status), rounds: [], now: 1_000)
                check(model.emotion == emotion, "原版表情映射：\(status)")
            }

            // 草稿：待发送标签。
            session.draft(generation: 1, seq: 1, version: 1, text: "帮我整理需求")
            viewModel = SpriteFeedback.project(session: session.current, task: nil, rounds: [],
                                               now: 1_000)
            check(viewModel.draft == "帮我整理需求" && viewModel.emotion == "35" && viewModel.statusLine == "待发送", "草稿带「待发送」状态")

            // 提交中保留草稿。
            session.submitting(version: 1, text: "帮我整理需求", requestId: "req-1")
            viewModel = SpriteFeedback.project(session: session.current, task: nil, rounds: [],
                                               now: 1_000)
            check(viewModel.submitting && viewModel.statusLine == "正在提交…" && viewModel.draft == "帮我整理需求",
                  "提交中显示「正在提交」且保留草稿")
            check(viewModel.question == "帮我整理需求", "提交中本轮问题即提交正文")

            check(viewModel.phase == .submitting && viewModel.displayText.isEmpty && !viewModel.headline.isEmpty,
                  "提交保留底层草稿，但浮层切为提交状态")

            // 已返回工具不等于当前正在执行的步骤。
            session.submitted(version: 1, taskId: "task-1")
            let running = makeTask(status: .running, toolName: "read_page")
            viewModel = SpriteFeedback.project(session: session.current, task: running, rounds: [],
                                               now: 1_000)
            check(viewModel.busy && viewModel.statusLine == "执行中", "执行中明确反馈，不把已返回工具当当前进度")
            let runningNoTool = makeTask(status: .running)
            viewModel = SpriteFeedback.project(session: session.current, task: runningNoTool, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine == "执行中", "没有工具事件保持「正在处理」")
            let accepted = makeTask(status: .accepted)
            viewModel = SpriteFeedback.project(session: session.current, task: accepted, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine == "已接收，准备执行" && viewModel.busy, "已接收保留等待动效但不冒充执行中")

            var editingWhileBusy = session.current
            editingWhileBusy.draft = "下一条还没发的草稿"
            let activeModel = SpriteFeedback.project(session: editingWhileBusy, task: running, rounds: [], now: 1_000)
            check(activeModel.phase == .working && activeModel.emotion == "32" && activeModel.displayText.isEmpty,
                  "执行中有留存草稿也不退回聆听")

            // 完成/失败/待补充/放弃。
            let succeeded = makeTask(status: .succeeded, result: "整理好了，共三步。")
            viewModel = SpriteFeedback.project(session: session.current, task: succeeded, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine == "已完成" && viewModel.answer == "整理好了，共三步。", "完成展示结论并停止忙碌")

            check(viewModel.phase == .succeeded && viewModel.emotion == "33" && viewModel.displayText == succeeded.result,
                  "完成展示结果并触发庆祝，不回显原话")
            let editingAfterDone = SpriteFeedback.project(session: editingWhileBusy, task: succeeded, rounds: [], now: 1_000)
            check(editingAfterDone.phase == .drafting && editingAfterDone.displayText == editingWhileBusy.draft,
                  "新输入替换已完成结果")

            let failed = makeTask(status: .failed, error: "模型服务不可达。")
            viewModel = SpriteFeedback.project(session: session.current, task: failed, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine == "未完成" && viewModel.answer == "模型服务不可达。", "失败展示原因")

            let needsInput = makeTask(status: .needsInput, result: "要 A 版本还是 B 版本？")
            viewModel = SpriteFeedback.project(session: session.current, task: needsInput, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine == "等你补充" && viewModel.answer == "要 A 版本还是 B 版本？", "待补充展示追问与选项")

            let abandoned = makeTask(status: .abandoned)
            viewModel = SpriteFeedback.project(session: session.current, task: abandoned, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine.contains("已放弃等待") && viewModel.statusLine.contains("可能仍在执行"),
                  "放弃等待如实展示，不谎报已停止")

            // 外部派单：小精灵本轮 succeeded 不得渲染成外部任务完成。
            let handoff = makeTask(status: .succeeded, result: "已交给 WorkBuddy 整理",
                                   handoffTarget: "WorkBuddy", handoffRequested: true)
            viewModel = SpriteFeedback.project(session: session.current, task: handoff, rounds: [],
                                               now: 1_000)
            check(viewModel.statusLine == "已交给 WorkBuddy" && viewModel.phase == .handedOff && viewModel.emotion == "19", "外部派单显示已提交，不冒充外部任务完成")

            // 断线标注：最近上报超过 15 秒。
            var stale = session.current
            stale.lastReportAt = 1_000 - 30
            viewModel = SpriteFeedback.project(session: stale, task: nil, rounds: [], now: 1_000)
            check(!viewModel.phoneConnected, "断线时标明输入连接状态")
            viewModel = SpriteFeedback.project(session: session.current, task: nil, rounds: [], now: 1_000)
            check(viewModel.phoneConnected, "刚上报视为在线")
        }

        print("sprite feedback: 轮次记账与面板投递")

        do {
            final class SpyPanel: SpriteFeedback.Panel {
                var last: SpriteFeedback.ViewModel?
                func apply(_ viewModel: SpriteFeedback.ViewModel) { last = viewModel }
            }

            let session = SpriteSession()
            let spy = SpyPanel()
            let feedback = SpriteFeedback(session: session, subject: "subject")
            feedback.panel = spy

            var store: [AgentTask] = []
            feedback.taskProvider = { store.max { $0.createdAt < $1.createdAt } }

            session.select(generation: 1)
            session.draft(generation: 1, seq: 1, version: 1, text: "第一件事")
            session.submitting(version: 1, text: "第一件事", requestId: "req-1")
            var task = makeTask(status: .running, revision: 2)
            store = [task]
            session.submitted(version: 1, taskId: task.id)
            feedback.refresh()
            check(spy.last?.busy == true, "任务事实变化驱动面板更新")

            task.status = .succeeded
            task.revision = 3
            task.result = "第一件事完成"
            store = [task]
            feedback.refresh()
            check(spy.last?.answer == "第一件事完成" && spy.last?.statusLine == "已完成", "任务完成投影到面板")

            feedback.refresh()
            check(spy.last?.question == "第一件事" || spy.last?.question == task.text, "提交回执认领到本轮问题")


        }

        print("sprite review regressions: 重连/回执/追问/重选")
        do {
            let session = SpriteSession()
            session.bind(controller: "old-connection")
            session.select(generation: 5)
            session.draft(generation: 5, seq: 50, version: 20, text: "旧草稿")
            session.bind(controller: "new-connection")
            session.select(generation: 1)
            session.draft(generation: 1, seq: 2, version: 1, text: "刷新后草稿")
            check(session.current.draft == "刷新后草稿", "刷新后的新控制连接接受从零开始的计数")
            session.submitting(version: 2, text: "新提交", requestId: "new")
            session.submitted(version: 1, taskId: "old", requestId: "old")
            check(session.current.submitting && session.current.lastTaskId == nil, "旧回执不能改新提交状态和任务身份")
            session.submitted(version: 2, taskId: "wrong", requestId: "wrong")
            check(session.current.submitting, "相同版本但不同提交身份仍拒绝")
            session.submitted(version: 2, taskId: "new", requestId: "new")
            check(!session.current.submitting && session.current.lastTaskId == "new", "本次回执正确结算")
            session.select(generation: 3, seq: 10)
            session.deselect(generation: 2, seq: 9)
            check(session.current.selected, "超时迟到的切走不能隐藏新选择")
        }
        do {
            final class ReviewPanel: SpriteFeedback.Panel {
                var last: SpriteFeedback.ViewModel?
                func apply(_ model: SpriteFeedback.ViewModel) { last = model }
            }
            let session = SpriteSession(); session.select(generation: 1)
            let panel = ReviewPanel()
            let feedback = SpriteFeedback(session: session, subject: "test")
            feedback.panel = panel
            var task = makeTask(status: .running)
            task.text = "第一轮"
            feedback.taskProvider = { task }
            feedback.refresh()
            task.status = .needsInput; task.result = "旧追问"; task.revision += 1
            feedback.refresh()
            task.status = .running; task.text = "第二轮补充"; task.revision += 1
            // TaskService 当前可能保留旧 result；展示层仍须按执行状态隐藏。
            feedback.refresh()
            check(panel.last?.question == "第二轮补充" && panel.last?.answer == nil, "追问接续显示最新问题且不复用旧结果")
            let revision = task.revision
            task = makeTask(status: .succeeded, revision: revision, result: "另一任务结果")
            task.text = "另一任务问题"
            feedback.refresh()
            check(panel.last?.question == nil && panel.last?.answer == nil, "历史终态不作为默认提示")
            session.submitting(version: 1, text: task.text, requestId: "new")
            session.submitted(version: 1, taskId: task.id, requestId: "new")
            feedback.refresh()
            check(panel.last?.question == "另一任务问题" && panel.last?.answer == "另一任务结果", "本会话任务相同 revision 仍更新")
            let oldPresentation = panel.last!.presentationRevision
            session.select(generation: 2)
            feedback.refresh()
            check(panel.last!.presentationRevision > oldPresentation, "显式重选驱动开心唤醒")
            let newPresentation = panel.last!.presentationRevision
            session.select(generation: 2)
            feedback.refresh()
            check(panel.last!.presentationRevision == newPresentation, "重连快照不重复唤醒")

        }

        if failures == 0 {
            print("sprite session: 全部通过")
        } else {
            print("sprite session: \(failures) 项失败")
            exit(1)
        }
    }
}

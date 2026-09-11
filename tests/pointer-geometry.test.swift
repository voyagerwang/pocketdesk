/**
 * [INPUT]: 依赖 PointerGeometry 的纯几何函数，不读焦点、不发事件、不要求辅助功能权限。
 * [OUTPUT]: 验证单屏/跨屏/负坐标/纵向排列下的落点选择、窗口内保持原位、明显遮挡与不可证明可见时跳过、
 *           零尺寸与屏外窗口拒绝；并验证绝不回退主屏中心。
 * [POS]: tests 的应用选择鼠标就位几何回归；真实鼠标移动与多屏拔插只在明确测试窗口上另行验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics

@main struct PointerGeometryTests {
    static func landing(_ window: CGRect, _ screens: [CGRect], _ occluders: [CGRect] = []) -> CGPoint {
        switch PointerGeometry.landing(window: window, screens: screens, occluders: occluders) {
        case .success(let point): return point
        case .failure(let reason): fatalError("本应有落点，实际跳过：\(reason.rawValue)")
        }
    }

    static func mustSkip(_ label: String, _ window: CGRect, _ screens: [CGRect], _ occluders: [CGRect] = []) {
        if case .success(let point) = PointerGeometry.landing(window: window, screens: screens, occluders: occluders) {
            fatalError("\(label)：本应跳过，实际给了落点 \(point)")
        }
    }

    static func main() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let single = [main]

        // 1) 单屏：窗口完全在屏内 → 落点是窗口中心，且判定为"已在位"。
        let inside = CGRect(x: 100, y: 100, width: 400, height: 300)
        let center = landing(inside, single)
        assert(abs(center.x - 300) <= 1 && abs(center.y - 250) <= 1, "单屏应落在窗口中心，实际 \(center)")
        assert(inside.contains(center))
        assert(PointerGeometry.isCursorSettled(at: center, window: inside, screens: single, occluders: []))
        // 光标在窗口外：不该被判成"已在位"。
        assert(!PointerGeometry.isCursorSettled(at: CGPoint(x: 5, y: 5), window: inside, screens: single, occluders: []))
        // 光标在窗口内、但被别的窗口压住：同样不算就位。
        assert(!PointerGeometry.isCursorSettled(at: center, window: inside, screens: single,
                                                occluders: [CGRect(x: 200, y: 200, width: 200, height: 100)]))

        // 2) 窗口中心被明显遮挡 → 退到可见区域内未被遮挡的候选点，仍落在同一窗口内。
        let occluder = CGRect(x: 250, y: 200, width: 100, height: 100)
        let shifted = landing(inside, single, [occluder])
        assert(!occluder.contains(shifted), "落点不能压在遮挡窗口上")
        assert(inside.contains(shifted), "退让后的落点仍须在目标窗口内")

        // 3) 可见区域被完全压住 → 跳过，不移动（绝不猜测）。
        mustSkip("完全被遮挡", inside, single, [CGRect(x: 0, y: 0, width: 1000, height: 800)])

        // 4) 窗口整个在屏幕之外 → 没有屏幕交集，跳过；**绝不回退主屏中心**。
        mustSkip("窗口在屏外", CGRect(x: 5000, y: 5000, width: 300, height: 200), single)
        // 与之对照：主屏中心附近仍能正常给点，说明上面的跳过不是"永远失败"。
        assert(abs(landing(CGRect(x: 400, y: 300, width: 200, height: 200), single).x - 500) <= 1)

        // 5) 零尺寸/退化窗口 → 跳过。
        mustSkip("零尺寸窗口", CGRect(x: 10, y: 10, width: 2, height: 2), single)

        // 6) 负坐标副屏（左侧那块，原点 -1200）→ 落点保持在负坐标那侧，不挪回主屏。
        let leftScreen = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        let onLeft = CGRect(x: -1100, y: 100, width: 400, height: 300)
        let leftPoint = landing(onLeft, [leftScreen, main])
        assert(abs(leftPoint.x - (-900)) <= 1 && abs(leftPoint.y - 250) <= 1, "副屏落点应使用负坐标，实际 \(leftPoint)")

        // 7) 纵向排列（第二屏在原屏下方 y = 800..1700）→ 落点落在下面那块屏上。
        let below = CGRect(x: 0, y: 800, width: 1000, height: 900)
        let onBelow = CGRect(x: 100, y: 900, width: 200, height: 200)
        let belowPoint = landing(onBelow, [main, below])
        assert(abs(belowPoint.x - 200) <= 1 && abs(belowPoint.y - 1000) <= 1, "纵向排列落点错误：\(belowPoint)")

        // 8) L 形排列：外接矩形包含没有屏幕的空洞，落点必须落在真实屏幕交集里。
        let lShape = [main, CGRect(x: 1000, y: 500, width: 800, height: 900)]
        let inHole = CGRect(x: 600, y: 900, width: 200, height: 200)   // 外接矩形内，但没有任何屏幕
        mustSkip("L 形空洞里的窗口", inHole, lShape)
        let inRightLeg = CGRect(x: 1100, y: 600, width: 300, height: 200)
        let legPoint = landing(inRightLeg, lShape)
        assert(abs(legPoint.x - 1250) <= 1 && abs(legPoint.y - 700) <= 1, "L 形右腿落点错误：\(legPoint)")

        // 9) 跨屏窗口：取与有效显示器相交面积最大的一块的中心。
        let spanning = CGRect(x: -300, y: 100, width: 600, height: 400)   // 左半在主屏左边那块屏
        let spanPoint = landing(spanning, [leftScreen, main])
        assert(leftScreen.contains(spanPoint) || main.contains(spanPoint), "跨屏落点必须落在某块真实屏幕上")
        assert(spanning.contains(spanPoint), "跨屏落点仍须在目标窗口内")

        print("pointer geometry: 单屏/窗口内保持/遮挡退让/完全遮挡跳过/屏外拒绝/负坐标/纵向/L 形/跨屏 全部通过")
    }
}

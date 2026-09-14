import Foundation
@main struct DeviceConnectionsTest {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeviceConnections(directory: folder)
        let id = UUID().uuidString
        let other = UUID().uuidString
        assert(!store.heartbeat(["deviceId": "invalid"], now: 100))
        assert(store.heartbeat(["deviceId": id, "name": "手机", "session": "owner"], now: 100))
        store.heartbeat(["deviceId": other, "name": "手机"], now: 101)
        var rows = store.snapshot(now: 110, controls: { $0 == "owner" })
        assert(rows.count == 2)
        assert(rows.filter { $0["controlling"] as? Bool == true }.count == 1)
        store.heartbeat(["deviceId": id, "name": "新名称"], now: 115)
        rows = store.snapshot(now: 130, controls: { _ in false })
        assert(rows.count == 2)
        assert(rows.contains { $0["name"] as? String == "新名称" && $0["started"] as? Double == 100 })
        assert(store.rename(id: id, name: "电脑上的名称"))
        store.heartbeat(["deviceId": id, "name": "手机伪造名称"], now: 131)
        assert(store.snapshot(now: 132, controls: { _ in false }).contains { $0["name"] as? String == "电脑上的名称" })
        let restored = DeviceConnections(directory: folder)
        assert(restored.snapshot(now: 132, controls: { _ in false }).contains { $0["name"] as? String == "电脑上的名称" })
        assert(restored.snapshot(now: 130, controls: { _ in true }).allSatisfy { $0["online"] as? Bool == false })
        rows = store.snapshot(now: 177, controls: { _ in true })
        assert(rows.allSatisfy { $0["online"] as? Bool == false })
        store.heartbeat(["deviceId": id, "name": "新名称"], now: 180)
        assert(store.snapshot(now: 180, controls: { _ in false }).count == 3)
        assert(store.snapshot(now: 31 * 86400, controls: { _ in false }).isEmpty)
        print("device-connections: passed")
    }
}

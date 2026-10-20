/**
 * [INPUT]: MijiaBridge 的真实家庭清单、本机 auth.json 的账号标识及私有家庭选择文件。
 * [OUTPUT]: 绑定账号摘要的单家庭授权票据、异步家庭选择接口与执行锁；缺失/损坏/账号变化均拒绝设备访问。
 * [POS]: 米家控制台选择与 Gateway 执行共用的范围边界；准备请求不持锁，执行前复核票据并与选择保存串行。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation
import CryptoKit
import Darwin

final class MijiaHomeScope {
    struct Dependencies {
        var authURL = URL(fileURLWithPath: MijiaBridge.authPath)
        var fileURL = MijiaBridge.directory.appendingPathComponent("home-scope.json")
        var invoke: ([String: Any]) -> Result<[String: Any], MijiaBridge.Failure> = MijiaBridge.run
        var save: (Data, URL) throws -> Void = MijiaHomeScope.privateSave
    }
    struct Ticket: Equatable {
        let account: String
        let homeID: String
        let homeName: String
        let revision: String
    }
    private struct Selection: Codable {
        let version: Int
        let account: String
        let homeID: String
        let homeName: String
        let revision: String
        var ticket: Ticket { Ticket(account: account, homeID: homeID, homeName: homeName, revision: revision) }
    }
    static let shared = MijiaHomeScope()
    private let dependencies: Dependencies
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.voicedeck.mijia-home-scope", qos: .utility)
    private static let selectionMessage = "请先在 PocketDesk 电脑控制台的“米家连接”中选择一个家庭，再查询或控制设备。"

    init(dependencies: Dependencies = Dependencies()) { self.dependencies = dependencies }

    func withAccountReplacement<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try action()
    }

    func authorize(homeID: String? = nil) throws -> Ticket {
        lock.lock(); defer { lock.unlock() }
        let selected = try selection()
        guard homeID == nil || homeID == selected.homeID else {
            throw failure("该家庭不在 PocketDesk 已选择的范围内。请在电脑控制台切换家庭后重新发起操作。")
        }
        return selected.ticket
    }

    func withAuthorization<T>(_ ticket: Ticket, _ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard try selection().ticket == ticket else { throw failure("米家家庭选择已变化，已停止此前操作。请按当前家庭重新发起。") }
        let result = try action()
        guard try selection().ticket == ticket else { throw failure("米家账号或家庭选择已变化，请在电脑控制台核对；此前操作结果需要确认。") }
        return result
    }

    func homes(completion: @escaping (Result<[String: Any], MijiaBridge.Failure>) -> Void) {
        queue.async { completion(self.homeList()) }
    }
    func select(homeID: String, completion: @escaping (Result<[String: Any], MijiaBridge.Failure>) -> Void) {
        queue.async { completion(self.saveSelection(homeID: homeID)) }
    }

    // ---------- 网络清单只提供候选；落盘前重新核对账号与真实家庭 ----------
    func homeList() -> Result<[String: Any], MijiaBridge.Failure> {
        do {
            let account = try accountHash()
            let homes = try fetchHomes()
            lock.lock(); defer { lock.unlock() }
            guard try accountHash() == account else { throw failure("米家账号已变化，请重新获取家庭列表。") }
            return .success(snapshot(homes, account: account))
        } catch let error as MijiaBridge.Failure { return .failure(error) }
        catch { return .failure(failure("无法读取米家账号，请重新扫码连接。")) }
    }
    func saveSelection(homeID: String) -> Result<[String: Any], MijiaBridge.Failure> {
        do {
            guard !homeID.isEmpty, homeID.count <= 256 else { throw failure("家庭选择无效，请重新选择。") }
            let account = try accountHash()
            let homes = try fetchHomes()
            guard let home = homes.first(where: { $0["id"] == homeID }), let name = home["name"] else {
                throw failure("该家庭已不可用，请刷新列表并选择其中一个家庭。")
            }
            lock.lock(); defer { lock.unlock() }
            guard try accountHash() == account else { throw failure("米家账号已变化，未保存家庭选择，请重新获取列表。") }
            let selected = Selection(version: 1, account: account, homeID: homeID, homeName: name, revision: UUID().uuidString)
            do { try dependencies.save(JSONEncoder().encode(selected), dependencies.fileURL) }
            catch { throw failure("家庭选择未能保存，原有范围已保留。请检查电脑存储权限后重试。") }
            return .success(snapshot(homes, account: account))
        } catch let error as MijiaBridge.Failure { return .failure(error) }
        catch { return .failure(failure("无法读取米家账号，请重新扫码连接。")) }
    }
    private func fetchHomes() throws -> [[String: String]] {
        let result = try dependencies.invoke(["operation": "list_homes"]).get()
        guard result["truncated"] as? Bool != true,
              let homes = result["homes"] as? [[String: Any]], homes.count <= 1000 else { throw failure("米家家庭列表不完整或无法核对，请稍后重试。") }
        var seen = Set<String>(), clean: [[String: String]] = []
        for home in homes {
            guard let id = home["id"] as? String, !id.isEmpty, id.count <= 256,
                  let name = home["name"] as? String, !name.isEmpty, name.count <= 1000,
                  seen.insert(id).inserted else { throw failure("米家家庭列表无法核对，请稍后重试。") }
            clean.append(["id": id, "name": name])
        }
        return clean
    }
    private func snapshot(_ homes: [[String: String]], account: String) -> [String: Any] {
        let saved = try? selection()
        let selected = saved.flatMap { value in
            value.account == account ? homes.first(where: { $0["id"] == value.homeID }) : nil
        }
        return ["homes": homes, "selectedHomeId": selected?["id"] as Any? ?? NSNull(),
                "selectedHomeName": selected?["name"] as Any? ?? NSNull(), "selectionRequired": selected == nil,
                "message": selected == nil ? Self.selectionMessage : "小精灵仅能访问已选择家庭的设备。"]
    }
    private func selection() throws -> Selection {
        let account = try accountHash()
        guard let data = try? Self.privateRead(dependencies.fileURL),
              let selected = try? JSONDecoder().decode(Selection.self, from: data), selected.version == 1,
              selected.account == account, !selected.homeID.isEmpty, selected.homeID.count <= 256,
              !selected.homeName.isEmpty, UUID(uuidString: selected.revision) != nil else { throw failure(Self.selectionMessage) }
        return selected
    }
    private func accountHash() throws -> String {
        let data = try Self.privateRead(dependencies.authURL)
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw failure(Self.selectionMessage) }
        let id: String
        if let text = value["userId"] as? String, !text.isEmpty, text.count <= 256 { id = text }
        else if let number = value["userId"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { id = number.stringValue }
        else { throw failure(Self.selectionMessage) }
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func failure(_ message: String) -> MijiaBridge.Failure { .init(kind: "scope", message: message) }
    private static func privateRead(_ url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let permissions = attrs[.posixPermissions] as? NSNumber, permissions.intValue & 0o777 == 0o600,
              let size = attrs[.size] as? NSNumber, size.intValue > 0 && size.intValue < 65536 else { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
    private static func privateSave(_ data: Data, _ url: URL) throws {
        let fm = FileManager.default, parent = url.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            guard try fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
        } else { try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        if fm.fileExists(atPath: url.path), try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType != .typeRegular { throw CocoaError(.fileWriteNoPermission) }
        let staging = parent.appendingPathComponent(".home-scope-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        guard fm.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/**
 * [INPUT]: 依赖 Foundation 的 Data/Date/NSLock 与 AppKit 的 NSImage 解码校验；消费客户端提供的批次与图片稳定身份。
 * [OUTPUT]: 对外提供 ImageBatchStore，负责多图幂等暂存、顺序完整性校验、成功消费、过期与内存总量回收。
 * [POS]: Sources 的图片批次资源层；Server 写入，InputExecutor 在焦点校验后读取并在提交完成后消费，隔离协议与系统粘贴。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

final class ImageBatchStore {
    static let maxImages = 8
    static let maxImageBytes = 8 * 1024 * 1024
    static let maxBatchBytes = 40 * 1024 * 1024
    static let maxTotalBytes = 80 * 1024 * 1024
    static let ttl: TimeInterval = 15 * 60

    private struct Entry { var data: Data; var touched: Date }
    private var batches: [String: [String: Entry]] = [:]
    private let lock = NSLock()

    func stage(batchId: String, imageId: String, data: Data) throws {
        guard valid(batchId), valid(imageId) else { throw InputError.message("图片批次身份无效。") }
        guard data.count <= Self.maxImageBytes else { throw InputError.message("单张图片不能超过 8MB。") }
        guard NSImage(data: data) != nil else { throw InputError.message("图片无法读取，请重新选择。") }
        lock.lock(); defer { lock.unlock() }
        cleanup(now: Date())
        var batch = batches[batchId] ?? [:]
        guard batch[imageId] != nil || batch.count < Self.maxImages else { throw InputError.message("一次最多选择 8 张图片。") }
        let oldBytes = batch[imageId]?.data.count ?? 0
        let batchBytes = batch.values.reduce(0) { $0 + $1.data.count } - oldBytes + data.count
        guard batchBytes <= Self.maxBatchBytes else { throw InputError.message("本批图片总计不能超过 40MB。") }
        let totalBytes = batches.values.flatMap(\.values).reduce(0) { $0 + $1.data.count } - oldBytes + data.count
        guard totalBytes <= Self.maxTotalBytes else { throw InputError.message("待发送图片过多，请先发送已有图片。") }
        batch[imageId] = Entry(data: data, touched: Date())
        batches[batchId] = batch
    }

    func resolve(batchId: String, imageIds: [String]) throws -> [Data] {
        guard valid(batchId), !imageIds.isEmpty, imageIds.count <= Self.maxImages,
              Set(imageIds).count == imageIds.count, imageIds.allSatisfy(valid) else {
            throw InputError.message("图片列表无效。")
        }
        lock.lock(); defer { lock.unlock() }
        cleanup(now: Date())
        guard var batch = batches[batchId] else { throw InputError.message("图片已过期，请重新选择。") }
        var result: [Data] = []
        for id in imageIds {
            guard var entry = batch[id], NSImage(data: entry.data) != nil else {
                throw InputError.message("图片未上传完整，请稍后重试。")
            }
            entry.touched = Date(); batch[id] = entry; result.append(entry.data)
        }
        batches[batchId] = batch
        return result
    }

    func consume(batchId: String, imageIds: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard var batch = batches[batchId] else { return }
        imageIds.forEach { batch.removeValue(forKey: $0) }
        batches[batchId] = batch.isEmpty ? nil : batch
    }

    private func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 100 }
    private func cleanup(now: Date) {
        for (batchId, batch) in batches {
            let fresh = batch.filter { now.timeIntervalSince($0.value.touched) <= Self.ttl }
            batches[batchId] = fresh.isEmpty ? nil : fresh
        }
    }
}

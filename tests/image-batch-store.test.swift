/**
 * [INPUT]: 依赖 AppKit 生成可解码 JPEG，直接消费 Sources/ImageBatchStore.swift 的批次资源接口。
 * [OUTPUT]: 提供无桌面副作用的可执行断言，覆盖批次隔离、幂等、顺序、完整性、数量/体积和解码边界。
 * [POS]: tests 的 Swift 隔离回归；单独编译运行，不启动 PocketDesk 服务或注入输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum InputError: Error { case message(String) }

func jpeg(_ color: NSColor) -> Data {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
}

let store = ImageBatchStore()
let first = jpeg(.red), second = jpeg(.blue)
try store.stage(batchId: "batch-a", imageId: "1", data: first)
try store.stage(batchId: "batch-a", imageId: "2", data: second)
try store.stage(batchId: "batch-a", imageId: "1", data: first)
let ordered = try store.resolve(batchId: "batch-a", imageIds: ["2", "1"])
precondition(ordered == [second, first])
try store.stage(batchId: "batch-b", imageId: "1", data: second)
let isolated = try store.resolve(batchId: "batch-b", imageIds: ["1"])
precondition(isolated == [second])
do { _ = try store.resolve(batchId: "batch-a", imageIds: ["1", "missing"]); preconditionFailure("缺图应整批失败") } catch {}
do { _ = try store.resolve(batchId: "batch-a", imageIds: ["1", "1"]); preconditionFailure("重复图片身份应拒绝") } catch {}
let limitStore = ImageBatchStore()
for index in 0..<ImageBatchStore.maxImages { try limitStore.stage(batchId: "limit", imageId: "\(index)", data: first) }
do { try limitStore.stage(batchId: "limit", imageId: "overflow", data: first); preconditionFailure("第 9 张应拒绝") } catch {}
do { try limitStore.stage(batchId: "large", imageId: "1", data: Data(count: ImageBatchStore.maxImageBytes + 1)); preconditionFailure("超过 8MiB 应拒绝") } catch {}
store.consume(batchId: "batch-a", imageIds: ["1", "2"])
do { _ = try store.resolve(batchId: "batch-a", imageIds: ["1"]); preconditionFailure("消费后不应存在") } catch {}
do { try store.stage(batchId: "bad", imageId: "bad", data: Data([1, 2, 3])); preconditionFailure("损坏图片应拒绝") } catch {}
print("image batch store tests passed")

import Foundation

struct RotationBatchItem: Codable, Equatable, Sendable {
    let itemId: String
    var mediaSourceId: String? = nil
    let title: String
}
struct RotationBatchRequest: Codable, Equatable, Sendable {
    let requestId: UUID
    let quarterTurns: Int
    let items: [RotationBatchItem]
}
struct RotationBatchEntry: Codable, Hashable, Identifiable, Sendable {
    let itemId: String
    let mediaSourceId: String?
    let title: String
    let state: String
    let jobId: UUID?
    let errorCode: String?
    let stage: String?
    let progress: Int
    var id: String { itemId }
    var stateTitle: String { RotationBatch.stateTitle(state) }
}
struct RotationBatch: Codable, Hashable, Identifiable, Sendable {
    let batchId: UUID
    let requestId: UUID
    let quarterTurns: Int
    let state: String
    let total: Int
    let completed: Int
    let failed: Int
    let remaining: Int
    let cancelled: Int
    let needsVerification: Int
    let updatedAt: String
    let current: RotationBatchEntry?
    let items: [RotationBatchEntry]?
    var id: UUID { batchId }
    var countsKey: String { "\(completed):\(failed):\(remaining):\(cancelled):\(needsVerification):\(state)" }
    func carryingItems(_ items: [RotationBatchEntry]?) -> Self {
        Self(batchId: batchId, requestId: requestId, quarterTurns: quarterTurns, state: state, total: total, completed: completed, failed: failed, remaining: remaining, cancelled: cancelled, needsVerification: needsVerification, updatedAt: updatedAt, current: current, items: items)
    }
    var active: Bool { ["queued", "running", "pausing", "cancelling"].contains(state) }
    var stateTitle: String { Self.stateTitle(state) }
    var finishedCount: Int { completed + failed + cancelled + needsVerification }
    static func stateTitle(_ state: String) -> String {
        switch state {
        case "queued": "排队中"
        case "running": "处理中"
        case "pausing": "当前文件完成后暂停"
        case "cancelling": "当前文件完成后取消"
        case "paused": "已暂停"
        case "completed": "已保存"
        case "finished": "处理结束"
        case "failed": "未完成"
        case "cancelled": "已取消"
        case "needs_verification": "需要核对"
        default: "等待更新"
        }
    }
}
struct RotationItemState: Codable, Equatable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let state: String
    let stage: String
    let progress: Int
    let errorCode: String?
    let revision: String?
    let restored: Bool
    let jobId: UUID?
    let previewMediaSourceId: String?
    var title: String {
        switch state {
        case "queued": return "等待旋转"
        case "running", "committing": return "正在旋转"
        case "needs_verification": return "方向待核对"
        case "failed", "recovery_failed": return "旋转未完成"
        default:
            let alternate = mediaSourceId.replacingOccurrences(of: "-", with: "").lowercased() != itemId.replacingOccurrences(of: "-", with: "").lowercased()
            return restored ? (alternate ? "版本方向已还原" : "方向已还原") : (alternate ? "版本方向已保存" : "方向已保存")
        }
    }
}

extension JellyfinRotationCapability {
    var supportsBatchRotation: Bool {
        let parts = pluginVersion.split(separator: ".").compactMap { Int($0) }
        guard supportsSafePublication, parts.count >= 3 else { return false }
        return parts[0] > 1 || (parts[0] == 1 && parts[1] >= 1)
    }
}

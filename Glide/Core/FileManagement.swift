import Foundation

enum FileOperation: String, Codable, CaseIterable {
    case move, trash, restore
    var title: String { switch self { case .move: "移动视频"; case .trash: "删除到回收目录"; case .restore: "还原到原目录" } }
    var symbol: String { switch self { case .move: "folder"; case .trash: "trash"; case .restore: "arrow.uturn.backward" } }
}
struct FileManagementCapability: Decodable {
    let protocolVersion: Int
    let pluginVersion: String
    let available: Bool
    let ready: Bool
    let maximumItems: Int
    let softDelete: Bool
    let sameLibraryOnly: Bool
}
struct FileActionItem: Codable, Equatable, Identifiable {
    let itemId: String
    let mediaSourceId: String
    let expectedVersion: String
    let title: String
    var id: String { itemId }
}
struct FileActionInspection: Decodable, Identifiable {
    let itemId: String
    let mediaSourceId: String
    let title: String
    let version: String
    let relatedFiles: Int
    let errorCode: String?
    var id: String { itemId }
    var item: FileActionItem { FileActionItem(itemId: itemId, mediaSourceId: mediaSourceId, expectedVersion: version, title: title) }
}
struct FileActionRequest: Codable, Equatable {
    let requestId: UUID
    let operation: FileOperation
    let items: [FileActionItem]
    var destinationId: String?
    var restoreBatchId: UUID?
    func validate() throws {
        guard !items.isEmpty, items.count <= 500, Set(items.map { $0.itemId.lowercased() }).count == items.count,
              items.allSatisfy({ !$0.itemId.isEmpty && !$0.mediaSourceId.isEmpty && !$0.expectedVersion.isEmpty }),
              operation != .move || destinationId?.isEmpty == false,
              operation != .restore || restoreBatchId != nil else { throw FileManagementFailure("invalid_batch") }
    }
}
struct FileDestination: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let canChoose: Bool
}
struct FileFolderPage: Decodable {
    let current: FileDestination?
    let folders: [FileDestination]
    let nextIndex: Int
    let total: Int
}
struct FileActionEntry: Codable, Identifiable {
    let itemId: String
    let mediaSourceId: String
    let title: String
    let state: String
    let errorCode: String?
    let relatedFiles: Int
    var id: String { itemId }
}
struct FileActionBatch: Codable, Identifiable {
    let batchId: UUID
    let requestId: UUID
    let operation: FileOperation
    let destinationName: String
    let state: String
    let updatedAt: String
    let total: Int
    let completed: Int
    let failed: Int
    let remaining: Int
    let cancelled: Int
    let needsVerification: Int
    let canRestore: Bool
    let refreshPending: Bool
    let items: [FileActionEntry]
    var id: UUID { batchId }
    var active: Bool { state == "queued" || state == "running" }
    var attention: Bool { failed > 0 || needsVerification > 0 || state == "paused" || refreshPending }
    var finished: Int { completed + failed + cancelled + needsVerification }
    var stateTitle: String { Self.title(state) }
    static func title(_ state: String) -> String {
        switch state {
        case "queued": "等待处理"
        case "running": "处理中"
        case "paused": "已暂停后续"
        case "completed": "已完成"
        case "finished": "处理结束"
        case "failed": "未完成"
        case "cancelled": "已取消"
        case "needs_verification": "需要核对"
        default: "等待更新"
        }
    }
    var restoreItems: [FileActionItem] { items.filter { $0.state == "completed" }.map { FileActionItem(itemId: $0.itemId, mediaSourceId: $0.mediaSourceId, expectedVersion: "journal", title: $0.title) } }
}
struct FileManagementFailure: LocalizedError {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? { Self.message(code) }
    static func message(_ code: String) -> String {
        switch code {
        case "plugin_missing", "protocol_unsupported": "请将 Glide Toolkit 更新至 1.2.0 或更新版本。"
        case "file_management_disabled", "permission_denied": "请让管理员在 Glide Toolkit 设置开启家庭视频文件整理，并单独授权当前用户。"
        case "server_preparing": "服务器正在恢复任务，请稍后重试。"
        case "invalid_batch": "每批选择 1–500 个家庭视频，移动前请选择目标目录。"
        case "destination_exists", "atomic_publish_17": "目标目录已有同名文件，已保留两边文件，不会覆盖。"
        case "same_directory": "视频已经位于这个目录。"
        case "same_library_required", "outside_library": "移动范围限于同一个媒体库根目录和管理员授权范围。"
        case "destination_not_writable", "write_denied": "目录或文件没有写入权限，请检查 NAS 权限。"
        case "file_changed", "source_changed", "destination_changed": "文件或目录已变化，请刷新列表后重新选择。"
        case "active_playback", "file_busy": "视频正在播放、旋转或被其他任务使用，稍后可仅重试失败项。"
        case "atomic_publish_18": "目标位于另一磁盘，未移动原文件；请选择同一磁盘中的目录。"
        case "atomic_replace_unsupported", "atomic_publish_22", "atomic_publish_95": "此目录不支持安全且不覆盖的移动操作，原文件已保留。"
        case "home_video_only", "version_selection_required": "仅支持可明确定位主文件的家庭视频，不处理电影、剧集目录或多版本条目。"
        case "restore_conflict": "该任务已有还原记录，或仍有文件未处理完成。请查看整理任务。"
        case "uncertain_commit": "保存结果需要核对，请保留原目录和回收目录，暂勿重复处理。"
        case "interrupted": "服务器重启中断了此项，已检查文件位置；可仅重试失败项。"
        case "file_missing", "item_missing": "视频已移动、删除或尚未被 Jellyfin 扫描，请刷新媒体库。"
        case "shared_sidecar": "所选视频共用外挂字幕，请分开处理，避免移动其他视频的字幕。"
        case "symbolic_link", "reserved_path": "不支持符号链接或应用保留的备份、回收目录。"
        case "queue_full": "服务器当前队列已满，请等待已有任务完成。"
        case "pending_submission": "有一次未确认的提交，请先在整理任务中核对，避免重复执行。"
        default: "此项未完成，请刷新后重试；原文件和任务记录会保留。（\(code)）"
        }
    }
}

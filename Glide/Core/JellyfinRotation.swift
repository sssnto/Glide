import Foundation

struct JellyfinRotationTarget: Equatable, Sendable {
    let server: MediaServer
    let videoID: String
    let itemID: String
    let mediaSourceID: String
    let title: String
    init?(video: Video, server: MediaServer?, resourceURL: URL?, mediaSourceID: String?) {
        guard let server,server.kind == .jellyfin,server.id == video.sourceID,video.offlineOnly != true,
              video.streamLinkID == nil,let itemID=video.remoteID,!itemID.isEmpty,
              let resourceURL,!resourceURL.isFileURL,let mediaSourceID,!mediaSourceID.isEmpty else { return nil }
        self.server=server;self.videoID=video.id;self.itemID=itemID;self.mediaSourceID=mediaSourceID;title=video.title
    }
}
enum PlayerRotationTarget: Equatable {
    case webDAV(WebDAVRotationTarget), jellyfin(JellyfinRotationTarget)
    var fileName:String { switch self { case .webDAV(let value):value.file.lastPathComponent;case .jellyfin(let value):value.title } }
    var isServerTask:Bool { if case .jellyfin = self { true } else { false } }
}
struct JellyfinRotationCapability: Codable, Equatable, Sendable {
    let protocolVersion:Int
    let pluginVersion:String
    let available:Bool
    let reason:String?
    var itemId:String?
    var mediaSourceId:String?
    var fileName:String?
    var version:String?
    var fileBytes:Int64?
    var supportedExtensions:[String]?
    var supportsSafePublication:Bool {
        let components=pluginVersion.split(separator:".",omittingEmptySubsequences:false)
        let parts=components.compactMap { Int($0) }
        guard parts.count>=3,parts.count==components.count,parts.allSatisfy({$0>=0}) else { return false }
        return parts[0]>1 || (parts[0]==1 && (parts[1]>0 || parts[2]>=3))
    }
}
struct JellyfinRotationRequest: Codable, Equatable, Sendable {
    let requestId:UUID
    let itemId:String
    let mediaSourceId:String
    let expectedVersion:String
    let quarterTurns:Int
    var restoreJobId:UUID?
}
struct JellyfinRotationJob: Codable, Equatable, Identifiable, Sendable {
    let jobId:UUID
    let requestId:UUID
    let itemId:String
    let mediaSourceId:String
    let state:String
    let stage:String
    let progress:Int
    let errorCode:String?
    let canRestore:Bool
    let refreshPending:Bool
    let updatedAt:String
    var publicationMode:String?=nil
    var failureCode:String?=nil
    var id:UUID { jobId }
    var isActive:Bool { ["queued","running","committing"].contains(state) }
    var completed:Bool { state == "completed" }
    var stageTitle:String {
        switch stage {
        case "queued":"等待服务器处理"
        case "waiting_playback":"等待其他播放结束"
        case "backing_up":"服务器正在备份原文件"
        case "preparing":"服务器正在修正方向"
        case "verifying":"服务器正在校验视频"
        case "replacing":"服务器正在保存原文件"
        case "completed":"已保存到服务器原文件"
        case "needs_verification":"服务器正在等待核对保存结果"
        case "original_restored":"原片已从备份恢复"
        default:"服务器处理未完成"
        }
    }
}
enum JellyfinRotationFailure: Error, LocalizedError {
    case code(String)
    var errorDescription:String? {
        guard case .code(let code)=self else { return nil }
        return switch code {
        case "batch_update_required":"请将服务器的 Glide 视频工具升级至 1.1.0 或更新版本，以使用批量旋转与新缩略图。"
        case "batch_pending":"上次提交的队列尚未确认，请先打开“旋转任务”核对；不要重复提交。"
        case "batch_too_large":"当前范围超过 1,000 个视频，请进入更小的目录后分批处理。"
        case "invalid_batch":"请选择 1 至 1,000 个来自当前 Jellyfin 的在线视频。"
        case "version_selection_required":"此视频有多个文件版本，服务器无法确定主文件，请在播放器中选择版本后单独旋转。"
        case "file_unavailable":"服务器暂时无法读取此文件，请检查挂载目录后重试。"
        case "journal_unavailable":"服务器暂时无法保存队列记录，请稍后在任务页核对。"
        case "plugin_missing":"服务器尚未安装 Glide 视频工具，暂不能远程保存方向。"
        case "plugin_update_required":"请先将服务器的 Glide 视频工具升级至 1.0.3 或更新版本，再保存方向。"
        case "permission_denied":"当前账号没有旋转保存权限，请由 Jellyfin 管理员授权。"
        case "write_denied":"服务器无法写入原文件，请检查媒体目录权限。"
        case "unsupported_format","invalid_container","multiple_video_tracks","unsupported_matrix":"此文件暂不支持服务器无损旋转，原文件已保留。"
        case "file_changed","source_changed","restore_conflict":"服务器原文件或媒体版本已变化，请重新打开后再操作。"
        case "file_busy","active_playback":"此视频仍在其他设备播放或处理，请稍后重试。"
        case let value where value.hasPrefix("file_lock_") || value.hasPrefix("file_unlock_"):"服务器未通过文件占用检查，原文件未替换。请结束其他设备播放后重试。"
        case "uncertain_commit":"服务器保存结果尚需核对，请勿重复旋转；原始备份已保留。"
        case "interrupted_before_commit":"服务器任务在替换前中断，原文件未替换，可重新发起。"
        case "backup_invalid","verification_failed":"服务器校验未通过，已保留备份，请检查任务状态。"
        case "remote_source":"这条媒体来源不是服务器可直接写入的原文件。"
        case "outside_library","symbolic_link":"此文件不在允许修改的目录内。"
        case "server_preparing":"服务器正在恢复任务记录，请稍后重试。"
        case "platform_unsupported":"此插件版本支持 Linux／NAS Docker 服务器。"
        case "protocol_unsupported":"服务器插件协议版本不匹配，请更新 Glide 或插件。"
        case "queue_full":"服务器任务队列已满，请稍后重试。"
        case "insufficient_space":"服务器空间不足，请为备份和临时文件预留空间。"
        case "metadata_unsupported":"服务器无法保留原文件的所有权或权限属性，已保留原文件。"
        case "atomic_replace_unsupported","atomic_probe_failed":"当前 NAS 目录未通过安全替换检查，已停止保存，原文件未改动。"
        case let value where value.hasPrefix("atomic_"):"当前 NAS 文件系统拒绝安全替换，请保留备份并检查服务器任务。"
        case "original_restored":"原片已从备份恢复，请刷新媒体库后重新打开视频。"
        default:"服务器未能完成处理，请查看任务状态。"
        }
    }
}

/// Persist before POST, including the request identity, to safely reissue a lost
/// response. Only ids/version are stored; no source paths, login or token.
struct JellyfinRotationPending: Codable, Equatable {
    let sourceID:UUID
    let videoID:String
    let request:JellyfinRotationRequest
    var jobID:UUID?
    func matches(_ target:JellyfinRotationTarget)->Bool {
        sourceID == target.server.id && videoID == target.videoID && request.itemId == target.itemID && request.mediaSourceId == target.mediaSourceID
    }
}

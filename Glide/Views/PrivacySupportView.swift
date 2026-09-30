import SwiftUI

struct PrivacySupportView: View {
    var body: some View {
        List {
            Section("数据存放") {
                Text("媒体来源、目录、观看记录、收藏和播放偏好保存在这台设备；登录令牌保存在系统钥匙串。海报与离线视频保存在应用沙盒。")
                Text("连接你指定的 Jellyfin 或 WebDAV 时，应用会直接向该服务器请求媒体和图片。观看进度与已看状态可能同步到你的 Jellyfin 账号。")
            }
            Section("诊断与控制") {
                Text("播放诊断只在你主动分享时导出。分享前可预览，不包含片名、服务器完整地址、密码或令牌。")
                Text("可以在设置中清除海报缓存，在离线下载页面管理文件，在个人片库中删除本机记录。删除来源会移除对应的本地资料与钥匙串令牌。")
            }
            Section("问题反馈") {
                Text("遇到播放问题，请提供版本、设备型号、复现步骤及脱敏诊断。无需发送服务器密码、令牌、完整地址或原视频。")
                Link("查看完整隐私政策", destination: URL(string: "https://glide.sssnto.cn/privacy.html")!)
                Link("查看支持页面", destination: URL(string: "https://glide.sssnto.cn/support.html")!)
                Link("邮件联系支持", destination: URL(string: "mailto:133317737@qq.com?subject=Glide%20Support")!)
            }
        }.navigationTitle("数据、隐私与帮助")
    }
}

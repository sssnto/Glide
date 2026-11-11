import SwiftUI

struct WorkspaceSettingsButton:View {
    let action:()->Void
    var body:some View {
        Button(action:action) { Image(systemName:"gearshape").frame(width:44,height:44) }
            .accessibilityLabel("设置与媒体来源").accessibilityIdentifier("workspace.settings")
    }
}
struct WorkspaceSettingsSheet:View {
    let library:LibraryStore
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack { SettingsView(library:library).toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } } }
    }
}
struct WorkspaceSectionHeading:View {
    let title:String
    var detail:String?=nil
    var body:some View {
        HStack(alignment:.firstTextBaseline) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength:8)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct WorkspaceFeatureLabel:View {
    let title:String
    let detail:String
    let symbol:String
    var body:some View {
        HStack(spacing:12) {
            Image(systemName:symbol).font(.title3).foregroundStyle(.tint)
                .frame(width:40,height:40).background(Color.accentColor.opacity(0.09),in:.rect(cornerRadius:11))
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth:.infinity,alignment:.leading)
            Image(systemName:"chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(14).frame(maxWidth:.infinity,minHeight:76,alignment:.leading)
            .background(GlideTheme.panel,in:.rect(cornerRadius:14)).contentShape(.rect)
            .accessibilityElement(children:.combine)
    }
}

struct WorkspaceResumeCard:View {
    let entry:ContinueWatchingItem
    let library:LibraryStore
    let action:()->Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var identity:RecommendationMediaIdentity { RecommendationMediaIdentity(entry.video) }
    var body:some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:10) {
                VideoArtwork(video:entry.video,contentMode:.fill,server:library.servers.first { $0.id==entry.video.sourceID })
                    .aspectRatio(16.0/9.0,contentMode:.fit)
                    .overlay(alignment:.bottomTrailing) {
                        Image(systemName:"play.fill").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width:44,height:44).background(.black.opacity(0.65),in:Circle()).padding(10)
                    }.clipShape(.rect(cornerRadius:12))
                VStack(alignment:.leading,spacing:5) {
                    Text(identity.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    if let episode=identity.episode { Text(episode).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    let position=library.resumePosition(entry.video)
                    HStack {
                        Text(entry.finished ? "已看完 · 重新观看" : position>0 ? "看到 "+position.mediaTime:"接着看下一集")
                        Spacer(minLength:8)
                        if let source=library.servers.first(where:{$0.id==entry.video.sourceID}) { Text(source.name).lineLimit(1) }
                    }.font(.caption2).foregroundStyle(.secondary)
                    if !entry.finished,entry.video.duration>0 {
                        ProgressView(value:min(position,entry.video.duration),total:entry.video.duration).tint(.accentColor)
                    }
                }
            }.frame(width:typeSize.isAccessibilitySize ? 280:252,alignment:.leading).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("workspace.resume."+entry.video.id)
    }
}

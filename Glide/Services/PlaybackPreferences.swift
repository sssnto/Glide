import Foundation

@MainActor enum PlaybackPreferences {
    static var audioLanguage: String { UserDefaults.standard.string(forKey: "preferredAudioLanguage") ?? "" }
    static var subtitleLanguage: String { UserDefaults.standard.string(forKey: "preferredSubtitleLanguage") ?? "" }
    static var subtitlesOff: Bool { subtitleLanguage == "off" }
    static var forcedOnly: Bool { UserDefaults.standard.bool(forKey: "forcedSubtitlesOnly") }
    static var subtitleScale: Double { let n = UserDefaults.standard.double(forKey: "subtitleScale"); return n > 0 ? n : 100 }
    static var cellularPlayback: Bool { UserDefaults.standard.object(forKey: "cellularPlayback") as? Bool ?? true }
    static var downloadWiFiOnly: Bool { UserDefaults.standard.object(forKey: "downloadWiFiOnly") as? Bool ?? true }
    static var downloadLimit: Int64 { let gb = UserDefaults.standard.integer(forKey: "downloadLimitGB"); return Int64(max(1, gb == 0 ? 20 : gb)) * 1_073_741_824 }
    static var seekInterval: Double { let value = UserDefaults.standard.double(forKey: "seekInterval"); return value > 0 ? value : 10 }
    static var controlsDelay: Double { let value = UserDefaults.standard.double(forKey: "controlsDelay"); return value > 0 ? value : 3 }
    static var appVersion: String { "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))" }
}

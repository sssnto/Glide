// A local feasibility experiment, excluded from the iOS app target.
// Reads only the three authored repository demos; never indexes private media.
import Foundation
import AVFoundation
import AppKit
import Vision

@main struct DiscoveryPrototype {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/Glide1100/ContentMapPrototype")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<3 {
            let input = root.appendingPathComponent("Glide/Resources/demo\(index).mp4")
            let asset = AVURLAsset(url: input), duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for second in [1.0, 4.0, 8.0] where second < duration {
                let sampleStarted = ProcessInfo.processInfo.systemUptime
                let frame = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                let name = "Demo\(index)-\(Int(second))s.png"
                let bitmap = NSBitmapImageRep(cgImage: frame.image)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name)) }
                var record: [String: Any] = ["sample": name, "requestedSeconds": second, "actualSeconds": frame.actualTime.seconds,
                    "width": frame.image.width, "height": frame.image.height,
                    "frameSeconds": ProcessInfo.processInfo.systemUptime - sampleStarted]
                let request = VNClassifyImageRequest()
                do {
                    let classifierStarted = ProcessInfo.processInfo.systemUptime
                    try VNImageRequestHandler(cgImage: frame.image).perform([request])
                    record["classificationSeconds"] = ProcessInfo.processInfo.systemUptime - classifierStarted
                    record["labels"] = Array((request.results ?? []).prefix(5)).map { ["label": $0.identifier, "confidence": Double($0.confidence)] as [String: Any] }
                } catch { record["classificationErrorCode"] = (error as NSError).code }
                records.append(record)
            }
        }
        let report: [String: Any] = ["scope": "macOS prototype with nine real authored-demo frames; no private media; no natural-language search capability claimed",
            "frames": records, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Results.json"))
        print("Authored frames: \(records.count). Prototype evidence: \(output.path)")
    }
}

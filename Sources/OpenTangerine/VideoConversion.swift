//
//  VideoConversion.swift
//  OpenTangerine
//
//  Video Transcoding & Metadata Inspection Engine
//  Supports: 3GP, AVI, FLV, MKV, MOV, MP4, OGV, WEBM, WMV
//  Integrates FFmpeg high-performance transcoding with Apple AVFoundation native fallback,
//  plus full technical metadata inspection and live video frame thumbnail extraction.
//

import SwiftUI
import AppKit
import Foundation
import AVFoundation

// MARK: - Process Runner

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunner {
    private final class DataBox: @unchecked Sendable { var data = Data() }

    public static func run(_ launchPath: String, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConversionError.archiveFailed("Couldn't launch \(URL(fileURLWithPath: launchPath).lastPathComponent): \(error.localizedDescription)")
        }

        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let errString = String(data: errBox.data, encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, stdout: outData, stderr: errString)
    }
}

// MARK: - Video Format Model

public enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4 = "mp4"
    case mov = "mov"
    case webm = "webm"
    case mkv = "mkv"
    case avi = "avi"
    case wmv = "wmv"
    case flv = "flv"
    case threeGP = "3gp"
    case ogv = "ogv"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .webm: return "WEBM"
        case .mkv: return "MKV"
        case .avi: return "AVI"
        case .wmv: return "WMV"
        case .flv: return "FLV"
        case .threeGP: return "3GP"
        case .ogv: return "OGV"
        }
    }

    public var isNativeSupported: Bool {
        switch self {
        case .mp4, .mov, .threeGP:
            return true
        default:
            return false
        }
    }

    public static func from(extension ext: String) -> VideoFormat? {
        let normalized = FileCategory.normalizedExtension(ext)
        switch normalized {
        case "3gp", "3g2", "3gpp": return .threeGP
        case "avi": return .avi
        case "flv", "f4v": return .flv
        case "mkv": return .mkv
        case "mov", "qt": return .mov
        case "mp4", "m4v": return .mp4
        case "ogv", "ogg": return .ogv
        case "webm": return .webm
        case "wmv", "asf": return .wmv
        default: return nil
        }
    }
}

// MARK: - FFmpeg & FFprobe Discovery

public enum FFmpegDiscovery {
    private static var cachedPath: String?
    private static var cachedProbePath: String?

    public static func resolvePath() -> String? {
        if let cached = cachedPath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        if let env = ProcessInfo.processInfo.environment["FFMPEG_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            cachedPath = env
            return env
        }
        if let bundlePath = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            cachedPath = bundlePath
            return bundlePath
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
            "\(home)/.local/bin/ffmpeg",
            "\(home)/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedPath = candidate
                return candidate
            }
        }

        // Check `which ffmpeg` in current environment PATH
        if let which = try? ProcessRunner.run("/usr/bin/which", ["ffmpeg"]),
           which.status == 0,
           let path = String(data: which.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            cachedPath = path
            return path
        }

        return nil
    }

    public static func resolveProbePath() -> String? {
        if let cached = cachedProbePath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        if let ffmpeg = resolvePath() {
            let candidate = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedProbePath = candidate
                return candidate
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/opt/homebrew/opt/ffmpeg/bin/ffprobe",
            "\(home)/.local/bin/ffprobe",
            "\(home)/bin/ffprobe",
            "/opt/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedProbePath = candidate
                return candidate
            }
        }
        if let which = try? ProcessRunner.run("/usr/bin/which", ["ffprobe"]),
           which.status == 0,
           let path = String(data: which.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            cachedProbePath = path
            return path
        }
        return nil
    }

    public static var isAvailable: Bool {
        resolvePath() != nil
    }
}

// MARK: - Video Conversion Engine

public final class VideoConversionEngine: @unchecked Sendable {
    public static let shared = VideoConversionEngine()

    public let supportedTargetExtensions: [String] = [
        "mp4", "mov", "webm", "mkv", "avi", "wmv", "flv", "3gp", "ogv"
    ]

    public func canConvert(to targetExt: String) -> Bool {
        let ext = FileCategory.normalizedExtension(targetExt)
        return supportedTargetExtensions.contains(ext)
    }

    public func convertVideo(sourceURL: URL, destinationURL: URL, format: String) throws {
        let targetExt = FileCategory.normalizedExtension(format)

        guard canConvert(to: targetExt) else {
            throw ConversionError.unsupportedConversion(
                "\(sourceURL.pathExtension.uppercased()) → \(targetExt.uppercased()) is not supported"
            )
        }

        if let ffmpegPath = FFmpegDiscovery.resolvePath() {
            try convertWithFFmpeg(ffmpegPath: ffmpegPath, sourceURL: sourceURL, destinationURL: destinationURL, format: targetExt)
        } else {
            // No FFmpeg on this system: try native AVFoundation
            let nativeFormats = ["mp4", "mov", "3gp"]
            if nativeFormats.contains(targetExt) {
                try convertWithAVFoundation(sourceURL: sourceURL, destinationURL: destinationURL, format: targetExt)
            } else {
                throw ConversionError.unsupportedConversion(
                    "Converting to \(targetExt.uppercased()) requires FFmpeg. Install it with: brew install ffmpeg"
                )
            }
        }

        // Verify the resulting file was created and is non-empty
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDir),
              !isDir.boolValue,
              (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            throw ConversionError.exportFailed("Video conversion generated an empty or missing output file.")
        }
    }

    // MARK: FFmpeg Conversion

    private func convertWithFFmpeg(ffmpegPath: String, sourceURL: URL, destinationURL: URL, format: String) throws {
        // Safe dimensions filter: ensures width and height are divisible by 2 (prevents encoder rejection on odd dimensions)
        let scaleFilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

        var formatArgs: [String]
        switch format {
        case "mp4":
            formatArgs = [
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-vf", scaleFilter,
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart"
            ]

        case "mov":
            formatArgs = [
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-vf", scaleFilter,
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart"
            ]

        case "webm":
            formatArgs = [
                "-c:v", "libvpx-vp9",
                "-crf", "30",
                "-b:v", "0",
                "-vf", scaleFilter,
                "-c:a", "libopus",
                "-b:a", "128k"
            ]

        case "mkv":
            formatArgs = [
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-vf", scaleFilter,
                "-c:a", "aac",
                "-b:a", "192k"
            ]

        case "avi":
            formatArgs = [
                "-c:v", "mpeg4",
                "-q:v", "3",
                "-vf", scaleFilter,
                "-c:a", "libmp3lame",
                "-b:a", "192k"
            ]

        case "wmv":
            formatArgs = [
                "-c:v", "wmv2",
                "-b:v", "2M",
                "-vf", scaleFilter,
                "-c:a", "wmav2",
                "-b:a", "192k"
            ]

        case "flv":
            formatArgs = [
                "-c:v", "flv",
                "-q:v", "3",
                "-vf", scaleFilter,
                "-c:a", "libmp3lame",
                "-b:a", "128k"
            ]

        case "3gp":
            formatArgs = [
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-vf", scaleFilter,
                "-c:a", "aac",
                "-b:a", "64k"
            ]

        case "ogv":
            formatArgs = [
                "-c:v", "libvpx",
                "-vf", scaleFilter,
                "-c:a", "flac"
            ]

        default:
            formatArgs = [
                "-vf", scaleFilter
            ]
        }

        let fullArgs = ["-nostdin", "-y", "-i", sourceURL.path] + formatArgs + [destinationURL.path]
        let result = try ProcessRunner.run(ffmpegPath, fullArgs)

        if result.status != 0 {
            // Secondary fallback attempt without specific codec flags in case input audio/video streams have quirks
            let fallbackArgs = ["-nostdin", "-y", "-i", sourceURL.path, destinationURL.path]
            let fallbackResult = try ProcessRunner.run(ffmpegPath, fallbackArgs)
            if fallbackResult.status != 0 {
                let errText = fallbackResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = errText.split(separator: "\n").suffix(3).joined(separator: " ")
                throw ConversionError.exportFailed(summary.isEmpty ? "FFmpeg exited with code \(fallbackResult.status)" : summary)
            }
        }
    }

    // MARK: AVFoundation Native Fallback

    private func convertWithAVFoundation(sourceURL: URL, destinationURL: URL, format: String) throws {
        let asset = AVURLAsset(url: sourceURL)

        let outputFileType: AVFileType
        let preset: String

        switch format {
        case "mp4":
            outputFileType = .mp4
            preset = AVAssetExportPresetHighestQuality
        case "mov":
            outputFileType = .mov
            preset = AVAssetExportPresetHighestQuality
        case "3gp":
            outputFileType = .mobile3GPP
            preset = AVAssetExportPresetMediumQuality
        default:
            throw ConversionError.unsupportedConversion("AVFoundation does not support .\(format). Please install FFmpeg: brew install ffmpeg")
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.exportFailed("Could not create AVAssetExportSession for \(sourceURL.lastPathComponent)")
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true

        let semaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        switch exportSession.status {
        case .completed:
            return
        case .failed:
            let msg = exportSession.error?.localizedDescription ?? "AVFoundation export failed"
            throw ConversionError.exportFailed(msg)
        case .cancelled:
            throw ConversionError.exportFailed("Export was cancelled")
        default:
            throw ConversionError.exportFailed("Export finished with status \(exportSession.status.rawValue)")
        }
    }
}

// MARK: - Video Metadata Report

public struct VideoMetadataReport: Sendable {
    public let fileName: String
    public let format: String
    public let dimensions: String
    public let durationString: String
    public let frameRate: String
    public let fileSize: String
    public let badges: [String]
    public let sections: [ImageMetadataSection]
    public let fullTextSummary: String
    public let errorMessage: String?

    public static func load(from url: URL) -> VideoMetadataReport {
        let fileAttrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSizeBytes = (fileAttrs[.size] as? NSNumber)?.int64Value ?? 0
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
        let ext = url.pathExtension.uppercased()

        // 1. Try ffprobe for deep stream inspection
        if let probePath = FFmpegDiscovery.resolveProbePath(),
           let probeResult = try? ProcessRunner.run(probePath, ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path]),
           probeResult.status == 0,
           let json = try? JSONSerialization.jsonObject(with: probeResult.stdout) as? [String: Any] {
            return parseFFprobe(json: json, url: url, fileSizeStr: fileSizeStr, ext: ext, attrs: fileAttrs)
        }

        // 2. Fallback to AVURLAsset (works for native macOS containers)
        return parseAVFoundation(url: url, fileSizeStr: fileSizeStr, ext: ext, attrs: fileAttrs)
    }

    private static func parseFFprobe(json: [String: Any], url: URL, fileSizeStr: String, ext: String, attrs: [FileAttributeKey: Any]) -> VideoMetadataReport {
        let streams = json["streams"] as? [[String: Any]] ?? []
        let formatDict = json["format"] as? [String: Any] ?? [:]

        let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" })
        let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

        // Video attributes
        let width = videoStream?["width"] as? Int ?? 0
        let height = videoStream?["height"] as? Int ?? 0
        let dimStr = (width > 0 && height > 0) ? "\(width) × \(height) px" : "Unknown"
        let dar = videoStream?["display_aspect_ratio"] as? String ?? ""
        let fpsRaw = (videoStream?["avg_frame_rate"] as? String) ?? (videoStream?["r_frame_rate"] as? String) ?? ""
        let fpsStr = cleanFrameRate(fpsRaw)
        let videoCodec = (videoStream?["codec_long_name"] as? String) ?? (videoStream?["codec_name"] as? String) ?? "Unknown"
        let profile = videoStream?["profile"] as? String ?? ""
        let pixFmt = videoStream?["pix_fmt"] as? String ?? ""
        let videoBitrate = (videoStream?["bit_rate"] as? String).flatMap(Double.init)

        // Audio attributes
        let audioCodec = (audioStream?["codec_long_name"] as? String) ?? (audioStream?["codec_name"] as? String)
        let channels = audioStream?["channels"] as? Int
        let channelLayout = audioStream?["channel_layout"] as? String
        let sampleRate = (audioStream?["sample_rate"] as? String).flatMap(Int.init)
        let audioBitrate = (audioStream?["bit_rate"] as? String).flatMap(Double.init)

        // Format / Container attributes
        let durationSec = (formatDict["duration"] as? String).flatMap(Double.init) ?? 0
        let durationStr = formatDuration(durationSec)
        let formatLongName = (formatDict["format_long_name"] as? String) ?? (formatDict["format_name"] as? String) ?? ext
        let overallBitrate = (formatDict["bit_rate"] as? String).flatMap(Double.init)
        let tags = formatDict["tags"] as? [String: String] ?? [:]
        let encoder = tags["ENCODER"] ?? tags["encoder"] ?? tags["handler_name"]

        var badges: [String] = []
        if dimStr != "Unknown" { badges.append(dimStr.replacingOccurrences(of: " px", with: "")) }
        if durationSec > 0 { badges.append(durationStr) }
        if !fpsStr.isEmpty && fpsStr != "0 fps" { badges.append(fpsStr) }
        badges.append(fileSizeStr)

        var sections: [ImageMetadataSection] = []

        // General section
        var generalItems: [ImageMetadataItem] = [
            ImageMetadataItem(label: "Name", value: url.lastPathComponent),
            ImageMetadataItem(label: "Kind", value: "\(ext) Video"),
            ImageMetadataItem(label: "File Size", value: fileSizeStr),
            ImageMetadataItem(label: "Location", value: url.deletingLastPathComponent().path)
        ]
        if let created = attrs[.creationDate] as? Date {
            generalItems.append(ImageMetadataItem(label: "Created", value: formatDate(created)))
        }
        if let modified = attrs[.modificationDate] as? Date {
            generalItems.append(ImageMetadataItem(label: "Modified", value: formatDate(modified)))
        }
        sections.append(ImageMetadataSection(title: "General", icon: "film", items: generalItems))

        // Video Stream section
        var videoItems: [ImageMetadataItem] = []
        if videoStream != nil {
            let codecDisplay = profile.isEmpty ? videoCodec : "\(videoCodec) (\(profile))"
            videoItems.append(ImageMetadataItem(label: "Codec", value: codecDisplay))
            videoItems.append(ImageMetadataItem(label: "Resolution", value: dimStr))
            if !dar.isEmpty && dar != "0:1" {
                videoItems.append(ImageMetadataItem(label: "Aspect Ratio", value: dar))
            }
            if !fpsStr.isEmpty && fpsStr != "0 fps" {
                videoItems.append(ImageMetadataItem(label: "Frame Rate", value: fpsStr))
            }
            if !pixFmt.isEmpty {
                videoItems.append(ImageMetadataItem(label: "Pixel Format", value: pixFmt))
            }
            if let vb = videoBitrate, vb > 0 {
                videoItems.append(ImageMetadataItem(label: "Bitrate", value: formatBitrate(vb)))
            }
            sections.append(ImageMetadataSection(title: "Video Stream", icon: "video", items: videoItems))
        }

        // Audio Stream section
        if let ac = audioCodec {
            var audioItems: [ImageMetadataItem] = [
                ImageMetadataItem(label: "Codec", value: ac)
            ]
            if let ch = channels {
                let layout = channelLayout.map { " (\($0))" } ?? ""
                audioItems.append(ImageMetadataItem(label: "Channels", value: "\(ch) channel\(ch == 1 ? "" : "s")\(layout)"))
            }
            if let sr = sampleRate {
                audioItems.append(ImageMetadataItem(label: "Sample Rate", value: "\(NumberFormatter.localizedString(from: NSNumber(value: sr), number: .decimal)) Hz"))
            }
            if let ab = audioBitrate, ab > 0 {
                audioItems.append(ImageMetadataItem(label: "Bitrate", value: formatBitrate(ab)))
            }
            sections.append(ImageMetadataSection(title: "Audio Stream", icon: "waveform", items: audioItems))
        }

        // Container / Details section
        var containerItems: [ImageMetadataItem] = [
            ImageMetadataItem(label: "Container", value: formatLongName),
            ImageMetadataItem(label: "Duration", value: "\(durationStr) (\(String(format: "%.2f", durationSec))s)")
        ]
        if let ob = overallBitrate, ob > 0 {
            containerItems.append(ImageMetadataItem(label: "Total Bitrate", value: formatBitrate(ob)))
        }
        if let enc = encoder, !enc.isEmpty {
            containerItems.append(ImageMetadataItem(label: "Encoder", value: enc))
        }
        sections.append(ImageMetadataSection(title: "Container & Specs", icon: "shippingbox", items: containerItems))

        let summary = buildTextSummary(name: url.lastPathComponent, sections: sections)

        return VideoMetadataReport(
            fileName: url.lastPathComponent,
            format: ext,
            dimensions: dimStr,
            durationString: durationStr,
            frameRate: fpsStr,
            fileSize: fileSizeStr,
            badges: badges,
            sections: sections,
            fullTextSummary: summary,
            errorMessage: nil
        )
    }

    private static func parseAVFoundation(url: URL, fileSizeStr: String, ext: String, attrs: [FileAttributeKey: Any]) -> VideoMetadataReport {
        let asset = AVURLAsset(url: url)
        let durationSec = asset.duration.seconds
        let durationStr = durationSec.isFinite && durationSec > 0 ? formatDuration(durationSec) : "Unknown"

        var dimStr = "Unknown"
        var fpsStr = ""

        if let vTrack = asset.tracks(withMediaType: .video).first {
            let size = vTrack.naturalSize
            if size.width > 0 && size.height > 0 {
                dimStr = "\(Int(size.width)) × \(Int(size.height)) px"
            }
            let fps = vTrack.nominalFrameRate
            if fps > 0 {
                fpsStr = String(format: "%.2f fps", fps)
            }
        }

        var badges: [String] = []
        if dimStr != "Unknown" { badges.append(dimStr.replacingOccurrences(of: " px", with: "")) }
        if durationStr != "Unknown" { badges.append(durationStr) }
        if !fpsStr.isEmpty { badges.append(fpsStr) }
        badges.append(fileSizeStr)

        var sections: [ImageMetadataSection] = []

        var generalItems: [ImageMetadataItem] = [
            ImageMetadataItem(label: "Name", value: url.lastPathComponent),
            ImageMetadataItem(label: "Kind", value: "\(ext) Video"),
            ImageMetadataItem(label: "File Size", value: fileSizeStr),
            ImageMetadataItem(label: "Location", value: url.deletingLastPathComponent().path)
        ]
        if let created = attrs[.creationDate] as? Date {
            generalItems.append(ImageMetadataItem(label: "Created", value: formatDate(created)))
        }
        if let modified = attrs[.modificationDate] as? Date {
            generalItems.append(ImageMetadataItem(label: "Modified", value: formatDate(modified)))
        }
        sections.append(ImageMetadataSection(title: "General", icon: "film", items: generalItems))

        var videoItems: [ImageMetadataItem] = [
            ImageMetadataItem(label: "Resolution", value: dimStr)
        ]
        if !fpsStr.isEmpty {
            videoItems.append(ImageMetadataItem(label: "Frame Rate", value: fpsStr))
        }
        sections.append(ImageMetadataSection(title: "Video Stream", icon: "video", items: videoItems))

        let summary = buildTextSummary(name: url.lastPathComponent, sections: sections)

        return VideoMetadataReport(
            fileName: url.lastPathComponent,
            format: ext,
            dimensions: dimStr,
            durationString: durationStr,
            frameRate: fpsStr,
            fileSize: fileSizeStr,
            badges: badges,
            sections: sections,
            fullTextSummary: summary,
            errorMessage: nil
        )
    }

    private static func cleanFrameRate(_ raw: String) -> String {
        let parts = raw.split(separator: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
            let fps = num / den
            if fps <= 0 { return "" }
            if fps.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(fps)) fps"
            } else {
                return String(format: "%.2f fps", fps)
            }
        }
        if let fps = Double(raw), fps > 0 {
            return String(format: "%.2f fps", fps)
        }
        return ""
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00" }
        let s = Int(seconds.rounded())
        let hrs = s / 3600
        let mins = (s % 3600) / 60
        let secs = s % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }

    private static func formatBitrate(_ bps: Double) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.2f Mbps", bps / 1_000_000.0)
        } else if bps >= 1_000 {
            return String(format: "%.0f kbps", bps / 1_000.0)
        } else {
            return "\(Int(bps)) bps"
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func buildTextSummary(name: String, sections: [ImageMetadataSection]) -> String {
        var lines: [String] = ["=== Video Metadata: \(name) ===", ""]
        for section in sections {
            lines.append("[\(section.title.uppercased())]")
            for item in section.items {
                lines.append("  \(item.label): \(item.value)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Video Inspector View

public struct VideoInspectorView: View {
    public let sourceURL: URL
    public var onClose: () -> Void

    @State private var report: VideoMetadataReport?
    @State private var thumbnail: NSImage?
    @State private var copied: Bool = false
    @State private var loadTask: Task<Void, Never>?

    @ObservedObject private var theme = ThemeManager.shared

    public init(sourceURL: URL, onClose: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            ZStack {
                Text("Video Inspector")
                    .font(.system(size: 14, weight: .bold))
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(14)
            .background(WindowDragHandle())

            // Summary card
            HStack(spacing: 12) {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 58, height: 58)
                        .overlay(Image(systemName: "film").foregroundColor(.secondary))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceURL.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        badge(text: report?.format ?? sourceURL.pathExtension.uppercased(), isAccent: true)
                        ForEach(report?.badges ?? [], id: \.self) { badge(text: $0, isAccent: false) }
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Content scroll area
            if let report {
                if let error = report.errorMessage {
                    Spacer()
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 12) {
                            ForEach(report.sections) { sectionView($0) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Reading video specs…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider().opacity(0.4)

            // Footer actions
            HStack(spacing: 10) {
                footerButton(icon: copied ? "checkmark" : "doc.on.doc", title: copied ? "Copied!" : "Copy All Info", action: copyToClipboard)
                    .disabled(report == nil || report?.errorMessage != nil)

                footerButton(icon: "folder", title: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                }

                Spacer()

                Button {
                    NSWorkspace.shared.open(sourceURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("Open in Player")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                    .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .frame(width: 520, height: 640)
        .background(LiquidWindowBackground(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onExitCommand(perform: onClose)
        .onAppear {
            startLoading()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            report = nil
            thumbnail = nil
            MemoryOptimizer.reclaimMemory()
        }
    }

    private func startLoading() {
        let url = sourceURL
        loadTask = Task.detached(priority: .userInitiated) {
            let rep = VideoMetadataReport.load(from: url)
            let thumb = Self.extractThumbnail(for: url)
            if Task.isCancelled { return }
            await MainActor.run {
                report = rep
                thumbnail = thumb
            }
        }
    }

    nonisolated private static func extractThumbnail(for url: URL) -> NSImage? {
        if let ffmpegPath = FFmpegDiscovery.resolvePath() {
            if let res = try? ProcessRunner.run(ffmpegPath, ["-nostdin", "-ss", "0.5", "-i", url.path, "-vframes", "1", "-f", "image2pipe", "-vcodec", "png", "-"]),
               res.status == 0,
               !res.stdout.isEmpty,
               let img = NSImage(data: res.stdout) {
                return img
            }
            if let res = try? ProcessRunner.run(ffmpegPath, ["-nostdin", "-ss", "0.0", "-i", url.path, "-vframes", "1", "-f", "image2pipe", "-vcodec", "png", "-"]),
               res.status == 0,
               !res.stdout.isEmpty,
               let img = NSImage(data: res.stdout) {
                return img
            }
        }
        // AVFoundation fallback
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func copyToClipboard() {
        guard let report else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report.fullTextSummary, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ImageMetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accent)
                Text(section.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            VStack(spacing: 4) {
                ForEach(section.items) { item in
                    HStack(alignment: .top) {
                        Text(item.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(item.value)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(item.label == "Location" ? 2 : 1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    if item.id != section.items.last?.id {
                        Divider().opacity(0.2)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        }
    }

    @ViewBuilder
    private func footerButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badge(text: String, isAccent: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(isAccent ? theme.accent.opacity(0.18) : Color.primary.opacity(0.08)))
            .foregroundColor(isAccent ? theme.accent : .primary)
    }
}

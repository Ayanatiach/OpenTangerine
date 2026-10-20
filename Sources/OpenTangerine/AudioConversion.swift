//
//  AudioConversion.swift
//  OpenTangerine
//
//  Audio Transcoding, Metadata (Title, Artist, Album) & Cover Icon Engine
//  Supports: AAC, AIFF, ALAC, AMR, FLAC, M4A, MP3, OGG, WAV, WMA
//  Integrates FFmpeg high-performance transcoding with Apple native AudioToolbox/afconvert fallback,
//  plus full technical metadata inspection, embedded album art tagging (VLC player compatible),
//  and macOS Finder custom file/folder icon updates.
//

import SwiftUI
import AppKit
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

// MARK: - Audio Format Model

public enum AudioFormat: String, CaseIterable, Identifiable, Sendable {
    case aac = "aac"
    case aiff = "aiff"
    case alac = "alac"
    case amr = "amr"
    case flac = "flac"
    case m4a = "m4a"
    case mp3 = "mp3"
    case ogg = "ogg"
    case wav = "wav"
    case wma = "wma"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .aac: return "AAC"
        case .aiff: return "AIFF"
        case .alac: return "ALAC"
        case .amr: return "AMR"
        case .flac: return "FLAC"
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        case .ogg: return "OGG"
        case .wav: return "WAV"
        case .wma: return "WMA"
        }
    }

    public var systemIcon: String {
        switch self {
        case .mp3, .m4a, .aac: return "music.note"
        case .flac, .alac: return "waveform.badge.magnifyingglass"
        case .wav, .aiff: return "waveform"
        case .ogg: return "antenna.radiowaves.left.and.right"
        case .amr: return "phone.bubble.left"
        case .wma: return "opticaldisc"
        }
    }

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff:
            return true
        default:
            return false
        }
    }

    public var isNativeSupported: Bool {
        switch self {
        case .aac, .aiff, .alac, .flac, .m4a, .wav:
            return true
        case .amr:
            return AMREncoder.isAvailable
        case .mp3, .ogg, .wma:
            return false
        }
    }

    public static func from(extension ext: String) -> AudioFormat? {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch normalized {
        case "aac": return .aac
        case "aiff", "aif", "aifc": return .aiff
        case "alac": return .alac
        case "amr", "awb": return .amr
        case "flac": return .flac
        case "m4a", "m4b", "m4r": return .m4a
        case "mp3", "mp2", "mpa": return .mp3
        case "ogg", "oga", "opus": return .ogg
        case "wav", "wave", "bwf": return .wav
        case "wma", "asf": return .wma
        default: return nil
        }
    }
}

// MARK: - AMR Encoder Bridge (opencore-amr)

public enum AMREncoder {
    private typealias InitFunc = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    private typealias EncodeFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafePointer<Int16>, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    private typealias ExitFunc = @convention(c) (UnsafeMutableRawPointer) -> Void

    public static var isAvailable: Bool {
        resolveDylib() != nil
    }

    public static func resolveDylib() -> String? {
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/Frameworks/libopencore-amrnb.dylib").path,
            bundle.appendingPathComponent("Contents/Resources/libopencore-amrnb.dylib").path,
            "/opt/homebrew/lib/libopencore-amrnb.dylib",
            "/usr/local/lib/libopencore-amrnb.dylib",
            "/opt/homebrew/lib/libopencore-amrnb.0.dylib",
            "/usr/local/lib/libopencore-amrnb.0.dylib",
            "libopencore-amrnb.dylib"
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Encodes raw 16-bit linear PCM at 8000 Hz mono to a standard AMR-NB container (.amr)
    public static func encodeRawPCM(pcmData: Data, to outputURL: URL) throws {
        guard let dylibPath = resolveDylib(),
              let handle = dlopen(dylibPath, RTLD_NOW) else {
            throw ConversionError.exportFailed(
                "AMR encoding requires libopencore-amrnb. Install it with: brew install opencore-amr"
            )
        }
        defer { dlclose(handle) }

        guard let initSym = dlsym(handle, "Encoder_Interface_init"),
              let encSym = dlsym(handle, "Encoder_Interface_Encode"),
              let exitSym = dlsym(handle, "Encoder_Interface_exit") else {
            throw ConversionError.exportFailed("AMR symbols missing in libopencore-amrnb")
        }

        let encoderInit = unsafeBitCast(initSym, to: InitFunc.self)
        let encoderEncode = unsafeBitCast(encSym, to: EncodeFunc.self)
        let encoderExit = unsafeBitCast(exitSym, to: ExitFunc.self)

        guard let state = encoderInit(0) else {
            throw ConversionError.exportFailed("Failed to initialize AMR encoder state")
        }
        defer { encoderExit(state) }

        var outputData = Data()
        // AMR file header magic: "#!AMR\n"
        let header: [UInt8] = [0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A]
        outputData.append(contentsOf: header)

        let sampleCount = pcmData.count / 2
        let frameSize = 160 // 160 samples per 20ms frame at 8000 Hz
        var frameBuffer = [UInt8](repeating: 0, count: 64)

        pcmData.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            var offset = 0
            while offset + frameSize <= sampleCount {
                let bytes = encoderEncode(state, 7 /* MR122 = 12.2 kbps highest quality */, samples + offset, &frameBuffer, 0)
                if bytes > 0 {
                    outputData.append(frameBuffer, count: Int(bytes))
                }
                offset += frameSize
            }
        }

        try outputData.write(to: outputURL, options: .atomic)
    }
}

// MARK: - Audio Conversion Engine

public final class AudioConversionEngine: @unchecked Sendable {
    public static let shared = AudioConversionEngine()

    public let supportedTargetExtensions: [String] = [
        "aac", "aiff", "alac", "amr", "flac", "m4a", "mp3", "ogg", "wav", "wma"
    ]

    public func canConvert(to targetExt: String) -> Bool {
        let ext = FileCategory.normalizedExtension(targetExt)
        return supportedTargetExtensions.contains(ext)
    }

    public func convertAudio(sourceURL: URL, destinationURL: URL, format: String) throws {
        let targetExt = FileCategory.normalizedExtension(format)

        guard canConvert(to: targetExt) else {
            throw ConversionError.unsupportedConversion(
                "\(sourceURL.pathExtension.uppercased()) → \(targetExt.uppercased()) is not supported"
            )
        }

        if let ffmpegPath = FFmpegDiscovery.resolvePath() {
            try convertWithFFmpeg(ffmpegPath: ffmpegPath, sourceURL: sourceURL, destinationURL: destinationURL, format: targetExt)
        } else {
            // No FFmpeg on machine: use native Apple afconvert fallback
            let nativeFormats = ["aac", "aiff", "alac", "flac", "m4a", "wav", "amr"]
            if nativeFormats.contains(targetExt) {
                try convertWithAfconvert(sourceURL: sourceURL, destinationURL: destinationURL, format: targetExt)
            } else {
                throw ConversionError.unsupportedConversion(
                    "Converting to \(targetExt.uppercased()) requires FFmpeg. Install it with: brew install ffmpeg"
                )
            }
        }

        // Verify destination file was created and is non-empty
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDir),
              !isDir.boolValue,
              (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            throw ConversionError.exportFailed("Audio conversion generated an empty or missing output file.")
        }

        // Reclaim RAM
        DispatchQueue.main.async {
            MemoryOptimizer.reclaimMemory()
        }
    }

    // MARK: - FFmpeg Transcoding

    private func convertWithFFmpeg(ffmpegPath: String, sourceURL: URL, destinationURL: URL, format: String) throws {
        // Special case: AMR
        if format == "amr" {
            try convertToAMRWithFFmpeg(ffmpegPath: ffmpegPath, sourceURL: sourceURL, destinationURL: destinationURL)
            return
        }

        var formatArgs: [String]
        switch format {
        case "aac":
            formatArgs = ["-vn", "-c:a", "aac", "-b:a", "256k"]

        case "aiff":
            formatArgs = ["-vn", "-c:a", "pcm_s16be"]

        case "alac":
            // ALAC in .alac or .m4a requires -f ipod or -f mp4 container muxer in FFmpeg
            formatArgs = ["-vn", "-c:a", "alac", "-f", "ipod"]

        case "flac":
            formatArgs = ["-vn", "-c:a", "flac", "-compression_level", "5"]

        case "m4a":
            formatArgs = ["-vn", "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]

        case "mp3":
            formatArgs = ["-vn", "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"]

        case "ogg":
            formatArgs = ["-vn", "-c:a", "libopus", "-b:a", "192k"]

        case "wav":
            formatArgs = ["-vn", "-c:a", "pcm_s16le"]

        case "wma":
            formatArgs = ["-vn", "-c:a", "wmav2", "-b:a", "192k"]

        default:
            throw ConversionError.unsupportedConversion("Audio format \(format) is unhandled")
        }

        let fullArgs = ["-y", "-nostdin", "-i", sourceURL.path] + formatArgs + [destinationURL.path]
        let result = try ProcessRunner.run(ffmpegPath, fullArgs)
        if result.status != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastLine = detail.components(separatedBy: .newlines).last ?? "Unknown error"
            throw ConversionError.exportFailed("FFmpeg audio conversion failed: \(lastLine)")
        }
    }

    private func convertToAMRWithFFmpeg(ffmpegPath: String, sourceURL: URL, destinationURL: URL) throws {
        // First try direct FFmpeg with libopencore_amrnb
        let testArgs = ["-y", "-nostdin", "-i", sourceURL.path, "-vn", "-ar", "8000", "-ac", "1", "-c:a", "libopencore_amrnb", destinationURL.path]
        if let res = try? ProcessRunner.run(ffmpegPath, testArgs), res.status == 0 {
            return
        }

        // Fallback: decode audio to raw 8000Hz 16-bit mono PCM via FFmpeg, then encode via AMREncoder
        let tempRawURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".raw")
        defer { try? FileManager.default.removeItem(at: tempRawURL) }

        let rawArgs = ["-y", "-nostdin", "-i", sourceURL.path, "-vn", "-ar", "8000", "-ac", "1", "-f", "s16le", tempRawURL.path]
        let rawRes = try ProcessRunner.run(ffmpegPath, rawArgs)
        guard rawRes.status == 0 else {
            throw ConversionError.exportFailed("Failed to decode audio to 8kHz PCM for AMR conversion.")
        }

        let pcmData = try Data(contentsOf: tempRawURL)
        try AMREncoder.encodeRawPCM(pcmData: pcmData, to: destinationURL)
    }

    // MARK: - Native Apple afconvert Fallback

    private func convertWithAfconvert(sourceURL: URL, destinationURL: URL, format: String) throws {
        let afconvert = "/usr/bin/afconvert"
        guard FileManager.default.isExecutableFile(atPath: afconvert) else {
            throw ConversionError.exportFailed("afconvert is not available on this Mac")
        }

        var args: [String]
        switch format {
        case "aac":
            args = ["-f", "adts", "-d", "aac", "-b", "256000", sourceURL.path, destinationURL.path]

        case "aiff":
            args = ["-f", "AIFF", "-d", "BEI16", sourceURL.path, destinationURL.path]

        case "alac":
            args = ["-f", "m4af", "-d", "alac", sourceURL.path, destinationURL.path]

        case "flac":
            args = ["-f", "flac", "-d", "flac", sourceURL.path, destinationURL.path]

        case "m4a":
            args = ["-f", "m4af", "-d", "aac", "-b", "256000", sourceURL.path, destinationURL.path]

        case "wav":
            args = ["-f", "WAVE", "-d", "LEI16", sourceURL.path, destinationURL.path]

        case "amr":
            if AMREncoder.isAvailable {
                let tempWav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                defer { try? FileManager.default.removeItem(at: tempWav) }
                _ = try? ProcessRunner.run(afconvert, ["-f", "WAVE", "-d", "LEI16@8000", "-c", "1", sourceURL.path, tempWav.path])
                if FileManager.default.fileExists(atPath: tempWav.path),
                   let pcm = try? Data(contentsOf: tempWav) {
                    // Skip 44 bytes WAV header
                    let raw = pcm.count > 44 ? pcm.subdata(in: 44..<pcm.count) : pcm
                    try AMREncoder.encodeRawPCM(pcmData: raw, to: destinationURL)
                    return
                }
            }
            throw ConversionError.unsupportedConversion("AMR conversion requires brew install opencore-amr or ffmpeg")

        default:
            throw ConversionError.unsupportedConversion("Conversion to \(format.uppercased()) requires FFmpeg.")
        }

        let res = try ProcessRunner.run(afconvert, args)
        if res.status != 0 {
            throw ConversionError.exportFailed("afconvert failed: \(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// MARK: - Audio Metadata Info Model

public struct AudioMetadataInfo: Identifiable, Sendable {
    public var id: String { filePath }

    public let filePath: String
    public let fileName: String
    public let isFolder: Bool
    public let trackCountInFolder: Int

    // Core Tags
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var composer: String
    public var genre: String
    public var year: String
    public var trackNumber: String
    public var comment: String

    // Technical specifications
    public let formatName: String
    public let codec: String
    public let bitrate: String
    public let sampleRate: String
    public let channels: String
    public let duration: TimeInterval
    public let durationFormatted: String
    public let fileSizeFormatted: String

    // Cover Artwork
    public var coverImage: NSImage?
    public var hasCustomFinderIcon: Bool
    public var coverDimensions: String?

    public init(
        filePath: String,
        fileName: String,
        isFolder: Bool = false,
        trackCountInFolder: Int = 0,
        title: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        composer: String = "",
        genre: String = "",
        year: String = "",
        trackNumber: String = "",
        comment: String = "",
        formatName: String = "",
        codec: String = "",
        bitrate: String = "",
        sampleRate: String = "",
        channels: String = "",
        duration: TimeInterval = 0,
        durationFormatted: String = "",
        fileSizeFormatted: String = "",
        coverImage: NSImage? = nil,
        hasCustomFinderIcon: Bool = false,
        coverDimensions: String? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.isFolder = isFolder
        self.trackCountInFolder = trackCountInFolder
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.comment = comment
        self.formatName = formatName
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = duration
        self.durationFormatted = durationFormatted
        self.fileSizeFormatted = fileSizeFormatted
        self.coverImage = coverImage
        self.hasCustomFinderIcon = hasCustomFinderIcon
        self.coverDimensions = coverDimensions
    }

    public var fullTextSummary: String {
        var lines: [String] = []
        lines.append("=== Audio Metadata Report ===")
        lines.append("File: \(fileName)")
        lines.append("Path: \(filePath)")
        if isFolder {
            lines.append("Type: Music Album Folder (\(trackCountInFolder) tracks)")
        } else {
            lines.append("Format: \(formatName.uppercased())")
            lines.append("Codec: \(codec)")
            lines.append("Duration: \(durationFormatted)")
            lines.append("Bitrate: \(bitrate)")
            lines.append("Sample Rate: \(sampleRate)")
            lines.append("Channels: \(channels)")
            lines.append("File Size: \(fileSizeFormatted)")
        }
        lines.append("")
        lines.append("--- Metadata Tags ---")
        if !title.isEmpty { lines.append("Title: \(title)") }
        if !artist.isEmpty { lines.append("Artist: \(artist)") }
        if !album.isEmpty { lines.append("Album: \(album)") }
        if !albumArtist.isEmpty { lines.append("Album Artist: \(albumArtist)") }
        if !composer.isEmpty { lines.append("Composer: \(composer)") }
        if !year.isEmpty { lines.append("Year: \(year)") }
        if !genre.isEmpty { lines.append("Genre: \(genre)") }
        if !trackNumber.isEmpty { lines.append("Track: \(trackNumber)") }
        if !comment.isEmpty { lines.append("Comment: \(comment)") }
        if let dim = coverDimensions { lines.append("Cover Art: \(dim)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Audio Metadata Service

public enum AudioMetadataService {

    /// Loads metadata, stream properties, and cover artwork for an audio file or music album folder.
    public static func loadMetadata(for url: URL) async -> AudioMetadataInfo {
        let isDir = FolderTools.isFolder(url)
        if isDir {
            return await loadFolderAlbumMetadata(for: url)
        } else {
            return await loadAudioFileMetadata(for: url)
        }
    }

    // MARK: - Audio File Inspection

    private static func loadAudioFileMetadata(for url: URL) async -> AudioMetadataInfo {
        let fileSizeStr = RadialMenuConfiguration.formattedFileSize(for: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        var title = ""
        var artist = ""
        var album = ""
        var albumArtist = ""
        var composer = ""
        var genre = ""
        var year = ""
        var trackNumber = ""
        var comment = ""

        var formatName = url.pathExtension.uppercased()
        var codec = url.pathExtension.uppercased()
        var bitrate = ""
        var sampleRate = ""
        var channels = ""
        var duration: TimeInterval = 0

        var coverImage: NSImage? = nil
        var coverDims: String? = nil

        // Try ffprobe JSON extraction
        if let probePath = FFmpegDiscovery.resolveProbePath(),
           let res = try? ProcessRunner.run(probePath, [
               "-v", "quiet",
               "-print_format", "json",
               "-show_format",
               "-show_streams",
               url.path
           ]),
           res.status == 0,
           let json = try? JSONSerialization.jsonObject(with: res.stdout) as? [String: Any] {

            if let formatDict = json["format"] as? [String: Any] {
                if let durStr = formatDict["duration"] as? String, let d = Double(durStr) {
                    duration = d
                }
                if let brStr = formatDict["bit_rate"] as? String, let br = Int(brStr) {
                    bitrate = "\(br / 1000) kbps"
                }
                if let fname = formatDict["format_name"] as? String {
                    formatName = fname.components(separatedBy: ",").first?.uppercased() ?? formatName
                }

                if let tags = formatDict["tags"] as? [String: Any] {
                    title = stringVal(tags, keys: ["title", "TITLE", "Title", "TIT2"]) ?? ""
                    artist = stringVal(tags, keys: ["artist", "ARTIST", "Artist", "TPE1", "author"]) ?? ""
                    album = stringVal(tags, keys: ["album", "ALBUM", "Album", "TALB"]) ?? ""
                    albumArtist = stringVal(tags, keys: ["album_artist", "ALBUM_ARTIST", "albumartist", "aART"]) ?? ""
                    composer = stringVal(tags, keys: ["composer", "COMPOSER", "Composer", "TCOM"]) ?? ""
                    genre = stringVal(tags, keys: ["genre", "GENRE", "Genre", "TCON"]) ?? ""
                    year = stringVal(tags, keys: ["date", "DATE", "year", "YEAR", "TYER", "TDRC"]) ?? ""
                    trackNumber = stringVal(tags, keys: ["track", "TRACK", "tracknumber", "TRCK"]) ?? ""
                    comment = stringVal(tags, keys: ["comment", "COMMENT", "description"]) ?? ""
                }
            }

            if let streams = json["streams"] as? [[String: Any]] {
                for stream in streams {
                    let type = stream["codec_type"] as? String ?? ""
                    if type == "audio" && codec == url.pathExtension.uppercased() {
                        codec = (stream["codec_name"] as? String)?.uppercased() ?? codec
                        if let sr = stream["sample_rate"] as? String, let srInt = Int(sr) {
                            sampleRate = String(format: "%.1f kHz", Double(srInt) / 1000.0)
                        }
                        if let ch = stream["channels"] as? Int {
                            let layout = stream["channel_layout"] as? String ?? (ch == 2 ? "stereo" : "mono")
                            channels = "\(ch) ch (\(layout))"
                        }
                        if bitrate.isEmpty, let brStr = stream["bit_rate"] as? String, let br = Int(brStr) {
                            bitrate = "\(br / 1000) kbps"
                        }
                    }
                }
            }
        }

        // Native AVFoundation fallback for tags / duration if ffprobe was absent
        if title.isEmpty && artist.isEmpty {
            let asset = AVURLAsset(url: url)
            if let items = try? await asset.load(.metadata) {
                for item in items {
                    guard let key = item.commonKey?.rawValue ?? item.keyString else { continue }
                    let strVal = (try? await item.load(.stringValue)) ?? ""
                    let val = strVal.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !val.isEmpty else { continue }

                    switch key.lowercased() {
                    case "title": title = val
                    case "artist", "author": artist = val
                    case "albumname", "album": album = val
                    case "type", "genre": genre = val
                    case "creationdate", "year", "date": year = val
                    default: break
                    }
                }
            }
            if duration == 0 {
                let cmTime = (try? await asset.load(.duration)) ?? .zero
                duration = cmTime.seconds.isFinite ? cmTime.seconds : 0
            }
        }

        // If title is still empty, use clean filename
        if title.isEmpty {
            title = fallbackTitle
        }

        // Extract Cover Artwork / Picture
        coverImage = extractArtwork(for: url)
        if let img = coverImage {
            coverDims = "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        }

        let durFormatted = formatDuration(duration)

        return AudioMetadataInfo(
            filePath: url.path,
            fileName: url.lastPathComponent,
            isFolder: false,
            trackCountInFolder: 0,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            composer: composer,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            comment: comment,
            formatName: formatName,
            codec: codec,
            bitrate: bitrate.isEmpty ? "Variable" : bitrate,
            sampleRate: sampleRate.isEmpty ? "44.1 kHz" : sampleRate,
            channels: channels.isEmpty ? "Stereo" : channels,
            duration: duration,
            durationFormatted: durFormatted,
            fileSizeFormatted: fileSizeStr,
            coverImage: coverImage,
            hasCustomFinderIcon: checkHasCustomIcon(at: url),
            coverDimensions: coverDims
        )
    }

    private static func listAudioFiles(in folderURL: URL) -> [URL] {
        let audioExts = Set(["mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff", "alac", "amr", "wma"])
        var audioTracks: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            while let next = enumerator.nextObject() as? URL {
                if audioExts.contains(next.pathExtension.lowercased()) {
                    audioTracks.append(next)
                }
            }
        }
        return audioTracks
    }

    // MARK: - Album Folder Inspection

    private static func loadFolderAlbumMetadata(for url: URL) async -> AudioMetadataInfo {
        let folderName = url.lastPathComponent
        let diskSizeStr = RadialMenuConfiguration.formattedFileSize(for: url)
        let audioTracks = listAudioFiles(in: url)

        var albumName = folderName
        var artistName = ""
        var genreName = ""
        var yearName = ""
        var coverImg: NSImage? = nil

        // Check for folder icon or cover.jpg / folder.jpg / albumart.jpg
        let imageCandidates = ["cover.jpg", "cover.png", "folder.jpg", "Folder.jpg", "front.jpg", "albumart.jpg"]
        for candidate in imageCandidates {
            let imgURL = url.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: imgURL.path),
               let img = NSImage(contentsOf: imgURL) {
                coverImg = img
                break
            }
        }

        // If no image on disk, check custom Finder icon or first track's embedded artwork
        if coverImg == nil {
            if let firstTrack = audioTracks.first {
                let firstInfo = await loadAudioFileMetadata(for: firstTrack)
                coverImg = firstInfo.coverImage
                if albumName == folderName && !firstInfo.album.isEmpty {
                    albumName = firstInfo.album
                }
                artistName = firstInfo.artist
                genreName = firstInfo.genre
                yearName = firstInfo.year
            }
        }

        if coverImg == nil {
            coverImg = NSWorkspace.shared.icon(forFile: url.path)
        }

        var dims: String? = nil
        if let img = coverImg {
            dims = "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        }

        return AudioMetadataInfo(
            filePath: url.path,
            fileName: folderName,
            isFolder: true,
            trackCountInFolder: audioTracks.count,
            title: folderName,
            artist: artistName,
            album: albumName,
            albumArtist: artistName,
            genre: genreName,
            year: yearName,
            formatName: "Music Album Folder",
            codec: "\(audioTracks.count) audio tracks",
            bitrate: "Multi-track",
            sampleRate: "Mixed",
            channels: "Folder",
            duration: 0,
            durationFormatted: "\(audioTracks.count) tracks",
            fileSizeFormatted: diskSizeStr,
            coverImage: coverImg,
            hasCustomFinderIcon: checkHasCustomIcon(at: url),
            coverDimensions: dims
        )
    }

    // MARK: - Save / Apply Metadata & Icon Updates

    public static func updateMetadataAndIcon(
        url: URL,
        newTitle: String,
        newArtist: String,
        newAlbum: String,
        newAlbumArtist: String,
        newYear: String,
        newGenre: String,
        newTrack: String,
        newComment: String,
        coverImage: NSImage?,
        updateFinderIcon: Bool,
        embedArtwork: Bool,
        applyToAllFolderTracks: Bool = false
    ) throws -> URL {
        let isDir = FolderTools.isFolder(url)

        if isDir {
            // Updating a Music Album Folder
            if let img = coverImage, updateFinderIcon {
                // Set Finder icon for the album folder
                _ = NSWorkspace.shared.setIcon(img, forFile: url.path, options: [])

                // Save cover.jpg inside the album folder for VLC and folder previews
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpgData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                    try? jpgData.write(to: url.appendingPathComponent("cover.jpg"), options: .atomic)
                }
            }

            if applyToAllFolderTracks {
                let tracks = listAudioFiles(in: url)
                for fileURL in tracks {
                    _ = try? updateSingleAudioFile(
                        fileURL: fileURL,
                        newTitle: nil, // keep individual track title
                        newArtist: newArtist.isEmpty ? nil : newArtist,
                        newAlbum: newAlbum.isEmpty ? nil : newAlbum,
                        newAlbumArtist: newAlbumArtist.isEmpty ? nil : newAlbumArtist,
                        newYear: newYear.isEmpty ? nil : newYear,
                        newGenre: newGenre.isEmpty ? nil : newGenre,
                        newTrack: nil,
                        newComment: nil,
                        coverImage: coverImage,
                        updateFinderIcon: updateFinderIcon,
                        embedArtwork: embedArtwork
                    )
                }
            }
            DispatchQueue.main.async {
                MemoryOptimizer.reclaimMemory()
            }
            return url
        } else {
            // Updating a single audio file
            let resultURL = try updateSingleAudioFile(
                fileURL: url,
                newTitle: newTitle,
                newArtist: newArtist,
                newAlbum: newAlbum,
                newAlbumArtist: newAlbumArtist,
                newYear: newYear,
                newGenre: newGenre,
                newTrack: newTrack,
                newComment: newComment,
                coverImage: coverImage,
                updateFinderIcon: updateFinderIcon,
                embedArtwork: embedArtwork
            )
            DispatchQueue.main.async {
                MemoryOptimizer.reclaimMemory()
            }
            return resultURL
        }
    }

    private static func updateSingleAudioFile(
        fileURL: URL,
        newTitle: String?,
        newArtist: String?,
        newAlbum: String?,
        newAlbumArtist: String?,
        newYear: String?,
        newGenre: String?,
        newTrack: String?,
        newComment: String?,
        coverImage: NSImage?,
        updateFinderIcon: Bool,
        embedArtwork: Bool
    ) throws -> URL {
        guard let ffmpegPath = FFmpegDiscovery.resolvePath() else {
            // If FFmpeg is not available, we can still set the custom Finder icon!
            if let img = coverImage, updateFinderIcon {
                _ = NSWorkspace.shared.setIcon(img, forFile: fileURL.path, options: [])
            }
            return fileURL
        }

        let parentDir = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension
        let tempOut = parentDir.appendingPathComponent(".tmp_tag_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        var tempCoverURL: URL? = nil
        defer {
            if let tempCoverURL { try? FileManager.default.removeItem(at: tempCoverURL) }
        }

        var ffmpegArgs = ["-y", "-nostdin", "-i", fileURL.path]

        // Prepare optimized cover picture (scaled to max 1024x1024 to save RAM and prevent file bloat)
        var hasValidCover = false
        if embedArtwork, let img = coverImage {
            let optimized = downsampleImage(img, maxPixelSize: 1024)
            if let pngData = imageToPNGData(optimized) {
                let coverPath = FileManager.default.temporaryDirectory.appendingPathComponent("cover_\(UUID().uuidString).png")
                if (try? pngData.write(to: coverPath)) != nil {
                    tempCoverURL = coverPath
                    hasValidCover = true
                    ffmpegArgs += ["-i", coverPath.path]
                }
            }
        }

        // Map streams: audio stream + optional attached picture
        let formatLower = ext.lowercased()
        let supportsAttachedPic = ["mp3", "m4a", "flac", "alac", "aiff"].contains(formatLower)

        if hasValidCover && supportsAttachedPic {
            ffmpegArgs += [
                "-map", "0:a",
                "-map", "1:0",
                "-c:a", "copy"
            ]
            if formatLower == "mp3" {
                ffmpegArgs += [
                    "-c:v", "copy",
                    "-id3v2_version", "3",
                    "-metadata:s:v", "title=Album cover",
                    "-metadata:s:v", "comment=Cover (front)",
                    "-disposition:v:0", "attached_pic"
                ]
            } else if formatLower == "flac" {
                ffmpegArgs += [
                    "-c:v", "png",
                    "-disposition:v:0", "attached_pic"
                ]
            } else if formatLower == "m4a" || formatLower == "alac" {
                ffmpegArgs += [
                    "-c:v", "png",
                    "-disposition:v:0", "attached_pic"
                ]
            } else {
                ffmpegArgs += [
                    "-c:v", "copy",
                    "-disposition:v:0", "attached_pic"
                ]
            }
        } else {
            // Keep original audio stream
            ffmpegArgs += ["-c:a", "copy"]
            if formatLower == "mp3" {
                ffmpegArgs += ["-id3v2_version", "3"]
            }
        }

        // Tag values: VLC reads "title", "artist", "album", "date", "genre", "track"
        if let title = newTitle, !title.isEmpty {
            ffmpegArgs += ["-metadata", "title=\(title)"]
        }
        if let artist = newArtist, !artist.isEmpty {
            ffmpegArgs += ["-metadata", "artist=\(artist)"]
        }
        if let album = newAlbum, !album.isEmpty {
            ffmpegArgs += ["-metadata", "album=\(album)"]
        }
        if let albumArtist = newAlbumArtist, !albumArtist.isEmpty {
            ffmpegArgs += ["-metadata", "album_artist=\(albumArtist)"]
        }
        if let year = newYear, !year.isEmpty {
            ffmpegArgs += ["-metadata", "date=\(year)"]
        }
        if let genre = newGenre, !genre.isEmpty {
            ffmpegArgs += ["-metadata", "genre=\(genre)"]
        }
        if let track = newTrack, !track.isEmpty {
            ffmpegArgs += ["-metadata", "track=\(track)"]
        }
        if let comment = newComment, !comment.isEmpty {
            ffmpegArgs += ["-metadata", "comment=\(comment)"]
        }

        ffmpegArgs.append(tempOut.path)

        let result = try ProcessRunner.run(ffmpegPath, ffmpegArgs)
        if result.status == 0 && FileManager.default.fileExists(atPath: tempOut.path) {
            // Atomically replace original file
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempOut)
        } else {
            // If tagging with artwork failed due to container limitations (e.g. wav/ogg), retry audio-only tagging
            if hasValidCover {
                var simpleArgs = ["-y", "-nostdin", "-i", fileURL.path, "-c:a", "copy"]
                if let title = newTitle, !title.isEmpty { simpleArgs += ["-metadata", "title=\(title)"] }
                if let artist = newArtist, !artist.isEmpty { simpleArgs += ["-metadata", "artist=\(artist)"] }
                if let album = newAlbum, !album.isEmpty { simpleArgs += ["-metadata", "album=\(album)"] }
                simpleArgs.append(tempOut.path)
                if let retryRes = try? ProcessRunner.run(ffmpegPath, simpleArgs), retryRes.status == 0 {
                    _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tempOut)
                }
            }
        }

        // Update macOS Finder Icon
        if updateFinderIcon {
            if let img = coverImage {
                _ = NSWorkspace.shared.setIcon(img, forFile: fileURL.path, options: [])
            } else {
                _ = NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
            }
        }

        return fileURL
    }

    // MARK: - Artwork Helpers

    public static func extractArtwork(for url: URL) -> NSImage? {
        // Method 1: Extract attached picture using FFmpeg image2pipe
        if let ffmpegPath = FFmpegDiscovery.resolvePath() {
            let args = ["-nostdin", "-i", url.path, "-an", "-vcodec", "png", "-f", "image2pipe", "-"]
            if let res = try? ProcessRunner.run(ffmpegPath, args),
               res.status == 0,
               !res.stdout.isEmpty,
               let img = NSImage(data: res.stdout) {
                return img
            }
        }

        // Method 2: AVFoundation metadata commonKeyArtwork
        let asset = AVURLAsset(url: url)
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                if item.commonKey == .commonKeyArtwork,
                   let data = item.value as? Data,
                   let img = NSImage(data: data) {
                    return img
                }
            }
        }

        // Method 3: Check custom Finder icon if set
        if let icon = getCustomFinderIcon(at: url) {
            return icon
        }

        return nil
    }

    public static func getCustomFinderIcon(at url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(forKeys: [.customIconKey]),
              let custom = values.customIcon else {
            return nil
        }
        return custom
    }

    public static func checkHasCustomIcon(at url: URL) -> Bool {
        getCustomFinderIcon(at: url) != nil
    }

    private static func downsampleImage(_ image: NSImage, maxPixelSize: CGFloat) -> NSImage {
        autoreleasepool {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                let maxDim = max(CGFloat(cg.width), CGFloat(cg.height))
                if maxDim <= maxPixelSize { return image }
                let scale = maxPixelSize / maxDim
                let newW = max(1, Int(CGFloat(cg.width) * scale))
                let newH = max(1, Int(CGFloat(cg.height) * scale))
                if let ctx = CGContext(
                    data: nil,
                    width: newW,
                    height: newH,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                    if let resized = ctx.makeImage() {
                        return NSImage(cgImage: resized, size: NSSize(width: newW, height: newH))
                    }
                }
            }
            guard let tiff = image.tiffRepresentation,
                  let source = CGImageSourceCreateWithData(tiff as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return image
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCache: false
            ]
            if let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            }
            return image
        }
    }

    private static func imageToPNGData(_ image: NSImage) -> Data? {
        autoreleasepool {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                let rep = NSBitmapImageRep(cgImage: cg)
                return rep.representation(using: .png, properties: [:])
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
    }

    private static func stringVal(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 && seconds.isFinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private extension AVMetadataItem {
    var keyString: String? {
        if let str = key as? String { return str }
        if let num = key as? NSNumber { return num.stringValue }
        return nil
    }
}

// MARK: - Audio Metadata & Icon Editor View

public struct AudioMetadataEditorView: View {
    public let sourceURL: URL
    public var onClose: () -> Void

    @State private var info: AudioMetadataInfo?
    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var albumArtist: String = ""
    @State private var year: String = ""
    @State private var genre: String = ""
    @State private var trackNumber: String = ""
    @State private var comment: String = ""

    @State private var coverImage: NSImage?
    @State private var isCropping: Bool = false
    @State private var updateFinderIcon: Bool = true
    @State private var embedArtwork: Bool = true
    @State private var applyToFolderTracks: Bool = true

    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false
    @State private var errorMessage: String?
    @State private var isTargetedForDrop: Bool = false

    @ObservedObject private var theme = ThemeManager.shared

    public init(sourceURL: URL, onClose: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            ZStack {
                Text(info?.isFolder == true ? "Music Album Icon & Metadata" : "Audio Metadata & Icon Editor")
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

            if let info {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {

                        // MARK: Cover Picture & Finder Icon Section
                        HStack(alignment: .top, spacing: 16) {
                            // Artwork preview box
                            ZStack {
                                if let img = coverImage {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 110, height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.accent.opacity(0.35), lineWidth: 1.5))
                                } else {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(width: 110, height: 110)
                                        .overlay(
                                            VStack(spacing: 6) {
                                                Image(systemName: info.isFolder ? "folder.fill" : "music.note")
                                                    .font(.system(size: 32))
                                                    .foregroundColor(.secondary)
                                                Text("Drop Image")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                        )
                                }

                                if isTargetedForDrop {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(theme.accent, lineWidth: 3)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.opacity(0.2)))
                                }
                            }
                            .frame(width: 110, height: 110)
                            .onDrop(of: [.fileURL, .image], isTargeted: $isTargetedForDrop) { providers in
                                handleDroppedImage(providers)
                            }

                            // Artwork actions & options
                            VStack(alignment: .leading, spacing: 8) {
                                Text(info.isFolder ? "Album Cover & Folder Icon" : "Cover Picture & Finder Icon")
                                    .font(.system(size: 13, weight: .semibold))

                                Text("Drop any image from your Mac or browse to replace the album art & icon.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 8) {
                                    Button(action: selectImageFromDisk) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "photo.badge.plus")
                                            Text("Choose Picture…")
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)

                                    if coverImage != nil {
                                        // Option beside Choose Picture to edit / crop the chosen picture
                                        Button(action: { isCropping = true }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "crop")
                                                Text("Edit / Crop")
                                            }
                                            .font(.system(size: 11, weight: .medium))
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.opacity(0.18)))
                                            .foregroundColor(theme.accent)
                                        }
                                        .buttonStyle(.plain)

                                        Button(action: { coverImage = nil }) {
                                            HStack(spacing: 3) {
                                                Image(systemName: "trash")
                                                Text("Remove")
                                            }
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.red.opacity(0.85))
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle(isOn: $updateFinderIcon) {
                                        Text("Set as macOS Finder icon")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .toggleStyle(.checkbox)

                                    if !info.isFolder {
                                        Toggle(isOn: $embedArtwork) {
                                            Text("Embed in audio file (shows in VLC Media Player)")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .toggleStyle(.checkbox)
                                    } else {
                                        Toggle(isOn: $applyToFolderTracks) {
                                            Text("Apply artwork & album to all \(info.trackCountInFolder) tracks inside")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                                .padding(.top, 2)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                        // MARK: Metadata Tags Form
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(theme.accent)
                                Text("TRACK & ALBUM METADATA")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("VLC Media Player Sync")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.accent)
                            }

                            VStack(spacing: 8) {
                                metadataField(
                                    label: info.isFolder ? "Album Name" : "Track Title (VLC Name)",
                                    icon: "music.note",
                                    placeholder: "Song or track name",
                                    text: $title,
                                    highlight: true
                                )

                                metadataField(
                                    label: "Artist",
                                    icon: "person.fill",
                                    placeholder: "Artist / Performer",
                                    text: $artist
                                )

                                metadataField(
                                    label: "Album",
                                    icon: "opticaldisc.fill",
                                    placeholder: "Album name",
                                    text: $album
                                )

                                HStack(spacing: 8) {
                                    metadataField(
                                        label: "Year / Date",
                                        icon: "calendar",
                                        placeholder: "e.g. 2026",
                                        text: $year
                                    )

                                    metadataField(
                                        label: "Genre",
                                        icon: "guitars.fill",
                                        placeholder: "e.g. Rock, Pop, Classical",
                                        text: $genre
                                    )
                                }

                                HStack(spacing: 8) {
                                    metadataField(
                                        label: "Track #",
                                        icon: "number",
                                        placeholder: "e.g. 1 or 1/12",
                                        text: $trackNumber
                                    )

                                    metadataField(
                                        label: "Album Artist",
                                        icon: "person.2.fill",
                                        placeholder: "Band or Primary Artist",
                                        text: $albumArtist
                                    )
                                }

                                metadataField(
                                    label: "Comments",
                                    icon: "bubble.left.fill",
                                    placeholder: "Notes or description",
                                    text: $comment
                                )
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                        // MARK: Technical Specifications Summary
                        if !info.isFolder {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(theme.accent)
                                    Text("TECHNICAL SPECS")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }

                                HStack(spacing: 6) {
                                    badge(text: info.formatName, isAccent: true)
                                    badge(text: info.codec, isAccent: false)
                                    badge(text: info.bitrate, isAccent: false)
                                    badge(text: info.sampleRate, isAccent: false)
                                    badge(text: info.channels, isAccent: false)
                                    badge(text: info.durationFormatted, isAccent: false)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            } else {
                Spacer()
                ProgressView().controlSize(.regular)
                Text("Inspecting audio tags…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                Spacer()
            }

            Divider().opacity(0.4)

            // Footer bar
            HStack(spacing: 10) {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Show in Finder")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button(action: {
                    NSWorkspace.shared.open(sourceURL)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        Text("Play in VLC / Music")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onClose) {
                    Text("Cancel")
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                Button(action: saveChanges) {
                    HStack(spacing: 5) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else if saveSuccess {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(saveSuccess ? "Saved!" : (isSaving ? "Saving…" : "Save & Update"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                    .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                }
                .buttonStyle(.plain)
                .disabled(isSaving || info == nil)
            }
            .padding(14)
        }
        .frame(width: 530, height: 650)
        .background(LiquidWindowBackground(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if isCropping, let img = coverImage {
                ImageCropModalView(
                    image: img,
                    onApply: { cropped in
                        self.coverImage = cropped
                        self.isCropping = false
                    },
                    onCancel: {
                        self.isCropping = false
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .onExitCommand(perform: onClose)
        .task {
            let loaded = await AudioMetadataService.loadMetadata(for: sourceURL)
            info = loaded
            title = loaded.title
            artist = loaded.artist
            album = loaded.album
            albumArtist = loaded.albumArtist
            year = loaded.year
            genre = loaded.genre
            trackNumber = loaded.trackNumber
            comment = loaded.comment
            coverImage = loaded.coverImage
        }
    }

    // MARK: - Save Action

    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                _ = try AudioMetadataService.updateMetadataAndIcon(
                    url: sourceURL,
                    newTitle: title,
                    newArtist: artist,
                    newAlbum: album,
                    newAlbumArtist: albumArtist,
                    newYear: year,
                    newGenre: genre,
                    newTrack: trackNumber,
                    newComment: comment,
                    coverImage: coverImage,
                    updateFinderIcon: updateFinderIcon,
                    embedArtwork: embedArtwork,
                    applyToAllFolderTracks: applyToFolderTracks
                )

                await MainActor.run {
                    isSaving = false
                    withAnimation { saveSuccess = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        onClose()
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Failed to update: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Dropped / Picked Images

    private func handleDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let img = FileIconService.loadDownsampledImage(from: data, maxPixelSize: 1200) {
                        DispatchQueue.main.async {
                            withAnimation { self.coverImage = img }
                        }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data,
                       let str = String(data: data, encoding: .utf8),
                       let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)),
                       let img = FileIconService.loadDownsampledImage(from: url, maxPixelSize: 1200) {
                        DispatchQueue.main.async {
                            withAnimation { self.coverImage = img }
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func selectImageFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff, .bmp]
        panel.prompt = "Choose Icon / Cover Art"

        if panel.runModal() == .OK, let url = panel.url,
           let img = FileIconService.loadDownsampledImage(from: url, maxPixelSize: 1200) {
            withAnimation {
                self.coverImage = img
            }
        }
    }

    // MARK: - UI Helpers

    @ViewBuilder
    private func metadataField(label: String, icon: String, placeholder: String, text: Binding<String>, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(highlight ? theme.accent : .secondary)
                Text(label)
                    .font(.system(size: 10, weight: highlight ? .bold : .medium))
                    .foregroundColor(highlight ? theme.accent : .secondary)
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(highlight ? theme.accent.opacity(0.5) : Color.clear, lineWidth: 1))
        }
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

// MARK: - Audio Technical Specs Inspector View

public struct AudioInspectorView: View {
    public let sourceURL: URL
    public var onClose: () -> Void
    public var onEditRequested: (() -> Void)?

    @State private var info: AudioMetadataInfo?
    @State private var copied: Bool = false

    @ObservedObject private var theme = ThemeManager.shared

    public init(sourceURL: URL, onClose: @escaping () -> Void, onEditRequested: (() -> Void)? = nil) {
        self.sourceURL = sourceURL
        self.onClose = onClose
        self.onEditRequested = onEditRequested
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            ZStack {
                Text("Audio Technical Inspector")
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

            // Summary Card
            HStack(spacing: 12) {
                if let cover = info?.coverImage {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 58, height: 58)
                        .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(info?.title.isEmpty == false ? (info?.title ?? sourceURL.lastPathComponent) : sourceURL.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let artist = info?.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        badge(text: info?.formatName ?? sourceURL.pathExtension.uppercased(), isAccent: true)
                        if let br = info?.bitrate, !br.isEmpty { badge(text: br, isAccent: false) }
                        if let dur = info?.durationFormatted, !dur.isEmpty { badge(text: dur, isAccent: false) }
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Spec Rows
            if let info {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 12) {
                        specSection(title: "Audio Stream Specs", icon: "waveform", items: [
                            ("Codec", info.codec),
                            ("Bitrate", info.bitrate),
                            ("Sample Rate", info.sampleRate),
                            ("Channels", info.channels),
                            ("Duration", info.durationFormatted),
                            ("File Size", info.fileSizeFormatted)
                        ])

                        specSection(title: "Track Tags (VLC Player)", icon: "tag.fill", items: [
                            ("Title", info.title),
                            ("Artist", info.artist.isEmpty ? "—" : info.artist),
                            ("Album", info.album.isEmpty ? "—" : info.album),
                            ("Year", info.year.isEmpty ? "—" : info.year),
                            ("Genre", info.genre.isEmpty ? "—" : info.genre),
                            ("Track #", info.trackNumber.isEmpty ? "—" : info.trackNumber),
                            ("Artwork", info.coverDimensions ?? (info.coverImage != nil ? "Embedded" : "None"))
                        ])
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            } else {
                Spacer()
                ProgressView().controlSize(.regular)
                Text("Reading audio specs…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                Spacer()
            }

            Divider().opacity(0.4)

            // Footer
            HStack(spacing: 10) {
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy Specs")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                if let onEdit = onEditRequested {
                    Button(action: onEdit) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit Metadata & Icon")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.opacity(0.18)))
                        .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button(action: {
                    NSWorkspace.shared.open(sourceURL)
                }) {
                    HStack(spacing: 4) {
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
        .frame(width: 520, height: 620)
        .background(LiquidWindowBackground(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onExitCommand(perform: onClose)
        .task {
            info = await AudioMetadataService.loadMetadata(for: sourceURL)
        }
    }

    private func copyToClipboard() {
        guard let info else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(info.fullTextSummary, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }

    @ViewBuilder
    private func specSection(title: String, icon: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            VStack(spacing: 4) {
                ForEach(items, id: \.0) { item in
                    HStack {
                        Text(item.0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(item.1)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    if item.0 != items.last?.0 {
                        Divider().opacity(0.2)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        }
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

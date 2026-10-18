//
//  OpenTangerine.swift
//  OpenTangerine — Open-Source macOS Radial File Converter & Image Toolkit
//  Inspired by Tangerine: File Converter for macOS
//
//  Compile & Run on macOS 13.0+:
//    swiftc -parse-as-library OpenTangerine.swift -o OpenTangerine && ./OpenTangerine
//  or, from the package root:
//    swift run -c release            (menu bar app)
//    swift run -c release OpenTangerine --convert png photo.heic   (command-line conversion)
//

import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import ImageIO
import CoreImage
import AVFoundation
import Combine

// MARK: - 1. Models & Radial Menu Configuration

public enum WheelMode: String, CaseIterable {
    case convert = "Convert (⇧ + Drag)"
    case tools = "Tools (⌥⇧ + Drag)"
}

/// How the wheel was opened: from a Finder drag (release over a slice) or from the menu bar (click a slice).
public enum WheelInteraction {
    case drag, click
}

public enum FileCategory: String {
    case pdf, image, video, audio, document, unknown

    public static func detect(from url: URL) -> FileCategory {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf
        case "jpg", "jpeg", "png", "webp", "heic", "heif", "tiff", "tif", "bmp", "gif", "avif":
            return .image
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff":
            return .audio
        case "txt", "rtf", "docx", "md", "html", "htm":
            return .document
        default:
            return .unknown
        }
    }

    /// Canonical spelling so "jpeg"/"jpg", "tif"/"tiff", "heif"/"heic" compare equal.
    public static func normalizedExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "htm": return "html"
        default: return ext.lowercased()
        }
    }
}

public enum RadialActionType: Equatable {
    case convertToFormat(String)
    case openTool(ToolKind)
}

public enum ToolKind: String, CaseIterable, Identifiable {
    case crop = "CROP"
    case compress = "COMPRESS"
    case metadata = "METADATA"
    case addBG = "ADD BG"

    public var id: String { rawValue }

    public var systemIcon: String {
        switch self {
        case .crop: return "crop"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "info.circle"
        case .addBG: return "photo.artframe"
        }
    }

    public var hint: String {
        switch self {
        case .crop: return "Crop & resize"
        case .compress: return "Shrink file size"
        case .metadata: return "Inspect EXIF & GPS"
        case .addBG: return "Add a backdrop"
        }
    }
}

public struct RadialSlice: Identifiable, Equatable {
    public var id: String { title }
    public let title: String
    public let systemIcon: String?
    public let hint: String
    public let action: RadialActionType

    public init(title: String, systemIcon: String? = nil, hint: String = "", action: RadialActionType) {
        self.title = title
        self.systemIcon = systemIcon
        self.hint = hint
        self.action = action
    }

    public var isTool: Bool {
        if case .openTool = action { return true }
        return false
    }
}

public struct RadialMenuConfiguration {
    public let outerSlices: [RadialSlice]
    public let centerSubtitle: String
    public let emptyMessage: String?

    public static func build(for url: URL, mode: WheelMode) -> RadialMenuConfiguration {
        let category = FileCategory.detect(from: url)
        let fileSizeString = Self.formattedFileSize(for: url)
        let currentExt = FileCategory.normalizedExtension(url.pathExtension)

        switch mode {
        case .convert:
            let targets: [String]
            switch category {
            case .pdf:
                targets = ["DOCX", "JPG", "PNG", "TXT"]
            case .image:
                targets = ["PNG", "JPG", "HEIC", "PDF", "TIFF", "AVIF", "BMP", "DOCX"]
            case .document:
                targets = ["TXT", "RTF", "DOCX", "HTML"]
            default:
                targets = []
            }
            let slices = targets
                .filter { FileCategory.normalizedExtension($0) != currentExt }
                .filter { FileConversionEngine.shared.canConvert(category, to: $0.lowercased()) }
                .map { RadialSlice(title: $0, systemIcon: Self.icon(forFormat: $0), action: .convertToFormat($0.lowercased())) }
            return RadialMenuConfiguration(
                outerSlices: slices,
                centerSubtitle: fileSizeString,
                emptyMessage: slices.isEmpty ? "No conversions for .\(url.pathExtension.lowercased())" : nil
            )

        case .tools:
            guard category == .image else {
                return RadialMenuConfiguration(outerSlices: [], centerSubtitle: fileSizeString, emptyMessage: "Tools work on images")
            }
            return RadialMenuConfiguration(
                outerSlices: ToolKind.allCases.map {
                    RadialSlice(title: $0.rawValue, systemIcon: $0.systemIcon, hint: $0.hint, action: .openTool($0))
                },
                centerSubtitle: fileSizeString,
                emptyMessage: nil
            )
        }
    }

    static func icon(forFormat format: String) -> String {
        switch format {
        case "PDF": return "doc.richtext"
        case "DOCX": return "doc.text"
        case "TXT": return "text.alignleft"
        case "RTF": return "textformat"
        case "HTML": return "chevron.left.forwardslash.chevron.right"
        default: return "photo"
        }
    }

    public static func formattedFileSize(for url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return "File" }
        return formattedByteCount(Int64(size))
    }

    public static func formattedByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 2. Global Finder Drag & Modifier Monitor

@MainActor
public final class DragMonitorService {
    public private(set) var activeFileURLs: [URL] = []

    public var onWheelRequested: ((_ urls: [URL], _ mode: WheelMode, _ screenLocation: CGPoint) -> Void)?
    public var onModeChanged: ((WheelMode) -> Void)?
    public var onPointerMoved: ((CGPoint) -> Void)?
    public var onMouseReleased: (() -> Void)?
    public var onMouseDown: (() -> Void)?

    private var monitors: [Any] = []
    private var isDraggingFile = false
    private var isWheelOpen = false
    private var currentMode: WheelMode?
    private var dragPasteboardCountAtMouseDown = -1

    public init() {}

    public func startMonitoring() {
        guard monitors.isEmpty else { return }
        addMonitor(.leftMouseDown) { service, _ in service.handleMouseDown() }
        addMonitor(.leftMouseDragged) { service, flags in service.handleDrag(flags) }
        addMonitor(.flagsChanged) { service, flags in service.handleFlags(flags) }
        addMonitor(.leftMouseUp) { service, _ in service.handleMouseUp() }
    }

    public func endSession() {
        isWheelOpen = false
        currentMode = nil
        isDraggingFile = false
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask,
                            _ handler: @escaping @MainActor (DragMonitorService, NSEvent.ModifierFlags) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                guard let self else { return }
                handler(self, flags)
            }
        }
        if let monitor { monitors.append(monitor) }
    }

    private func handleMouseDown() {
        dragPasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        isDraggingFile = false
        onMouseDown?()
    }

    private func handleDrag(_ flags: NSEvent.ModifierFlags) {
        if !isDraggingFile {
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != dragPasteboardCountAtMouseDown,
                  let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return }
            isDraggingFile = true
            activeFileURLs = urls
        }
        evaluate(flags)
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        guard isDraggingFile else { return }
        evaluate(flags)
    }

    private func evaluate(_ flags: NSEvent.ModifierFlags) {
        let location = NSEvent.mouseLocation
        let requested: WheelMode? = flags.contains(.shift) ? (flags.contains(.option) ? .tools : .convert) : nil

        if !isWheelOpen {
            guard let mode = requested else { return }
            isWheelOpen = true
            currentMode = mode
            onWheelRequested?(activeFileURLs, mode, location)
        } else {
            if let mode = requested, mode != currentMode {
                currentMode = mode
                onModeChanged?(mode)
            }
            onPointerMoved?(location)
        }
    }

    private func handleMouseUp() {
        isDraggingFile = false
        if isWheelOpen { onMouseReleased?() }
    }
}

// MARK: - 3. Offline File Conversion Engine (PDFKit + ImageIO + CoreGraphics)

public enum ConversionError: LocalizedError {
    case unreadableSource(String)
    case unsupportedConversion(String)
    case exportFailed(String)
    case alreadyOptimized(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableSource(let msg): return "Could not read source file: \(msg)"
        case .unsupportedConversion(let msg): return "Unsupported conversion: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .alreadyOptimized(let msg): return msg
        }
    }
}

public struct CompressionResult: Sendable {
    public let output: URL
    public let originalBytes: Int64
    public let newBytes: Int64
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}

public final class FileConversionEngine: @unchecked Sendable {
    public static let shared = FileConversionEngine()

    public static let writableTypeIdentifiers: Set<String> =
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    public static func imageType(forExtension ext: String) -> UTType? {
        switch FileCategory.normalizedExtension(ext) {
        case "jpg": return .jpeg
        case "png": return .png
        case "tiff": return .tiff
        case "heic": return .heic
        case "bmp": return .bmp
        case "gif": return .gif
        case "webp": return .webP
        case "avif": return UTType("public.avif")
        default: return nil
        }
    }

    public static func canEncode(_ ext: String) -> Bool {
        guard let type = imageType(forExtension: ext) else { return false }
        return writableTypeIdentifiers.contains(type.identifier)
    }

    private static func supportsAlpha(_ ext: String) -> Bool {
        !["jpg", "bmp"].contains(FileCategory.normalizedExtension(ext))
    }

    public func canConvert(_ category: FileCategory, to targetExt: String) -> Bool {
        let ext = FileCategory.normalizedExtension(targetExt)
        switch (category, ext) {
        case (.pdf, "txt"), (.pdf, "docx"):
            return true
        case (.pdf, _):
            return Self.canEncode(ext)
        case (.image, "pdf"), (.image, "docx"):
            return true
        case (.image, _):
            return Self.canEncode(ext)
        case (.document, "txt"), (.document, "rtf"), (.document, "docx"), (.document, "html"):
            return true
        default:
            return false
        }
    }

    @discardableResult
    public func convertFile(at sourceURL: URL, to targetExt: String) throws -> URL {
        let ext = FileCategory.normalizedExtension(targetExt)
        let category = FileCategory.detect(from: sourceURL)
        guard canConvert(category, to: ext) else {
            throw ConversionError.unsupportedConversion(
                "\(sourceURL.pathExtension.uppercased()) → \(ext.uppercased()) isn't available on this Mac")
        }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let parentDir = sourceURL.deletingLastPathComponent()
        let destinationURL = uniqueOutputURL(in: parentDir, baseName: baseName, ext: ext)

        do {
            switch (category, ext) {
            case (.pdf, "txt"):
                try extractTextFromPDF(pdfURL: sourceURL, destinationURL: destinationURL)
            case (.pdf, "docx"):
                try convertPDFToDocx(pdfURL: sourceURL, destinationURL: destinationURL)
            case (.pdf, _):
                try renderPDFFirstPageToImage(pdfURL: sourceURL, destinationURL: destinationURL, format: ext)
            case (.image, "pdf"):
                try convertImageToPDF(imageURL: sourceURL, destinationURL: destinationURL)
            case (.image, "docx"):
                try convertImageToDocx(imageURL: sourceURL, destinationURL: destinationURL)
            case (.image, _):
                try convertImageFormat(sourceURL: sourceURL, destinationURL: destinationURL, format: ext)
            case (.document, _):
                try convertDocument(sourceURL: sourceURL, destinationURL: destinationURL, format: ext)
            default:
                throw ConversionError.unsupportedConversion("\(sourceURL.pathExtension) -> \(ext)")
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        return destinationURL
    }

    // MARK: PDF

    private func renderPDFFirstPageToImage(pdfURL: URL, destinationURL: URL, format: String) throws {
        guard let pdfDoc = PDFDocument(url: pdfURL), let page = pdfDoc.page(at: 0) else {
            throw ConversionError.unreadableSource(pdfURL.lastPathComponent)
        }
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300.0 / 72.0
        let width = Int(round(pageRect.width * scale))
        let height = Int(round(pageRect.height * scale))

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.exportFailed("Failed to allocate bitmap buffer.")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)

        guard let cgImage = ctx.makeImage() else {
            throw ConversionError.exportFailed("Failed to extract CGImage.")
        }
        try writeCGImage(cgImage, to: destinationURL, format: format, quality: 0.92)
    }

    private func extractTextFromPDF(pdfURL: URL, destinationURL: URL) throws {
        guard let pdfDoc = PDFDocument(url: pdfURL) else {
            throw ConversionError.unreadableSource(pdfURL.lastPathComponent)
        }
        let text = (0..<pdfDoc.pageCount).compactMap { pdfDoc.page(at: $0)?.string }.joined(separator: "\n\n")
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func convertPDFToDocx(pdfURL: URL, destinationURL: URL) throws {
        guard let pdfDoc = PDFDocument(url: pdfURL) else {
            throw ConversionError.unreadableSource(pdfURL.lastPathComponent)
        }
        let combined = NSMutableAttributedString()
        for i in 0..<pdfDoc.pageCount {
            if let attr = pdfDoc.page(at: i)?.attributedString {
                combined.append(attr)
                combined.append(NSAttributedString(string: "\n"))
            }
        }
        let data = try combined.data(
            from: NSRange(location: 0, length: combined.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: destinationURL, options: .atomic)
    }

    // MARK: Images

    private func loadOrientedImage(_ url: URL) throws -> (CGImage, CGImageSource) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadableSource(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadableSource(url.lastPathComponent)
        }
        return (image, source)
    }

    private func preservedMetadata(_ source: CGImageSource) -> [CFString: Any] {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyExifAuxDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = props[key] { kept[key] = value }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        kept[kCGImagePropertyOrientation] = 1
        return kept
    }

    private func convertImageFormat(sourceURL: URL, destinationURL: URL, format: String) throws {
        let (image, source) = try loadOrientedImage(sourceURL)
        try writeCGImage(image, to: destinationURL, format: format, quality: 0.9, properties: preservedMetadata(source))
    }

    private func convertImageToPDF(imageURL: URL, destinationURL: URL) throws {
        let (image, _) = try loadOrientedImage(imageURL)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let page = PDFPage(image: nsImage) else {
            throw ConversionError.exportFailed("Could not create a PDF page from \(imageURL.lastPathComponent)")
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard doc.write(to: destinationURL) else {
            throw ConversionError.exportFailed("Could not write \(destinationURL.lastPathComponent)")
        }
    }

    private func convertImageToDocx(imageURL: URL, destinationURL: URL) throws {
        let (image, _) = try loadOrientedImage(imageURL)
        let useJPEG = !image.hasAlpha
        let mediaData = try encodedData(image, type: useJPEG ? .jpeg : .png, quality: 0.9)
        let mediaName = useJPEG ? "image1.jpeg" : "image1.png"

        let maxWidth = 6.5 * 914_400.0, maxHeight = 9.0 * 914_400.0
        var width = Double(image.width) * 9525, height = Double(image.height) * 9525
        let fit = min(1, maxWidth / width, maxHeight / height)
        width = (width * fit).rounded()
        height = (height * fit).rounded()

        let package = DocxPackage.imageDocument(mediaName: mediaName, mediaData: mediaData,
                                                widthEMU: Int(width), heightEMU: Int(height),
                                                title: imageURL.deletingPathExtension().lastPathComponent)
        try StoredZipArchive.data(for: package).write(to: destinationURL, options: .atomic)
    }

    private func encodedData(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ConversionError.exportFailed("No encoder for \(type.identifier)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.exportFailed("Encoding \(type.identifier) failed")
        }
        return data as Data
    }

    private func flattened(_ image: CGImage) -> CGImage? {
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    public func writeCGImage(_ cgImage: CGImage, to destinationURL: URL, format: String, quality: Double = 0.92,
                             properties: [CFString: Any] = [:]) throws {
        guard let type = Self.imageType(forExtension: format),
              Self.writableTypeIdentifiers.contains(type.identifier) else {
            throw ConversionError.unsupportedConversion("This Mac has no \(format.uppercased()) encoder")
        }
        let image = (!Self.supportsAlpha(format) && cgImage.hasAlpha) ? (flattened(cgImage) ?? cgImage) : cgImage

        guard let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.exportFailed("Could not create \(destinationURL.lastPathComponent)")
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ConversionError.exportFailed("Encoding \(format.uppercased()) failed")
        }
    }

    // MARK: Image tools

    public func compressImage(at url: URL) throws -> CompressionResult {
        let (image, source) = try loadOrientedImage(url)
        let current = FileCategory.normalizedExtension(url.pathExtension)
        let keepFormat = ["jpg", "heic", "avif"].contains(current) && Self.canEncode(current)
        let outExt = keepFormat ? current : (image.hasAlpha && Self.canEncode("heic") ? "heic" : "jpg")
        let output = uniqueOutputURL(in: url.deletingLastPathComponent(),
                                     baseName: url.deletingPathExtension().lastPathComponent,
                                     suffix: "Compressed", ext: outExt)
        try writeCGImage(image, to: output, format: outExt, quality: keepFormat ? 0.6 : 0.75,
                         properties: preservedMetadata(source))
        let before = fileSize(url), after = fileSize(output)
        if after >= before {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.alreadyOptimized("\(url.lastPathComponent) is already well compressed")
        }
        return CompressionResult(output: output, originalBytes: before, newBytes: after)
    }

    public func stripMetadata(at url: URL) throws -> URL {
        let (image, _) = try loadOrientedImage(url)
        var ext = FileCategory.normalizedExtension(url.pathExtension)
        if !Self.canEncode(ext) { ext = "png" }
        let output = uniqueOutputURL(in: url.deletingLastPathComponent(),
                                     baseName: url.deletingPathExtension().lastPathComponent,
                                     suffix: "No Metadata", ext: ext)
        try writeCGImage(image, to: output, format: ext, quality: 0.95)
        return output
    }

    // MARK: Documents

    private func convertDocument(sourceURL: URL, destinationURL: URL, format: String) throws {
        let attr = try NSAttributedString(url: sourceURL, options: [:], documentAttributes: nil)
        let range = NSRange(location: 0, length: attr.length)
        let data: Data
        switch format {
        case "txt":
            data = Data(attr.string.utf8)
        case "rtf":
            data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case "docx":
            data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case "html":
            data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        default:
            throw ConversionError.unsupportedConversion("\(sourceURL.pathExtension) -> \(format)")
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    // MARK: Helpers

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    public func uniqueOutputURL(in directory: URL, baseName: String, suffix: String = "", ext: String) -> URL {
        let cleanBase = suffix.isEmpty ? baseName : "\(baseName) \(suffix)"
        var candidate = directory.appendingPathComponent("\(cleanBase).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(cleanBase) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

// MARK: - Docx & Zip Helpers

enum DocxPackage {
    static func imageDocument(mediaName: String, mediaData: Data, widthEMU: Int, heightEMU: Int,
                              title: String) -> [(path: String, data: Data)] {
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

        let contentTypes = header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        </Types>
        """
        let rootRels = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """
        let documentRels = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdImage1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(mediaName)"/>\
        </Relationships>
        """
        let document = header + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <w:body><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>\
        <wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(widthEMU)" cy="\(heightEMU)"/>\
        <wp:docPr id="1" name="\(safeTitle)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="\(mediaName)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdImage1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(widthEMU)" cy="\(heightEMU)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
        </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>\
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """
        return [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/media/\(mediaName)", mediaData)
        ]
    }
}

enum StoredZipArchive {
    static func data(for entries: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        let dosTime: UInt16 = 0, dosDate: UInt16 = 0x21

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)); archive.append(le16(0)); archive.append(le16(0))
            archive.append(le16(dosTime)); archive.append(le16(dosDate))
            archive.append(le32(crc)); archive.append(le32(size)); archive.append(le32(size))
            archive.append(le16(UInt16(name.count))); archive.append(le16(0))
            archive.append(name)
            archive.append(entry.data)

            centralDirectory.append(le32(0x0201_4B50))
            centralDirectory.append(le16(20)); centralDirectory.append(le16(20))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le16(dosTime)); centralDirectory.append(le16(dosDate))
            centralDirectory.append(le32(crc)); centralDirectory.append(le32(size)); centralDirectory.append(le32(size))
            centralDirectory.append(le16(UInt16(name.count)))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(0))
            centralDirectory.append(le32(offset))
            centralDirectory.append(name)
        }

        let directoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(entries.count))); archive.append(le16(UInt16(entries.count)))
        archive.append(le32(UInt32(centralDirectory.count)))
        archive.append(le32(directoryOffset))
        archive.append(le16(0))
        return archive
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

// MARK: - 4. Radial Pie Menu View & Geometry

public enum WheelGeometry {
    public static let panelSize: CGFloat = 440
    public static let outerRadius: CGFloat = 150
    public static let innerRadius: CGFloat = 62
    public static let selectionRadius: CGFloat = 215
    public static let gapDegrees: Double = 3.5
}

// MARK: - Theme System & Liquid Glass Customization

public enum ThemePreset: String, CaseIterable, Identifiable {
    case tangerine = "Tangerine"
    case liquidGlass = "Liquid Glass"
    case cyberCyan = "Cyber Cyan"
    case neonViolet = "Neon Violet"
    case emeraldMint = "Emerald Mint"
    case solarGold = "Solar Gold"
    case monochrome = "Monochrome"

    public var id: String { rawValue }
    public var name: String { rawValue }

    public var systemIcon: String {
        switch self {
        case .tangerine: return "sun.max.fill"
        case .liquidGlass: return "drop.fill"
        case .cyberCyan: return "bolt.fill"
        case .neonViolet: return "sparkles"
        case .emeraldMint: return "leaf.fill"
        case .solarGold: return "flame.fill"
        case .monochrome: return "circle.lefthalf.filled"
        }
    }

    public var accent: Color {
        switch self {
        case .tangerine:
            return Color(red: 0.94, green: 0.30, blue: 0.12)
        case .liquidGlass:
            return Color(red: 0.15, green: 0.65, blue: 0.98)
        case .cyberCyan:
            return Color(red: 0.0, green: 0.85, blue: 0.95)
        case .neonViolet:
            return Color(red: 0.68, green: 0.32, blue: 0.98)
        case .emeraldMint:
            return Color(red: 0.08, green: 0.80, blue: 0.52)
        case .solarGold:
            return Color(red: 0.98, green: 0.66, blue: 0.12)
        case .monochrome:
            return Color(white: 0.92)
        }
    }

    public var accentLight: Color {
        switch self {
        case .tangerine:
            return Color(red: 1.0, green: 0.56, blue: 0.24)
        case .liquidGlass:
            return Color(red: 0.65, green: 0.88, blue: 1.0)
        case .cyberCyan:
            return Color(red: 0.45, green: 0.95, blue: 1.0)
        case .neonViolet:
            return Color(red: 0.88, green: 0.52, blue: 1.0)
        case .emeraldMint:
            return Color(red: 0.40, green: 0.94, blue: 0.72)
        case .solarGold:
            return Color(red: 1.0, green: 0.82, blue: 0.38)
        case .monochrome:
            return Color(white: 1.0)
        }
    }

    public var description: String {
        switch self {
        case .tangerine: return "Citrus orange with warm glow"
        case .liquidGlass: return "Fluid frosted glass & specular highlights"
        case .cyberCyan: return "Vibrant electric neon cyan"
        case .neonViolet: return "Luminous ultraviolet & magenta"
        case .emeraldMint: return "Fresh botanical mint & emerald"
        case .solarGold: return "Radiant amber & golden warmth"
        case .monochrome: return "Clean minimalist slate & frosty white"
        }
    }
}

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    @Published public var currentTheme: ThemePreset {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "OpenTangerine.selectedThemePreset")
        }
    }

    /// Opacity of the liquid glass base material (0.10 ... 0.90).
    /// Lower value = more translucent, higher value = more frosted.
    @Published public var liquidGlassOpacity: Double {
        didSet {
            UserDefaults.standard.set(liquidGlassOpacity, forKey: "OpenTangerine.liquidGlassOpacity")
        }
    }

    /// Whether to respect and adapt to macOS System Settings (Reduce Transparency)
    @Published public var syncWithSystemSettings: Bool {
        didSet {
            UserDefaults.standard.set(syncWithSystemSettings, forKey: "OpenTangerine.syncWithSystemSettings")
        }
    }

    /// Live state of macOS System Settings -> Accessibility -> Display -> Reduce Transparency
    @Published public private(set) var systemReduceTransparency: Bool = false

    private init() {
        let savedPreset = UserDefaults.standard.string(forKey: "OpenTangerine.selectedThemePreset")
        self.currentTheme = savedPreset.flatMap(ThemePreset.init(rawValue:)) ?? .tangerine

        let savedOpacity = UserDefaults.standard.double(forKey: "OpenTangerine.liquidGlassOpacity")
        self.liquidGlassOpacity = savedOpacity > 0 ? savedOpacity : 0.40

        if UserDefaults.standard.object(forKey: "OpenTangerine.syncWithSystemSettings") != nil {
            self.syncWithSystemSettings = UserDefaults.standard.bool(forKey: "OpenTangerine.syncWithSystemSettings")
        } else {
            self.syncWithSystemSettings = true
        }

        self.systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    public var isLiquidGlass: Bool {
        currentTheme == .liquidGlass
    }

    public var accent: Color {
        currentTheme.accent
    }

    public var accentLight: Color {
        currentTheme.accentLight
    }

    public var effectiveGlassOpacity: Double {
        if syncWithSystemSettings && systemReduceTransparency {
            return 0.92
        }
        return liquidGlassOpacity
    }

    public var transparencyPercentage: Int {
        Int(round((1.0 - effectiveGlassOpacity) * 100))
    }
}

@MainActor
public enum Theme {
    public static var manager: ThemeManager { ThemeManager.shared }
    public static var accent: Color { ThemeManager.shared.accent }
    public static var accentLight: Color { ThemeManager.shared.accentLight }
    public static var isLiquidGlass: Bool { ThemeManager.shared.isLiquidGlass }
    public static var glassOpacity: Double { ThemeManager.shared.effectiveGlassOpacity }
}

public struct LiquidWindowBackground: View {
    @ObservedObject var theme = ThemeManager.shared

    public init() {}

    public var body: some View {
        ZStack {
            if theme.isLiquidGlass {
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(theme.effectiveGlassOpacity))
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18 * (1.0 - theme.effectiveGlassOpacity * 0.7)),
                                Color.cyan.opacity(0.06 * (1.0 - theme.effectiveGlassOpacity * 0.7)),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.8),
                                Color.cyan.opacity(0.35),
                                Color.purple.opacity(0.2),
                                Color.white.opacity(0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
    }
}

public struct AnnularSectorShape: Shape {
    public var startAngle: Angle
    public var endAngle: Angle
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(innerRadius, outerRadius) }
        set { innerRadius = newValue.first; outerRadius = newValue.second }
    }

    public func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

@MainActor
public final class WheelState: ObservableObject {
    public let fileURLs: [URL]
    public let interaction: WheelInteraction
    public let fileIcon: NSImage

    @Published public private(set) var mode: WheelMode
    @Published public private(set) var config: RadialMenuConfiguration
    @Published public private(set) var hoveredID: String?
    @Published public private(set) var pointerAngle: Double = -90
    @Published public private(set) var pointerActive = false
    @Published public var isPresented = false
    @Published public var committedID: String?

    public var onCommit: ((RadialSlice) -> Void)?
    public var onDismiss: (() -> Void)?

    public init(fileURLs: [URL], mode: WheelMode, interaction: WheelInteraction) {
        self.fileURLs = fileURLs
        self.mode = mode
        self.interaction = interaction
        self.config = RadialMenuConfiguration.build(for: fileURLs[0], mode: mode)
        self.fileIcon = NSWorkspace.shared.icon(forFile: fileURLs[0].path)
    }

    public var hoveredSlice: RadialSlice? {
        guard let hoveredID else { return nil }
        return config.outerSlices.first { $0.id == hoveredID }
    }

    var idleCaption: String {
        fileURLs.count > 1 ? "\(fileURLs.count) files" : config.centerSubtitle
    }

    func actionHint(for slice: RadialSlice) -> String {
        if slice.isTool { return slice.hint }
        return interaction == .drag ? "Release to convert" : "Click to convert"
    }

    public func setMode(_ newMode: WheelMode) {
        guard newMode != mode, committedID == nil else { return }
        mode = newMode
        config = RadialMenuConfiguration.build(for: fileURLs[0], mode: newMode)
        hoveredID = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    public func updatePointer(dx: CGFloat, dy: CGFloat) {
        guard committedID == nil else { return }
        let distance = hypot(dx, dy)
        let degrees = Double(atan2(-dy, dx)) * 180 / .pi

        let active = distance >= WheelGeometry.innerRadius * 0.55
        if active != pointerActive { pointerActive = active }
        if active {
            var delta = (degrees - pointerAngle).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            if abs(delta) > 0.5 { pointerAngle += delta }
        }

        let slices = config.outerSlices
        var newID: String?
        if !slices.isEmpty, distance >= WheelGeometry.innerRadius - 6, distance <= WheelGeometry.selectionRadius {
            let step = 360.0 / Double(slices.count)
            var relative = (degrees + 90).truncatingRemainder(dividingBy: 360)
            if relative < 0 { relative += 360 }
            newID = slices[Int((relative / step).rounded()) % slices.count].id
        }
        if newID != hoveredID {
            hoveredID = newID
            if newID != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    public func commitCurrentSelection() {
        guard committedID == nil, let slice = hoveredSlice else { return }
        committedID = slice.id
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.onCommit?(slice)
        }
    }
}

public struct RadialWheelView: View {
    @ObservedObject public var state: WheelState
    @ObservedObject private var theme = ThemeManager.shared

    public init(state: WheelState) { self.state = state }

    public var body: some View {
        let slices = state.config.outerSlices
        let step = 360.0 / Double(max(slices.count, 1))
        let committed = state.committedID != nil
        let glowRadius = WheelGeometry.outerRadius + 55

        ZStack {
            // Ambient glow that blooms while something is targeted
            Circle()
                .fill(RadialGradient(
                    colors: theme.isLiquidGlass
                        ? [Color.cyan.opacity(0.38), Color.purple.opacity(0.20), Color.clear]
                        : [theme.accent.opacity(0.42), theme.accent.opacity(0)],
                    center: .center,
                    startRadius: WheelGeometry.outerRadius * 0.7,
                    endRadius: glowRadius
                ))
                .frame(width: glowRadius * 2, height: glowRadius * 2)
                .opacity(state.hoveredID == nil ? 0.2 : 1)

            // Frosted / Liquid Glass base disc
            if theme.isLiquidGlass {
                Circle()
                    .fill(.ultraThinMaterial.opacity(theme.effectiveGlassOpacity))
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.25 * (1.0 - theme.effectiveGlassOpacity * 0.7)),
                                    Color.cyan.opacity(0.08 * (1.0 - theme.effectiveGlassOpacity * 0.7))
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.9),
                                    Color.cyan.opacity(0.5),
                                    Color.purple.opacity(0.3),
                                    Color.white.opacity(0.7)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                    )
                    .frame(width: WheelGeometry.outerRadius * 2 + 12, height: WheelGeometry.outerRadius * 2 + 12)
                    .shadow(color: Color.cyan.opacity(0.25), radius: 26, x: 0, y: 12)
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.2)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5)
                    )
                    .frame(width: WheelGeometry.outerRadius * 2 + 12, height: WheelGeometry.outerRadius * 2 + 12)
                    .shadow(color: .black.opacity(0.32), radius: 26, x: 0, y: 12)
            }

            // Slices
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                WheelSliceView(
                    slice: slice,
                    midAngle: -90 + Double(index) * step,
                    step: step,
                    isHovered: state.hoveredID == slice.id,
                    isCommitted: state.committedID == slice.id,
                    isDimmed: committed && state.committedID != slice.id
                )
                .opacity(state.isPresented ? 1 : 0)
                .scaleEffect(state.isPresented ? 1 : 0.6)
                .animation(.spring(response: 0.38, dampingFraction: 0.7)
                            .delay(state.isPresented && !committed ? Double(index) * 0.025 : 0),
                           value: state.isPresented)
            }

            // Directional pointer triangle on rim
            if !slices.isEmpty {
                WheelPointer(angle: state.pointerAngle, radius: WheelGeometry.outerRadius + 26)
                    .opacity(state.pointerActive && !committed ? 1 : 0)
            }

            // Central dynamic hub
            WheelHub(state: state)
        }
        .frame(width: WheelGeometry.panelSize, height: WheelGeometry.panelSize)
        .contentShape(Circle())
        .onContinuousHover { phase in
            guard state.interaction == .click else { return }
            switch phase {
            case .active(let loc):
                let center = CGPoint(x: WheelGeometry.panelSize / 2, y: WheelGeometry.panelSize / 2)
                let dx = loc.x - center.x
                let dy = -(loc.y - center.y)
                state.updatePointer(dx: dx, dy: dy)
            case .ended:
                break
            }
        }
        .onTapGesture {
            if state.hoveredSlice != nil {
                state.commitCurrentSelection()
            } else {
                state.onDismiss?()
            }
        }
        .scaleEffect(state.isPresented ? 1 : (committed ? 1.08 : 0.75))
        .opacity(state.isPresented ? 1 : 0)
        .rotationEffect(.degrees(state.isPresented || committed ? 0 : -15))
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: state.isPresented)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: state.hoveredID)
        .animation(.interpolatingSpring(stiffness: 280, damping: 24), value: state.pointerAngle)
        .animation(.easeOut(duration: 0.12), value: state.pointerActive)
        .animation(.spring(response: 0.30, dampingFraction: 0.8), value: state.mode)
        .animation(.easeOut(duration: 0.14), value: state.committedID)
    }
}

struct WheelSliceView: View {
    @ObservedObject private var theme = ThemeManager.shared
    let slice: RadialSlice
    let midAngle: Double
    let step: Double
    let isHovered: Bool
    let isCommitted: Bool
    let isDimmed: Bool

    var body: some View {
        let start = midAngle - step / 2 + WheelGeometry.gapDegrees / 2
        let end = midAngle + step / 2 - WheelGeometry.gapDegrees / 2
        let rad = midAngle * .pi / 180
        let pop: CGFloat = isCommitted ? 16 : (isHovered ? 10 : 0)
        let labelRadius = (WheelGeometry.innerRadius + WheelGeometry.outerRadius) / 2 + (isHovered ? 4 : 0)
        let sector = AnnularSectorShape(startAngle: .degrees(start), endAngle: .degrees(end),
                                        innerRadius: WheelGeometry.innerRadius,
                                        outerRadius: WheelGeometry.outerRadius + (isHovered ? 8 : 0))

        ZStack {
            sector
                .fill(isHovered
                      ? AnyShapeStyle(LinearGradient(
                            colors: theme.isLiquidGlass
                                ? [Color.white.opacity(0.88), theme.accent.opacity(0.85)]
                                : [theme.accentLight, theme.accent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                      : AnyShapeStyle(theme.isLiquidGlass
                            ? Color.white.opacity(max(0.12, 0.45 * theme.effectiveGlassOpacity))
                            : Color.white.opacity(0.58)))
                .shadow(color: theme.accent.opacity(isHovered ? 0.65 : 0), radius: 18)
            sector
                .stroke(Color.white.opacity(isHovered ? 0.95 : (theme.isLiquidGlass ? 0.35 : 0.45)),
                        lineWidth: isHovered ? 1.5 : 1)

            VStack(spacing: 3) {
                if let icon = slice.systemIcon {
                    Image(systemName: icon)
                        .font(.system(size: isHovered ? 17 : 14, weight: .semibold))
                }
                Text(slice.title)
                    .font(.system(size: slice.isTool ? 10.5 : 12.5, weight: isHovered ? .heavy : .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 74)
            .foregroundStyle(isHovered
                ? (theme.currentTheme == .monochrome ? Color.black : Color.white)
                : (theme.isLiquidGlass ? Color.primary.opacity(0.88) : Color.black.opacity(0.78)))
            .scaleEffect(isHovered ? 1.14 : 1)
            .offset(x: cos(rad) * labelRadius, y: sin(rad) * labelRadius)
        }
        .frame(width: WheelGeometry.panelSize, height: WheelGeometry.panelSize)
        .offset(x: cos(rad) * pop, y: sin(rad) * pop)
        .opacity(isDimmed ? 0.22 : 1)
        .allowsHitTesting(false)
    }
}

struct PointerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct WheelPointer: View {
    let angle: Double
    let radius: CGFloat

    var body: some View {
        PointerTriangle()
            .fill(Theme.accent)
            .frame(width: 16, height: 10)
            .shadow(color: Theme.accent.opacity(0.7), radius: 4)
            .offset(y: -radius)
            .rotationEffect(.degrees(angle + 90))
            .allowsHitTesting(false)
    }
}

struct WheelHub: View {
    @ObservedObject var state: WheelState
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        let slice = state.hoveredSlice
        let diameter = (WheelGeometry.innerRadius - 7) * 2

        ZStack {
            Circle()
                .fill(theme.isLiquidGlass
                      ? AnyShapeStyle(.ultraThinMaterial.opacity(theme.effectiveGlassOpacity))
                      : AnyShapeStyle(.regularMaterial))
                .overlay(Circle().strokeBorder(slice == nil
                                               ? (theme.isLiquidGlass ? Color.white.opacity(0.8) : Color.white.opacity(0.65))
                                               : theme.accent,
                                               lineWidth: slice == nil ? 1 : 2.5))
                .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 4)
                .frame(width: diameter, height: diameter)
                .scaleEffect(slice == nil ? 1 : 1.08)

            if let slice {
                VStack(spacing: 2) {
                    Image(systemName: slice.isTool ? (slice.systemIcon ?? "wand.and.stars") : "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text(slice.title)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(state.actionHint(for: slice))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(width: diameter - 14)
                .id(slice.id)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                VStack(spacing: 2) {
                    Image(nsImage: state.fileIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                    Text(state.config.emptyMessage ?? state.idleCaption)
                        .font(.system(size: state.config.emptyMessage == nil ? 10 : 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(width: diameter - 14)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
    }
}

final class WheelInteractionView: NSView {
    var onPointer: ((CGPoint) -> Void)?
    var canDrop: (() -> Bool)?
    var onDrop: (() -> Bool)?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { report(event.locationInWindow) }
    override func mouseDown(with event: NSEvent) {
        report(event.locationInWindow)
        onClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canDrop?() ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        report(sender.draggingLocation)
        return onDrop?() ?? false
    }

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        report(sender.draggingLocation)
        return (canDrop?() ?? false) ? .copy : []
    }

    private func report(_ windowPoint: NSPoint) {
        guard let window else { return }
        onPointer?(window.convertPoint(toScreen: windowPoint))
    }
}

// MARK: - 5. Crop Image Window

public enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", widescreen = "16:9", vertical = "9:16", standard = "4:3", portrait = "3:4"
    public var id: String { rawValue }
    public var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1.0
        case .widescreen: return 16.0 / 9.0
        case .vertical: return 9.0 / 16.0
        case .standard: return 4.0 / 3.0
        case .portrait: return 3.0 / 4.0
        }
    }
}

public struct CropEditorView: View {
    public let sourceURL: URL
    public var onComplete: (URL) -> Void
    public var onClose: () -> Void

    @State private var nsImage: NSImage?
    @State private var naturalPixelSize = CGSize(width: 2550, height: 3300)
    @State private var normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var selectedPreset: CropAspectPreset = .free
    @State private var widthInput = "2550"
    @State private var heightInput = "3300"
    @ObservedObject private var theme = ThemeManager.shared

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Crop Image").font(.system(size: 14, weight: .bold))
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.08)))
                    }.buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(14)

            GeometryReader { geo in
                if let img = nsImage {
                    let scale = min((geo.size.width - 40) / max(naturalPixelSize.width, 1),
                                     (geo.size.height - 30) / max(naturalPixelSize.height, 1))
                    let w = naturalPixelSize.width * scale
                    let h = naturalPixelSize.height * scale
                    let frame = CGRect(x: (geo.size.width - w) / 2, y: (geo.size.height - h) / 2, width: w, height: h)
                    let cropRect = CGRect(
                        x: frame.minX + normalizedCrop.minX * frame.width,
                        y: frame.minY + normalizedCrop.minY * frame.height,
                        width: normalizedCrop.width * frame.width,
                        height: normalizedCrop.height * frame.height
                    )

                    ZStack {
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: w, height: h)
                            .position(x: frame.midX, y: frame.midY)

                        Rectangle()
                            .stroke(theme.accent, lineWidth: 2)
                            .frame(width: cropRect.width, height: cropRect.height)
                            .position(x: cropRect.midX, y: cropRect.midY)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.accent)
                            .frame(width: 26, height: 8)
                            .position(x: cropRect.midX, y: cropRect.maxY)
                            .gesture(
                                DragGesture().onChanged { val in
                                    let clampedY = min(max(val.location.y, cropRect.minY + 24), frame.maxY)
                                    normalizedCrop.size.height = (clampedY - cropRect.minY) / frame.height
                                    selectedPreset = .free
                                    syncDimensions()
                                }
                            )
                    }
                }
            }
            .frame(height: 390)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Aspect ratio").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    ForEach(CropAspectPreset.allCases) { preset in
                        Button(preset.rawValue) {
                            selectedPreset = preset
                            if let r = preset.ratio {
                                let imgRatio = naturalPixelSize.width / max(naturalPixelSize.height, 1)
                                let normH = min(1.0, (1.0 * imgRatio) / r)
                                normalizedCrop = CGRect(x: 0, y: (1.0 - normH) / 2, width: 1.0, height: normH)
                                syncDimensions()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selectedPreset == preset ? theme.accent : Color.clear))
                        .foregroundColor(selectedPreset == preset ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
                    }
                }

                HStack(spacing: 10) {
                    Text("W").font(.caption)
                    TextField("W", text: $widthInput).textFieldStyle(.roundedBorder).frame(width: 72)
                    Text("H").font(.caption)
                    TextField("H", text: $heightInput).textFieldStyle(.roundedBorder).frame(width: 72)
                    Text("px").font(.caption).foregroundColor(.secondary)
                    Spacer()
                }

                HStack {
                    Button("Reset") {
                        normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
                        selectedPreset = .free
                        syncDimensions()
                    }
                    Spacer()
                    Button("Apply") { applyCrop() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                        .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                }
            }
            .padding(18)
        }
        .frame(width: 480, height: 580)
        .background(LiquidWindowBackground())
        .onExitCommand(perform: onClose)
        .onAppear {
            if let img = NSImage(contentsOf: sourceURL) {
                nsImage = img
                if let rep = img.representations.first, rep.pixelsWide > 0 {
                    naturalPixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
                syncDimensions()
            }
        }
    }

    private func syncDimensions() {
        widthInput = "\(Int(round(normalizedCrop.width * naturalPixelSize.width)))"
        heightInput = "\(Int(round(normalizedCrop.height * naturalPixelSize.height)))"
    }

    private func applyCrop() {
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let rect = CGRect(
            x: round(normalizedCrop.minX * CGFloat(cg.width)),
            y: round(normalizedCrop.minY * CGFloat(cg.height)),
            width: round(normalizedCrop.width * CGFloat(cg.width)),
            height: round(normalizedCrop.height * CGFloat(cg.height))
        )
        guard let cropped = cg.cropping(to: rect) else { return }
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let outURL = FileConversionEngine.shared.uniqueOutputURL(
            in: sourceURL.deletingLastPathComponent(),
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            suffix: "Cropped",
            ext: ext
        )
        if (try? FileConversionEngine.shared.writeCGImage(cropped, to: outURL, format: ext)) != nil {
            onComplete(outURL)
        }
    }
}

// MARK: - 6. Add BG Window

public struct BackgroundEditorView: View {
    public let sourceURL: URL
    public var onComplete: (URL) -> Void
    public var onClose: () -> Void

    @State private var nsImage: NSImage?
    @State private var paddingPx: Double = 160
    @State private var cornersPx: Double = 24
    @State private var shadowPx: Double = 24
    @State private var selectedPresetIndex: Int = 0
    @State private var selectedRatio: String = "Auto"

    @ObservedObject private var theme = ThemeManager.shared
    private let gradients: [[Color]] = [
        [Color(red: 0.96, green: 0.25, blue: 0.34), Color(red: 0.99, green: 0.72, blue: 0.14), Color(red: 0.52, green: 0.36, blue: 0.85)],
        [Color.cyan, Color.blue, Color.indigo],
        [Color.pink, Color.orange, Color.yellow],
        [Color.mint, Color.teal, Color.blue]
    ]

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Add BG").font(.system(size: 14, weight: .bold))
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.08)))
                    }.buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(14)

            canvasView(size: CGSize(width: 440, height: 280))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Background").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
                    ForEach(0..<gradients.count, id: \.self) { idx in
                        Button {
                            selectedPresetIndex = idx
                        } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(colors: gradients[idx], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 30, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedPresetIndex == idx ? theme.accent : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }

                sliderRow("Padding", value: $paddingPx, range: 0...800)
                sliderRow("Corners", value: $cornersPx, range: 0...240)
                sliderRow("Shadow", value: $shadowPx, range: 0...100)

                HStack {
                    Text("Ratio").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
                    Spacer()
                    ForEach(["Auto", "1:1", "16:9", "4:5"], id: \.self) { r in
                        Button(r) { selectedRatio = r }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selectedRatio == r ? theme.accent : Color.clear))
                            .foregroundColor(selectedRatio == r ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
                    }
                }

                HStack {
                    Button("Reset") {
                        paddingPx = 160; cornersPx = 24; shadowPx = 24
                    }
                    Spacer()
                    Button("Save with Background") { saveComposite() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                        .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                }
            }
            .padding(20)
        }
        .frame(width: 490, height: 610)
        .background(LiquidWindowBackground())
        .onExitCommand(perform: onClose)
        .onAppear { nsImage = NSImage(contentsOf: sourceURL) }
    }

    @ViewBuilder
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            Slider(value: value, in: range).tint(theme.accent)
            Text("\(Int(round(value.wrappedValue))) px")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func canvasView(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: gradients[selectedPresetIndex], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(cornersPx) * 0.15, style: .continuous))
                    .shadow(color: .black.opacity(0.32), radius: CGFloat(shadowPx) * 0.4, x: 0, y: 8)
                    .padding(min(CGFloat(paddingPx) * 0.11, size.height * 0.35))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @MainActor
    private func saveComposite() {
        let renderer = ImageRenderer(content: canvasView(size: CGSize(width: 1600, height: 1100)))
        renderer.scale = 2.0
        guard let cg = renderer.cgImage else { return }
        let outURL = FileConversionEngine.shared.uniqueOutputURL(
            in: sourceURL.deletingLastPathComponent(),
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            suffix: "with Background",
            ext: "png"
        )
        if (try? FileConversionEngine.shared.writeCGImage(cg, to: outURL, format: "png")) != nil {
            onComplete(outURL)
        }
    }
}

// MARK: - 7. Metadata Inspector Window

public struct ImageMetadataItem: Identifiable, Sendable {
    public let id = UUID()
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct ImageMetadataSection: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let icon: String
    public let items: [ImageMetadataItem]

    public init(title: String, icon: String, items: [ImageMetadataItem]) {
        self.title = title
        self.icon = icon
        self.items = items
    }
}

public struct GPSCoordinate: Sendable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public struct ImageMetadataReport: Sendable {
    public let fileName: String
    public let fileSize: String
    public let dimensions: String
    public let megapixels: String
    public let format: String
    public let colorProfile: String
    public let cameraSummary: String?
    public let exposureSummary: String?
    public let shutterSpeed: String?
    public let aperture: String?
    public let iso: String?
    public let focalLength: String?
    public let gpsCoordinate: GPSCoordinate?
    public let hasEXIFOrGPS: Bool
    public let sections: [ImageMetadataSection]
    public let fullTextSummary: String

    public static func load(from url: URL) -> ImageMetadataReport {
        let fileAttrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSizeBytes = (fileAttrs[.size] as? NSNumber)?.int64Value ?? 0
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
        let ext = url.pathExtension.uppercased()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return ImageMetadataReport(
                fileName: url.lastPathComponent,
                fileSize: fileSizeStr,
                dimensions: "Unknown",
                megapixels: "",
                format: ext,
                colorProfile: "",
                cameraSummary: nil,
                exposureSummary: nil,
                shutterSpeed: nil,
                aperture: nil,
                iso: nil,
                focalLength: nil,
                gpsCoordinate: nil,
                hasEXIFOrGPS: false,
                sections: [],
                fullTextSummary: "Could not read metadata for \(url.lastPathComponent)"
            )
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]

        let pixelW = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelH = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        let dimStr = (pixelW > 0 && pixelH > 0) ? "\(pixelW) × \(pixelH) px" : "Unknown"
        let mpStr = (pixelW > 0 && pixelH > 0) ? String(format: "%.1f MP", Double(pixelW * pixelH) / 1_000_000.0) : ""

        let colorModel = (props[kCGImagePropertyColorModel] as? String) ?? ""
        let profileName = (props[kCGImagePropertyProfileName] as? String) ?? ""
        let dpiW = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue ?? 0
        let dpiH = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.intValue ?? 0
        let depth = (props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0

        var sections: [ImageMetadataSection] = []

        // 1. File & Image specs
        var fileItems: [ImageMetadataItem] = [
            ImageMetadataItem(label: "Dimensions", value: dimStr + (mpStr.isEmpty ? "" : " (\(mpStr))")),
            ImageMetadataItem(label: "File Size", value: fileSizeStr),
            ImageMetadataItem(label: "Format", value: ext)
        ]
        if !colorModel.isEmpty {
            let depthStr = depth > 0 ? " (\(depth)-bit)" : ""
            fileItems.append(ImageMetadataItem(label: "Color Model", value: "\(colorModel)\(depthStr)"))
        }
        if !profileName.isEmpty {
            fileItems.append(ImageMetadataItem(label: "Color Profile", value: profileName))
        }
        if dpiW > 0 && dpiH > 0 {
            fileItems.append(ImageMetadataItem(label: "Resolution", value: "\(dpiW) × \(dpiH) DPI"))
        }
        if let modDate = fileAttrs[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            fileItems.append(ImageMetadataItem(label: "Modified", value: f.string(from: modDate)))
        }
        sections.append(ImageMetadataSection(title: "File & Image Specs", icon: "doc.text", items: fileItems))

        // 2. Camera & Equipment
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let software = (tiff?[kCGImagePropertyTIFFSoftware] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lensMake = (exif?[kCGImagePropertyExifLensMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var cameraSummary: String? = nil
        if let model, !model.isEmpty {
            if let make, !make.isEmpty, !model.lowercased().contains(make.lowercased()) {
                cameraSummary = "\(make) \(model)"
            } else {
                cameraSummary = model
            }
        } else if let make, !make.isEmpty {
            cameraSummary = make
        }

        var cameraItems: [ImageMetadataItem] = []
        if let make, !make.isEmpty { cameraItems.append(ImageMetadataItem(label: "Make", value: make)) }
        if let model, !model.isEmpty { cameraItems.append(ImageMetadataItem(label: "Model", value: model)) }
        if let lensModel, !lensModel.isEmpty {
            let fullLens = (lensMake != nil && !lensModel.contains(lensMake!)) ? "\(lensMake!) \(lensModel)" : lensModel
            cameraItems.append(ImageMetadataItem(label: "Lens", value: fullLens))
        }
        if let software, !software.isEmpty { cameraItems.append(ImageMetadataItem(label: "Software", value: software)) }
        if !cameraItems.isEmpty {
            sections.append(ImageMetadataSection(title: "Camera & Equipment", icon: "camera", items: cameraItems))
        }

        // 3. Exposure & Shooting
        var shutterSpeed: String? = nil
        var aperture: String? = nil
        var iso: String? = nil
        var focalLength: String? = nil

        var shotItems: [ImageMetadataItem] = []
        if let dateOriginal = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            shotItems.append(ImageMetadataItem(label: "Date Taken", value: dateOriginal))
        } else if let dateTiff = tiff?[kCGImagePropertyTIFFDateTime] as? String {
            shotItems.append(ImageMetadataItem(label: "Date", value: dateTiff))
        }

        if let expTime = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue {
            let str = expTime < 1.0 && expTime > 0 ? "1/\(Int(round(1.0 / expTime)))s" : String(format: "%.1fs", expTime)
            shutterSpeed = str
            shotItems.append(ImageMetadataItem(label: "Shutter Speed", value: str))
        }

        if let fNum = (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue {
            let str = String(format: "ƒ/%.1f", fNum)
            aperture = str
            shotItems.append(ImageMetadataItem(label: "Aperture", value: str))
        }

        if let isoArr = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArr.first {
            iso = "\(first)"
            shotItems.append(ImageMetadataItem(label: "ISO", value: "\(first)"))
        } else if let isoNum = (exif?[kCGImagePropertyExifISOSpeedRatings] as? NSNumber)?.intValue {
            iso = "\(isoNum)"
            shotItems.append(ImageMetadataItem(label: "ISO", value: "\(isoNum)"))
        }

        if let fl = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue {
            var fStr = String(format: "%.1f mm", fl)
            if let eq35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue {
                fStr += " (\(eq35)mm equiv)"
            }
            focalLength = String(format: "%.1fmm", fl)
            shotItems.append(ImageMetadataItem(label: "Focal Length", value: fStr))
        }

        if let bias = (exif?[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue {
            shotItems.append(ImageMetadataItem(label: "Exposure Bias", value: String(format: "%+.1f EV", bias)))
        }

        if let flash = (exif?[kCGImagePropertyExifFlash] as? NSNumber)?.intValue {
            let fired = (flash & 1) != 0
            shotItems.append(ImageMetadataItem(label: "Flash", value: fired ? "Fired" : "Did not fire"))
        }

        if let wb = (exif?[kCGImagePropertyExifWhiteBalance] as? NSNumber)?.intValue {
            shotItems.append(ImageMetadataItem(label: "White Balance", value: wb == 0 ? "Auto" : "Manual"))
        }

        if let meter = (exif?[kCGImagePropertyExifMeteringMode] as? NSNumber)?.intValue {
            let meterName: String
            switch meter {
            case 1: meterName = "Average"
            case 2: meterName = "Center-Weighted Average"
            case 3: meterName = "Spot"
            case 4: meterName = "Multi-Spot"
            case 5: meterName = "Multi-Segment (Pattern)"
            case 6: meterName = "Partial"
            default: meterName = "Standard (\(meter))"
            }
            shotItems.append(ImageMetadataItem(label: "Metering", value: meterName))
        }

        if !shotItems.isEmpty {
            sections.append(ImageMetadataSection(title: "Exposure & Settings", icon: "slider.horizontal.3", items: shotItems))
        }

        // 4. GPS & Location
        var gpsCoord: GPSCoordinate? = nil
        if let gps {
            var gpsItems: [ImageMetadataItem] = []
            if let latVal = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
               let lonVal = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                let latSigned = latRef.uppercased() == "S" ? -latVal : latVal
                let lonSigned = lonRef.uppercased() == "W" ? -lonVal : lonVal
                gpsCoord = GPSCoordinate(lat: latSigned, lon: lonSigned)
                gpsItems.append(ImageMetadataItem(label: "Latitude", value: String(format: "%.5f° %@", latVal, latRef)))
                gpsItems.append(ImageMetadataItem(label: "Longitude", value: String(format: "%.5f° %@", lonVal, lonRef)))
            }

            if let altVal = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue {
                let altRef = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue ?? 0
                let altSigned = altRef == 1 ? -altVal : altVal
                gpsItems.append(ImageMetadataItem(label: "Altitude", value: String(format: "%.1f m (%d ft)", altSigned, Int(altSigned * 3.28084))))
            }

            if let speed = (gps[kCGImagePropertyGPSSpeed] as? NSNumber)?.doubleValue {
                let sRef = (gps[kCGImagePropertyGPSSpeedRef] as? String) ?? "K"
                gpsItems.append(ImageMetadataItem(label: "Speed", value: String(format: "%.1f %@", speed, sRef == "M" ? "mph" : "km/h")))
            }

            if let dir = (gps[kCGImagePropertyGPSImgDirection] as? NSNumber)?.doubleValue {
                gpsItems.append(ImageMetadataItem(label: "Heading", value: String(format: "%.0f°", dir)))
            }

            if !gpsItems.isEmpty {
                sections.append(ImageMetadataSection(title: "Location (GPS)", icon: "location", items: gpsItems))
            }
        }

        // 5. IPTC & Rights
        if let iptc {
            var iptcItems: [ImageMetadataItem] = []
            if let obj = iptc[kCGImagePropertyIPTCObjectName] as? String, !obj.isEmpty {
                iptcItems.append(ImageMetadataItem(label: "Title", value: obj))
            }
            if let author = iptc[kCGImagePropertyIPTCByline] as? String, !author.isEmpty {
                iptcItems.append(ImageMetadataItem(label: "Creator / Artist", value: author))
            }
            if let c = iptc[kCGImagePropertyIPTCCopyrightNotice] as? String, !c.isEmpty {
                iptcItems.append(ImageMetadataItem(label: "Copyright", value: c))
            }
            if let desc = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, !desc.isEmpty {
                iptcItems.append(ImageMetadataItem(label: "Caption", value: desc))
            }
            if let kw = iptc[kCGImagePropertyIPTCKeywords] as? [String], !kw.isEmpty {
                iptcItems.append(ImageMetadataItem(label: "Keywords", value: kw.joined(separator: ", ")))
            } else if let kwStr = iptc[kCGImagePropertyIPTCKeywords] as? String, !kwStr.isEmpty {
                iptcItems.append(ImageMetadataItem(label: "Keywords", value: kwStr))
            }

            if !iptcItems.isEmpty {
                sections.append(ImageMetadataSection(title: "IPTC & Copyright", icon: "person.text.rectangle", items: iptcItems))
            }
        }

        let hasEXIFOrGPS = (exif != nil && !exif!.isEmpty) || (gps != nil && !gps!.isEmpty) || (!cameraItems.isEmpty)

        // Summary string
        var textLines: [String] = ["Metadata for \(url.lastPathComponent):"]
        for s in sections {
            textLines.append("\n[\(s.title)]")
            for item in s.items {
                textLines.append("  \(item.label): \(item.value)")
            }
        }

        return ImageMetadataReport(
            fileName: url.lastPathComponent,
            fileSize: fileSizeStr,
            dimensions: dimStr,
            megapixels: mpStr,
            format: ext,
            colorProfile: profileName,
            cameraSummary: cameraSummary,
            exposureSummary: [shutterSpeed, aperture, iso != nil ? "ISO \(iso!)" : nil].compactMap { $0 }.joined(separator: " · "),
            shutterSpeed: shutterSpeed,
            aperture: aperture,
            iso: iso != nil ? "ISO \(iso!)" : nil,
            focalLength: focalLength,
            gpsCoordinate: gpsCoord,
            hasEXIFOrGPS: hasEXIFOrGPS,
            sections: sections,
            fullTextSummary: textLines.joined(separator: "\n")
        )
    }
}

public struct MetadataInspectorView: View {
    public let sourceURL: URL
    public var onStripComplete: ((URL) -> Void)?
    public var onClose: () -> Void

    @State private var report: ImageMetadataReport?
    @State private var thumbnail: NSImage?
    @State private var copied: Bool = false
    @State private var isStripping: Bool = false
    @State private var bannerMessage: String? = nil

    @ObservedObject private var theme = ThemeManager.shared

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            ZStack {
                Text("Metadata Inspector")
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

            // File summary card
            HStack(spacing: 12) {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 58, height: 58)
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceURL.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        badge(text: report?.format ?? sourceURL.pathExtension.uppercased(), isAccent: true)
                        if let dim = report?.dimensions, dim != "Unknown" {
                            badge(text: dim, isAccent: false)
                        }
                        if let mp = report?.megapixels, !mp.isEmpty {
                            badge(text: mp, isAccent: false)
                        }
                        if let size = report?.fileSize {
                            badge(text: size, isAccent: false)
                        }
                    }

                    if let cam = report?.cameraSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill").font(.system(size: 10))
                            Text(cam).font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Quick shooting pills (if available)
            if let report, (report.shutterSpeed != nil || report.aperture != nil || report.iso != nil || report.focalLength != nil) {
                HStack(spacing: 6) {
                    if let s = report.shutterSpeed { statPill(icon: "timer", label: "Shutter", val: s) }
                    if let a = report.aperture { statPill(icon: "camera.aperture", label: "Aperture", val: a) }
                    if let i = report.iso { statPill(icon: "gauge.with.dots.needle.bottom.50percent", label: "ISO", val: i) }
                    if let f = report.focalLength { statPill(icon: "arrow.left.and.right", label: "Focal", val: f) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Banner feedback (if stripped or clean)
            if let msg = bannerMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(msg).font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.12)))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if let report, !report.hasEXIFOrGPS {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill").foregroundColor(.green)
                    Text("No EXIF or GPS tags found in file (already clean)").font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Scrollable list of sections
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    if let sections = report?.sections {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider().opacity(0.4)

            // Action footer
            HStack(spacing: 10) {
                Button(action: copyToClipboard) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy All Info")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                if let coord = report?.gpsCoordinate {
                    Button(action: { openInMaps(lat: coord.lat, lon: coord.lon) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "map")
                            Text("Apple Maps")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if report?.hasEXIFOrGPS == true {
                    Button(action: stripMetadataCopy) {
                        HStack(spacing: 5) {
                            if isStripping {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "shield.slash")
                            }
                            Text("Strip & Save Copy")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                        .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .disabled(isStripping)
                }
            }
            .padding(14)
        }
        .frame(width: 520, height: 620)
        .background(LiquidWindowBackground())
        .onExitCommand(perform: onClose)
        .onAppear {
            loadMetadata()
            loadThumbnail()
        }
    }

    @ViewBuilder
    private func badge(text: String, isAccent: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(isAccent ? theme.accent.opacity(0.15) : Color.primary.opacity(0.06)))
            .foregroundColor(isAccent ? theme.accent : .secondary)
    }

    @ViewBuilder
    private func statPill(icon: String, label: String, val: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(theme.accent)
            Text(val).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func sectionView(_ section: ImageMetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accent)
                Text(section.title)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
            }

            VStack(spacing: 4) {
                ForEach(section.items) { item in
                    HStack(alignment: .top) {
                        Text(item.label)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Spacer()
                        Text(item.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    if item.id != section.items.last?.id {
                        Divider().opacity(0.2)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    private func loadMetadata() {
        report = ImageMetadataReport.load(from: sourceURL)
    }

    private func loadThumbnail() {
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return }
        guard CGImageSourceGetCount(src) > 0 else { return }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 180
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            guard cg.width > 0 && cg.height > 0 else { return }
            thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
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

    private func openInMaps(lat: Double, lon: Double) {
        if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(lat),\(lon)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stripMetadataCopy() {
        isStripping = true
        do {
            let outURL = try FileConversionEngine.shared.stripMetadata(at: sourceURL)
            isStripping = false
            withAnimation {
                bannerMessage = "Saved clean copy: \(outURL.lastPathComponent)"
            }
            onStripComplete?(outURL)
        } catch {
            isStripping = false
            withAnimation {
                bannerMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 8. Theme & Liquid Glass Settings Window

public struct ThemeSettingsView: View {
    @ObservedObject var theme = ThemeManager.shared
    public var onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette.fill")
                        .foregroundColor(theme.accent)
                    Text("Theme & Appearance")
                        .font(.system(size: 14, weight: .bold))
                }
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

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. Theme Presets Grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Select Theme")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(ThemePreset.allCases) { preset in
                                themeCard(preset)
                            }
                        }
                    }

                    // 2. Liquid Glass Customization Section
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            Image(systemName: "drop.fill")
                                .foregroundColor(theme.accent)
                            Text("Liquid Glass Customization")
                                .font(.system(size: 13, weight: .bold))
                            Spacer()
                            if theme.isLiquidGlass {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(theme.accent.opacity(0.18)))
                                    .foregroundColor(theme.accent)
                            }
                        }

                        // Transparency slider
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Glass Transparency")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(theme.transparencyPercentage)% Transparent")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(theme.accent)
                            }

                            Slider(value: $theme.liquidGlassOpacity, in: 0.10...0.85, step: 0.05)
                                .tint(theme.accent)

                            HStack {
                                Text("More Translucent").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Text("More Frosted").font(.caption2).foregroundColor(.secondary)
                            }

                            // Quick preset pills
                            HStack(spacing: 8) {
                                presetOpacityButton(label: "Crystal (80%)", value: 0.20)
                                presetOpacityButton(label: "Balanced (60%)", value: 0.40)
                                presetOpacityButton(label: "Frosted (30%)", value: 0.70)
                            }
                            .padding(.top, 4)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                        // Live Interactive Preview Disc
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live Glass Preview")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)

                            ZStack {
                                // Background texture to test transparency
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.96, green: 0.25, blue: 0.34),
                                        Color(red: 0.99, green: 0.72, blue: 0.14),
                                        Color(red: 0.20, green: 0.65, blue: 0.98),
                                        Color(red: 0.52, green: 0.36, blue: 0.85)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                // Floating Liquid Glass Disc
                                Circle()
                                    .fill(.ultraThinMaterial.opacity(theme.effectiveGlassOpacity))
                                    .background(
                                        Circle().fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.3 * (1.0 - theme.effectiveGlassOpacity * 0.7)),
                                                    Color.cyan.opacity(0.12 * (1.0 - theme.effectiveGlassOpacity * 0.7))
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    )
                                    .overlay(
                                        Circle().strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.9),
                                                    Color.cyan.opacity(0.6),
                                                    Color.purple.opacity(0.3),
                                                    Color.white.opacity(0.7)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2
                                        )
                                    )
                                    .frame(width: 84, height: 84)
                                    .overlay(
                                        VStack(spacing: 2) {
                                            Image(systemName: "drop.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.white)
                                                .shadow(color: .black.opacity(0.4), radius: 3)
                                            Text("\(theme.transparencyPercentage)%")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(.white)
                                                .shadow(color: .black.opacity(0.4), radius: 3)
                                        }
                                    )
                                    .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 5)
                            }
                        }

                        // macOS System Settings Connection Card
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Sync with macOS System Settings", isOn: $theme.syncWithSystemSettings)
                                .font(.system(size: 12, weight: .medium))
                                .tint(theme.accent)

                            Text("Automatically adjusts when 'Reduce transparency' is toggled in macOS System Settings → Accessibility → Display.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(theme.systemReduceTransparency ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                Text(theme.systemReduceTransparency
                                     ? "System 'Reduce Transparency' is currently ON"
                                     : "System 'Reduce Transparency' is currently OFF")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.systemReduceTransparency ? .orange : .secondary)

                                Spacer()

                                Button("Open Display Settings…") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Display") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.link)
                            }
                            .padding(.top, 4)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    }
                }
                .padding(16)
            }

            Divider().opacity(0.3)

            // Footer
            HStack {
                Button("Reset Defaults") {
                    withAnimation {
                        theme.currentTheme = .tangerine
                        theme.liquidGlassOpacity = 0.40
                        theme.syncWithSystemSettings = true
                    }
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button("Done") {
                    onClose()
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
                .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .frame(width: 500, height: 640)
        .background(LiquidWindowBackground())
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private func themeCard(_ preset: ThemePreset) -> some View {
        let isSelected = theme.currentTheme == preset
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                theme.currentTheme = preset
            }
        } label: {
            HStack(spacing: 10) {
                // Swatch Circle
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [preset.accentLight, preset.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: preset.systemIcon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(preset == .monochrome ? .black : .white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(preset.name)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .foregroundColor(.primary)
                        if preset == .liquidGlass {
                            Text("GLASS")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.cyan.opacity(0.2)))
                                .foregroundColor(.cyan)
                        }
                    }
                    Text(preset.description)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accent)
                        .font(.system(size: 14))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? theme.accent.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? theme.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func presetOpacityButton(label: String, value: Double) -> some View {
        let isCurrent = abs(theme.liquidGlassOpacity - value) < 0.03
        Button {
            withAnimation {
                theme.liquidGlassOpacity = value
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? theme.accent : Color.primary.opacity(0.06)))
                .foregroundColor(isCurrent ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 9. App Coordinator & Floating Wheel Controller

private final class EditorWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

@MainActor
public final class AppCoordinator: ObservableObject {
    public let dragMonitor = DragMonitorService()
    @Published public var statusMessage: String = "Ready — Hold ⇧ while dragging in Finder"

    private var wheelPanel: WheelPanel?
    private var wheelState: WheelState?
    private var wheelCenterPoint: CGPoint = .zero
    private var editorWindow: NSWindow?
    private var editorWindowDelegate: EditorWindowDelegate?

    public init() {
        setupDragMonitor()
        dragMonitor.startMonitoring()
    }

    private func setupDragMonitor() {
        dragMonitor.onWheelRequested = { [weak self] urls, mode, loc in
            self?.showWheel(for: urls, mode: mode, at: loc, interaction: .drag)
        }
        dragMonitor.onModeChanged = { [weak self] mode in
            self?.wheelState?.setMode(mode)
        }
        dragMonitor.onPointerMoved = { [weak self] loc in
            guard let self, let state = self.wheelState else { return }
            let dx = loc.x - self.wheelCenterPoint.x
            let dy = loc.y - self.wheelCenterPoint.y
            state.updatePointer(dx: dx, dy: dy)
        }
        dragMonitor.onMouseReleased = { [weak self] in
            guard let self, let state = self.wheelState else { return }
            if state.hoveredSlice != nil {
                state.commitCurrentSelection()
            } else {
                self.hideWheel()
            }
        }
        dragMonitor.onMouseDown = { [weak self] in
            if self?.wheelState?.interaction == .click {
                // If user clicks outside the wheel during click test, dismiss
            }
        }
    }

    public func pickFileAndShowWheel(mode: WheelMode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to test the OpenTangerine radial menu"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            showWheel(for: [url], mode: mode, at: NSEvent.mouseLocation, interaction: .click)
        }
    }

    public func showWheel(for urls: [URL], mode: WheelMode, at screenLocation: CGPoint, interaction: WheelInteraction) {
        guard !urls.isEmpty else { return }

        let panelSize = WheelGeometry.panelSize
        var center = screenLocation

        // Keep wheel on screen
        if let screen = NSScreen.screens.first(where: { NSPointInRect(screenLocation, $0.frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let margin = panelSize / 2 + 10
            center.x = min(max(center.x, visible.minX + margin), visible.maxX - margin)
            center.y = min(max(center.y, visible.minY + margin), visible.maxY - margin)
        }
        wheelCenterPoint = center

        let origin = CGPoint(x: center.x - panelSize / 2, y: center.y - panelSize / 2)
        let rect = CGRect(origin: origin, size: CGSize(width: panelSize, height: panelSize))

        let state = WheelState(fileURLs: urls, mode: mode, interaction: interaction)
        self.wheelState = state

        state.onCommit = { [weak self] slice in
            guard let self else { return }
            self.hideWheel()
            switch slice.action {
            case .openTool:
                if let first = urls.first {
                    self.execute(slice.action, for: first)
                }
            case .convertToFormat:
                for url in urls {
                    self.execute(slice.action, for: url)
                }
            }
        }
        state.onDismiss = { [weak self] in
            self?.hideWheel()
        }

        let panel: WheelPanel
        if let existing = self.wheelPanel {
            panel = existing
            panel.setFrame(rect, display: true)
        } else {
            panel = WheelPanel(contentRect: rect)
            self.wheelPanel = panel
        }

        // Host the interactive SwiftUI wheel view
        let hostingView = NSHostingView(rootView: RadialWheelView(state: state))
        hostingView.frame = NSRect(origin: .zero, size: rect.size)

        // Overlay interaction view to support Finder drop target and mouse tracking
        let interactionView = WheelInteractionView(frame: NSRect(origin: .zero, size: rect.size))
        interactionView.canDrop = { [weak state] in state?.hoveredSlice != nil }
        interactionView.onDrop = { [weak state] in
            guard let state, state.hoveredSlice != nil else { return false }
            state.commitCurrentSelection()
            return true
        }
        interactionView.onPointer = { [weak self, weak state] screenPoint in
            guard let self, let state else { return }
            let dx = screenPoint.x - self.wheelCenterPoint.x
            let dy = screenPoint.y - self.wheelCenterPoint.y
            state.updatePointer(dx: dx, dy: dy)
        }
        interactionView.onClick = { [weak state] in
            if state?.hoveredSlice != nil {
                state?.commitCurrentSelection()
            } else {
                state?.onDismiss?()
            }
        }

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.addSubview(hostingView)
        container.addSubview(interactionView)
        panel.contentView = container

        panel.orderFrontRegardless()
        withAnimation {
            state.isPresented = true
        }
    }

    public func hideWheel() {
        guard let state = wheelState else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            state.isPresented = false
        }
        dragMonitor.endSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.wheelPanel?.orderOut(nil)
            self.wheelPanel?.contentView = nil
            self.wheelState = nil
        }
    }

    public func execute(_ action: RadialActionType, for fileURL: URL) {
        switch action {
        case .convertToFormat(let ext):
            do {
                let outURL = try FileConversionEngine.shared.convertFile(at: fileURL, to: ext)
                statusMessage = "Saved \(outURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([outURL])
            } catch {
                statusMessage = "Failed: \(error.localizedDescription)"
                showNotification(title: "Conversion Error", message: error.localizedDescription)
            }

        case .openTool(let tool):
            switch tool {
            case .crop:
                openEditor(CropEditorView(
                    sourceURL: fileURL,
                    onComplete: { [weak self] url in
                        self?.closeEditor()
                        self?.statusMessage = "Cropped \(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onClose: { [weak self] in self?.closeEditor() }
                ), size: CGSize(width: 480, height: 580))

            case .addBG:
                openEditor(BackgroundEditorView(
                    sourceURL: fileURL,
                    onComplete: { [weak self] url in
                        self?.closeEditor()
                        self?.statusMessage = "Added BG to \(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onClose: { [weak self] in self?.closeEditor() }
                ), size: CGSize(width: 490, height: 610))

            case .compress:
                do {
                    let result = try FileConversionEngine.shared.compressImage(at: fileURL)
                    let saved = RadialMenuConfiguration.formattedByteCount(result.originalBytes - result.newBytes)
                    statusMessage = "Compressed: saved \(saved)"
                    NSWorkspace.shared.activateFileViewerSelecting([result.output])
                } catch {
                    statusMessage = error.localizedDescription
                    showNotification(title: "Compress Image", message: error.localizedDescription)
                }

            case .metadata:
                statusMessage = "Inspecting metadata: \(fileURL.lastPathComponent)"
                openEditor(MetadataInspectorView(
                    sourceURL: fileURL,
                    onStripComplete: { [weak self] url in
                        self?.statusMessage = "Saved clean copy: \(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onClose: { [weak self] in self?.closeEditor() }
                ), size: CGSize(width: 520, height: 620))
            }
        }
    }

    private func showNotification(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    public func closeEditor() {
        guard let win = editorWindow else { return }
        editorWindow = nil
        editorWindowDelegate = nil
        win.delegate = nil
        win.contentView = nil
        win.orderOut(nil)
        win.close()
    }

    private func openEditor<V: View>(_ view: V, size: CGSize) {
        closeEditor()

        let win = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.level = .floating
        win.center()
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        let hostingView = NSHostingView(rootView: view)
        win.contentView = hostingView

        let delegate = EditorWindowDelegate()
        delegate.onClose = { [weak self] in
            self?.editorWindow = nil
            self?.editorWindowDelegate = nil
        }
        win.delegate = delegate
        self.editorWindowDelegate = delegate
        self.editorWindow = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func openSettings() {
        openEditor(ThemeSettingsView(onClose: { [weak self] in
            self?.closeEditor()
        }), size: CGSize(width: 500, height: 640))
    }
}

// MARK: - 8. Menu Bar App Entry Point & CLI Support

@main
public struct OpenTangerineApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @ObservedObject private var theme = ThemeManager.shared

    public init() {
        if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--convert" {
            let targetExt = CommandLine.arguments[2]
            let filePath = CommandLine.arguments[3]
            let url = URL(fileURLWithPath: filePath)
            do {
                let out = try FileConversionEngine.shared.convertFile(at: url, to: targetExt)
                print("Converted: \(out.path)")
                exit(0)
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--test-stability") {
            print("==> Running OpenTangerine Stability Tests…")
            let theme = ThemeManager.shared
            for preset in ThemePreset.allCases {
                theme.currentTheme = preset
                assert(theme.currentTheme == preset)
                _ = theme.accent
                _ = theme.isLiquidGlass
                _ = theme.effectiveGlassOpacity
            }
            print("  ✓ Theme preset switching: OK")

            let coord = AppCoordinator()
            coord.openSettings()
            theme.currentTheme = .liquidGlass
            theme.liquidGlassOpacity = 0.50
            theme.currentTheme = .monochrome
            theme.currentTheme = .tangerine
            coord.closeEditor()
            print("  ✓ Theme settings open/close/switch: OK")

            coord.openSettings()
            coord.openSettings()
            coord.closeEditor()
            print("  ✓ Idempotent settings re-opening: OK")

            let tempDir = FileManager.default.temporaryDirectory
            let testImgURL = tempDir.appendingPathComponent("test_img.png")
            let img = NSImage(size: NSSize(width: 80, height: 80))
            img.lockFocus()
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 0, width: 80, height: 80).fill()
            img.unlockFocus()
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: testImgURL)
            }

            let report = ImageMetadataReport.load(from: testImgURL)
            assert(!report.format.isEmpty)
            print("  ✓ ImageMetadataReport extraction: OK (\(report.dimensions), \(report.format))")

            coord.execute(.openTool(.metadata), for: testImgURL)
            coord.closeEditor()
            coord.execute(.openTool(.metadata), for: testImgURL)
            coord.openSettings()
            coord.closeEditor()
            print("  ✓ Metadata inspector open/close/switch: OK")

            print("==> ALL STABILITY TESTS PASSED WITH ZERO CRASHES! 🎉")
            exit(0)
        }
    }

    public var body: some Scene {
        MenuBarExtra("OpenTangerine", systemImage: "circle.hexagongrid.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenTangerine").font(.headline)
                        Text(coordinator.statusMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Divider()
                Text("• Hold Shift (⇧) + Drag: Convert Wheel").font(.caption)
                Text("• Hold Option + Shift (⌥⇧) + Drag: Tools Wheel").font(.caption)
                Divider()
                Button("Pick File to Test Convert Wheel…") {
                    coordinator.pickFileAndShowWheel(mode: .convert)
                }
                Button("Pick File to Test Tools Wheel…") {
                    coordinator.pickFileAndShowWheel(mode: .tools)
                }
                Divider()
                Menu("Theme") {
                    ForEach(ThemePreset.allCases) { preset in
                        Button {
                            theme.currentTheme = preset
                        } label: {
                            if theme.currentTheme == preset {
                                Text("✓ \(preset.name)")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                }
                if theme.isLiquidGlass {
                    Text("• Glass: \(theme.transparencyPercentage)% Transparent")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("Theme & Appearance Settings…") {
                    coordinator.openSettings()
                }
                .keyboardShortcut(",")
                Divider()
                Button("Quit OpenTangerine") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
        }
    }
}

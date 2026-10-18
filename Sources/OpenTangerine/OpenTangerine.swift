//
//  OpenTangerine.swift
//  OpenTangerine — Open-Source macOS Radial File Converter & Image Toolkit
//  Inspired by Tangerine: File Converter for macOS
//
//  Compile & Run on macOS 13.0+:
//    swiftc OpenTangerine.swift -o OpenTangerine && ./OpenTangerine
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

public enum FileCategory: String {
    case pdf, image, video, audio, document, unknown

    public static func detect(from url: URL) -> FileCategory {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf
        case "jpg", "jpeg", "png", "webp", "heic", "tiff", "tif", "bmp", "gif", "avif":
            return .image
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff":
            return .audio
        case "txt", "rtf", "docx", "md", "html":
            return .document
        default:
            return .unknown
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
    case adjust = "ADJUST"
    case annotate = "ANNOTATE"
    case addBG = "ADD BG"
    case redact = "REDACT"

    public var id: String { rawValue }

    public var systemIcon: String {
        switch self {
        case .crop: return "crop"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "info.circle"
        case .adjust: return "slider.horizontal.3"
        case .annotate: return "pencil.tip.crop.circle"
        case .addBG: return "photo.artframe"
        case .redact: return "eye.slash"
        }
    }
}

public struct RadialSlice: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let systemIcon: String?
    public let action: RadialActionType

    public init(title: String, systemIcon: String? = nil, action: RadialActionType) {
        self.title = title
        self.systemIcon = systemIcon
        self.action = action
    }
}

public struct RadialMenuConfiguration {
    public let outerSlices: [RadialSlice]
    public let centerSlice: RadialSlice?
    public let centerSubtitle: String

    public static func build(for url: URL, mode: WheelMode) -> RadialMenuConfiguration {
        let category = FileCategory.detect(from: url)
        let fileSizeString = Self.formattedFileSize(for: url)

        switch mode {
        case .convert:
            switch category {
            case .pdf:
                // Matches 00:02 in video: DOCX (top), JPG (right), PNG (bottom), TXT (left) + file size in center
                return RadialMenuConfiguration(
                    outerSlices: [
                        RadialSlice(title: "DOCX", action: .convertToFormat("docx")),
                        RadialSlice(title: "JPG", action: .convertToFormat("jpg")),
                        RadialSlice(title: "PNG", action: .convertToFormat("png")),
                        RadialSlice(title: "TXT", action: .convertToFormat("txt"))
                    ],
                    centerSlice: nil,
                    centerSubtitle: fileSizeString
                )
            case .image:
                // Matches 00:05 & 00:12 in video: 8 outer format slices + TIFF in center
                let currentExt = url.pathExtension.lowercased()
                let normalizedExt = (currentExt == "jpeg") ? "jpg" : currentExt
                let formats = ["PNG", "WEBP", "HEIC", "JPG", "AVIF", "BMP", "PDF", "DOCX"]
                    .filter { $0.lowercased() != normalizedExt }
                return RadialMenuConfiguration(
                    outerSlices: Array(formats.prefix(8)).map {
                        RadialSlice(title: $0, action: .convertToFormat($0.lowercased()))
                    },
                    centerSlice: RadialSlice(title: "TIFF", action: .convertToFormat("tiff")),
                    centerSubtitle: fileSizeString
                )
            default:
                return RadialMenuConfiguration(
                    outerSlices: ["PDF", "TXT", "DOCX", "PNG", "JPG"].map {
                        RadialSlice(title: $0, action: .convertToFormat($0.lowercased()))
                    },
                    centerSlice: nil,
                    centerSubtitle: fileSizeString
                )
            }

        case .tools:
            // Matches 00:05.4 & 00:13 in video: 6 outer tool slices + CROP in center
            let outerTools: [ToolKind] = [.compress, .metadata, .adjust, .annotate, .addBG, .redact]
            return RadialMenuConfiguration(
                outerSlices: outerTools.map {
                    RadialSlice(title: $0.rawValue, systemIcon: $0.systemIcon, action: .openTool($0))
                },
                centerSlice: RadialSlice(title: "CROP", systemIcon: "crop", action: .openTool(.crop)),
                centerSubtitle: fileSizeString
            )
        }
    }

    public static func formattedFileSize(for url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return "File" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - 2. Global Finder Drag & Modifier Monitor

@MainActor
public final class DragMonitorService: ObservableObject {
    @Published public var isWheelVisible: Bool = false
    @Published public var wheelCenterScreenPoint: CGPoint = .zero
    @Published public var activeFileURLs: [URL] = []
    @Published public var activeMode: WheelMode = .convert
    @Published public var hoveredSlice: RadialSlice? = nil
    @Published public var statusMessage: String = "Ready — Hold Shift (⇧) while dragging any file in Finder"

    private var monitors: [Any] = []
    private var isDraggingFile: Bool = false
    public var onStateChanged: (() -> Void)?
    public var onActionTriggered: ((URL, RadialActionType) -> Void)?

    public func startMonitoring() {
        if let m1 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] e in
            Task { @MainActor in self?.handleDrag(e) }
        }) { monitors.append(m1) }

        if let m2 = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] e in
            Task { @MainActor in self?.handleFlags(e) }
        }) { monitors.append(m2) }

        if let m3 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
            Task { @MainActor in self?.handleMouseUp(e) }
        }) { monitors.append(m3) }
    }

    private func handleDrag(_ event: NSEvent) {
        let pasteboard = NSPasteboard(name: .drag)
        if !isDraggingFile {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                isDraggingFile = true
                activeFileURLs = urls
            }
        }
        guard isDraggingFile, !activeFileURLs.isEmpty else { return }
        evaluateModifiers(event.modifierFlags, at: NSEvent.mouseLocation)
    }

    private func handleFlags(_ event: NSEvent) {
        guard isDraggingFile, !activeFileURLs.isEmpty else { return }
        evaluateModifiers(event.modifierFlags, at: NSEvent.mouseLocation)
    }

    private func evaluateModifiers(_ flags: NSEvent.ModifierFlags, at mouseLoc: CGPoint) {
        let hasShift = flags.contains(.shift)
        let hasOption = flags.contains(.option)

        if hasShift && hasOption {
            activeMode = .tools
            if !isWheelVisible {
                wheelCenterScreenPoint = mouseLoc
                isWheelVisible = true
            }
            onStateChanged?()
        } else if hasShift {
            activeMode = .convert
            if !isWheelVisible {
                wheelCenterScreenPoint = mouseLoc
                isWheelVisible = true
            }
            onStateChanged?()
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        defer {
            isDraggingFile = false
            isWheelVisible = false
            hoveredSlice = nil
            onStateChanged?()
        }
        guard isWheelVisible, let slice = hoveredSlice, let firstURL = activeFileURLs.first else { return }
        onActionTriggered?(firstURL, slice.action)
    }
}

// MARK: - 3. Offline File Conversion Engine (PDFKit + ImageIO + CoreGraphics)

public enum ConversionError: LocalizedError {
    case unreadableSource(String)
    case unsupportedConversion(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableSource(let msg): return "Could not read source file: \(msg)"
        case .unsupportedConversion(let msg): return "Unsupported conversion: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        }
    }
}

public final class FileConversionEngine {
    public static let shared = FileConversionEngine()

    @discardableResult
    public func convertFile(at sourceURL: URL, to targetExt: String) throws -> URL {
        let ext = targetExt.lowercased()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let parentDir = sourceURL.deletingLastPathComponent()
        let destinationURL = uniqueOutputURL(in: parentDir, baseName: baseName, ext: ext)
        let category = FileCategory.detect(from: sourceURL)

        switch (category, ext) {
        case (.pdf, "jpg"), (.pdf, "jpeg"), (.pdf, "png"), (.pdf, "tiff"), (.pdf, "bmp"), (.pdf, "heic"), (.pdf, "webp"):
            try renderPDFFirstPageToImage(pdfURL: sourceURL, destinationURL: destinationURL, format: ext)
        case (.pdf, "txt"):
            try extractTextFromPDF(pdfURL: sourceURL, destinationURL: destinationURL)
        case (.pdf, "docx"):
            try convertPDFToDocx(pdfURL: sourceURL, destinationURL: destinationURL)
        case (.image, "pdf"):
            try convertImageToPDF(imageURL: sourceURL, destinationURL: destinationURL)
        case (.image, "docx"):
            try convertImageToDocx(imageURL: sourceURL, destinationURL: destinationURL)
        case (.image, _):
            try convertImageFormat(sourceURL: sourceURL, destinationURL: destinationURL, format: ext)
        default:
            throw ConversionError.unsupportedConversion("\(sourceURL.pathExtension) -> \(ext)")
        }
        return destinationURL
    }

    private func renderPDFFirstPageToImage(pdfURL: URL, destinationURL: URL, format: String) throws {
        guard let pdfDoc = PDFDocument(url: pdfURL), let page = pdfDoc.page(at: 0) else {
            throw ConversionError.unreadableSource(pdfURL.lastPathComponent)
        }
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300.0 / 72.0 // 300 DPI (2550 x 3300 px for US Letter)
        let targetSize = CGSize(width: round(pageRect.width * scale), height: round(pageRect.height * scale))

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ConversionError.exportFailed("Failed to allocate bitmap buffer.")
        }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep) {
            NSGraphicsContext.current = ctx
            ctx.cgContext.setFillColor(NSColor.white.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: targetSize))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmapRep.cgImage else {
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

    private func convertImageFormat(sourceURL: URL, destinationURL: URL, format: String) throws {
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConversionError.unreadableSource(sourceURL.lastPathComponent)
        }
        try writeCGImage(cgImg, to: destinationURL, format: format, quality: 0.92)
    }

    private func convertImageToPDF(imageURL: URL, destinationURL: URL) throws {
        guard let nsImage = NSImage(contentsOf: imageURL), let page = PDFPage(image: nsImage) else {
            throw ConversionError.unreadableSource(imageURL.lastPathComponent)
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        doc.write(to: destinationURL)
    }

    private func convertImageToDocx(imageURL: URL, destinationURL: URL) throws {
        guard let nsImage = NSImage(contentsOf: imageURL) else {
            throw ConversionError.unreadableSource(imageURL.lastPathComponent)
        }
        let attachment = NSTextAttachment()
        attachment.image = nsImage
        let attr = NSAttributedString(attachment: attachment)
        let data = try attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: destinationURL)
    }

    public func writeCGImage(_ cgImage: CGImage, to destinationURL: URL, format: String, quality: Double = 0.92) throws {
        let utType: CFString
        switch format.lowercased() {
        case "jpg", "jpeg": utType = UTType.jpeg.identifier as CFString
        case "png": utType = UTType.png.identifier as CFString
        case "tiff", "tif": utType = UTType.tiff.identifier as CFString
        case "heic": utType = UTType.heic.identifier as CFString
        case "bmp": utType = UTType.bmp.identifier as CFString
        case "webp": utType = UTType.webP.identifier as CFString
        default: utType = UTType.png.identifier as CFString
        }

        if let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, utType, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(dest) { return }
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let fileType: NSBitmapImageRep.FileType = (format == "jpg" || format == "jpeg") ? .jpeg : .png
        guard let data = rep.representation(using: fileType, properties: [.compressionFactor: quality]) else {
            throw ConversionError.exportFailed("Encoding failed for \(format)")
        }
        try data.write(to: destinationURL)
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

// MARK: - 4. Radial Pie Menu View

public struct AnnularSectorShape: Shape {
    public var startAngle: Angle
    public var endAngle: Angle
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat

    public func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

public struct RadialWheelView: View {
    public let fileURL: URL
    public let mode: WheelMode
    @Binding public var hoveredSlice: RadialSlice?
    public var onSelectSlice: (RadialSlice) -> Void

    private let wheelDiameter: CGFloat = 310
    private let outerRadius: CGFloat = 144
    private let innerRadius: CGFloat = 58
    private let gapDegrees: Double = 4.0

    private var config: RadialMenuConfiguration {
        RadialMenuConfiguration.build(for: fileURL, mode: mode)
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: wheelDiameter, height: wheelDiameter)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 2))
                .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)

            let slices = config.outerSlices
            let stepDegrees = 360.0 / Double(max(slices.count, 1))

            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let midAngle = -90.0 + Double(index) * stepDegrees
                let startDeg = midAngle - (stepDegrees / 2.0) + (gapDegrees / 2.0)
                let endDeg = midAngle + (stepDegrees / 2.0) - (gapDegrees / 2.0)
                let isHovered = (hoveredSlice == slice)

                ZStack {
                    AnnularSectorShape(
                        startAngle: .degrees(startDeg),
                        endAngle: .degrees(endDeg),
                        innerRadius: innerRadius,
                        outerRadius: outerRadius
                    )
                    .fill(
                        isHovered
                        ? Color(red: 0.94, green: 0.30, blue: 0.12)
                        : Color.white.opacity(0.48)
                    )

                    let labelRadius = (innerRadius + outerRadius) / 2.0
                    let rad = midAngle * .pi / 180.0
                    VStack(spacing: 4) {
                        if let icon = slice.systemIcon {
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text(slice.title)
                            .font(.system(size: slice.systemIcon == nil ? 13 : 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(isHovered ? .white : .black.opacity(0.85))
                    .offset(x: cos(rad) * labelRadius, y: sin(rad) * labelRadius)
                }
                .onHover { hovering in
                    hoveredSlice = hovering ? slice : (hoveredSlice == slice ? nil : hoveredSlice)
                }
                .onTapGesture {
                    onSelectSlice(slice)
                }
            }

            if let centerSlice = config.centerSlice {
                let isCenterHovered = (hoveredSlice == centerSlice)
                Button {
                    onSelectSlice(centerSlice)
                } label: {
                    Text(centerSlice.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(isCenterHovered ? .white : .black.opacity(0.85))
                        .frame(width: 82, height: 50)
                        .background(
                            Capsule().fill(isCenterHovered ? Color(red: 0.94, green: 0.30, blue: 0.12) : Color.white.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in hoveredSlice = hovering ? centerSlice : nil }
            } else {
                Text(config.centerSubtitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.55)))
            }
        }
        .frame(width: 340, height: 340)
    }
}

// MARK: - 5. Crop Image Window (Matches 00:07 - 00:10 in Video)

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
    private let accentOrange = Color(red: 0.94, green: 0.30, blue: 0.12)

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
                            .stroke(accentOrange, lineWidth: 2)
                            .frame(width: cropRect.width, height: cropRect.height)
                            .position(x: cropRect.midX, y: cropRect.midY)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(accentOrange)
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
                        .background(RoundedRectangle(cornerRadius: 6).fill(selectedPreset == preset ? accentOrange : Color.clear))
                        .foregroundColor(selectedPreset == preset ? .white : .primary)
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(accentOrange))
                        .foregroundColor(.white)
                }
            }
            .padding(18)
        }
        .frame(width: 480, height: 580)
        .background(.ultraThinMaterial)
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

// MARK: - 6. Add BG Window (Matches 00:14 - 00:19 in Video)

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

    private let accentOrange = Color(red: 0.94, green: 0.30, blue: 0.12)
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
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedPresetIndex == idx ? accentOrange : .clear, lineWidth: 2))
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
                            .background(RoundedRectangle(cornerRadius: 6).fill(selectedRatio == r ? accentOrange : Color.clear))
                            .foregroundColor(selectedRatio == r ? .white : .primary)
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(accentOrange))
                        .foregroundColor(.white)
                }
            }
            .padding(20)
        }
        .frame(width: 490, height: 610)
        .background(.ultraThinMaterial)
        .onAppear { nsImage = NSImage(contentsOf: sourceURL) }
    }

    @ViewBuilder
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            Slider(value: value, in: range).tint(accentOrange)
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

// MARK: - 7. Floating NSPanel & Menu Bar App Entry Point

@MainActor
public final class AppCoordinator: ObservableObject {
    public let dragMonitor = DragMonitorService()
    private var wheelPanel: NSPanel?
    private var editorWindow: NSWindow?

    public init() {
        dragMonitor.onStateChanged = { [weak self] in self?.syncWheelPanel() }
        dragMonitor.onActionTriggered = { [weak self] url, action in self?.execute(action, for: url) }
        dragMonitor.startMonitoring()
    }

    public func syncWheelPanel() {
        guard dragMonitor.isWheelVisible, let firstURL = dragMonitor.activeFileURLs.first else {
            wheelPanel?.orderOut(nil)
            return
        }
        let size = CGSize(width: 340, height: 340)
        let origin = CGPoint(
            x: dragMonitor.wheelCenterScreenPoint.x - size.width / 2,
            y: dragMonitor.wheelCenterScreenPoint.y - size.height / 2
        )
        if wheelPanel == nil {
            let panel = NSPanel(
                contentRect: CGRect(origin: origin, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            wheelPanel = panel
        }
        let view = RadialWheelView(
            fileURL: firstURL,
            mode: dragMonitor.activeMode,
            hoveredSlice: Binding(
                get: { self.dragMonitor.hoveredSlice },
                set: { self.dragMonitor.hoveredSlice = $0 }
            ),
            onSelectSlice: { [weak self] slice in
                self?.wheelPanel?.orderOut(nil)
                self?.execute(slice.action, for: firstURL)
            }
        )
        wheelPanel?.contentView = NSHostingView(rootView: view)
        wheelPanel?.setFrameOrigin(origin)
        wheelPanel?.orderFrontRegardless()
    }

    public func execute(_ action: RadialActionType, for fileURL: URL) {
        switch action {
        case .convertToFormat(let ext):
            if let outURL = try? FileConversionEngine.shared.convertFile(at: fileURL, to: ext) {
                dragMonitor.statusMessage = "Saved \(outURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([outURL])
            }
        case .openTool(let tool):
            if tool == .crop {
                openEditor(CropEditorView(
                    sourceURL: fileURL,
                    onComplete: { [weak self] url in
                        self?.editorWindow?.close()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onClose: { [weak self] in self?.editorWindow?.close() }
                ), size: CGSize(width: 480, height: 580))
            } else {
                openEditor(BackgroundEditorView(
                    sourceURL: fileURL,
                    onComplete: { [weak self] url in
                        self?.editorWindow?.close()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onClose: { [weak self] in self?.editorWindow?.close() }
                ), size: CGSize(width: 490, height: 610))
            }
        }
    }

    private func openEditor<V: View>(_ view: V, size: CGSize) {
        editorWindow?.close()
        let win = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        win.level = .floating
        win.center()
        win.contentView = NSHostingView(rootView: view)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow = win
    }
}

@main
public struct OpenTangerineApp: App {
    @StateObject private var coordinator = AppCoordinator()

    public init() {}

    public var body: some Scene {
        MenuBarExtra("OpenTangerine", systemImage: "circle.hexagongrid.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenTangerine for macOS").font(.headline)
                Text(coordinator.dragMonitor.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Divider()
                Text("• Hold Shift (⇧) + Drag file: Convert Wheel").font(.caption)
                Text("• Hold Option + Shift (⌥⇧) + Drag: Tools Wheel").font(.caption)
                Divider()
                Button("Pick File to Test Convert Wheel…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url {
                        coordinator.dragMonitor.activeFileURLs = [url]
                        coordinator.dragMonitor.activeMode = .convert
                        coordinator.dragMonitor.wheelCenterScreenPoint = NSEvent.mouseLocation
                        coordinator.dragMonitor.isWheelVisible = true
                        coordinator.syncWheelPanel()
                    }
                }
                Button("Pick File to Test Tools Wheel…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url {
                        coordinator.dragMonitor.activeFileURLs = [url]
                        coordinator.dragMonitor.activeMode = .tools
                        coordinator.dragMonitor.wheelCenterScreenPoint = NSEvent.mouseLocation
                        coordinator.dragMonitor.isWheelVisible = true
                        coordinator.syncWheelPanel()
                    }
                }
                Divider()
                Button("Quit OpenTangerine") { NSApplication.shared.terminate(nil) }
            }
            .padding(12)
        }
    }
}
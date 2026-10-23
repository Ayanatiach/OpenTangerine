//
//  PhotoPDFStudio.swift
//  OpenTangerine
//
//  Multi-Photo PDF Studio: Interactive page ordering, per-photo cropping,
//  rotation, document scan enhancements, filters, and high-fidelity PDF compilation.
//

import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - 1. Studio Models & Enums

public enum PhotoCropPreset: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "1:1 Square"
    case ratio4_3 = "4:3 Standard"
    case ratio16_9 = "16:9 Wide"
    case ratio3_2 = "3:2 Photo"
    case a4Portrait = "A4 Portrait"
    case a4Landscape = "A4 Landscape"
    case usLetter = "US Letter"

    public var id: String { rawValue }

    public func targetAspectRatio(for imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.height > 0 ? (imageSize.width / imageSize.height) : 1.0
        case .square: return 1.0
        case .ratio4_3: return 4.0 / 3.0
        case .ratio16_9: return 16.0 / 9.0
        case .ratio3_2: return 3.0 / 2.0
        case .a4Portrait: return 1.0 / 1.4142
        case .a4Landscape: return 1.4142
        case .usLetter: return 8.5 / 11.0
        }
    }
}

public enum PhotoFilter: String, CaseIterable, Identifiable {
    case none = "Original"
    case scanDoc = "Doc Scan"
    case grayscale = "B & W"
    case sepia = "Sepia"
    case vivid = "Vivid"
    case warm = "Warm"
    case cool = "Cool"
    case invert = "Negative"

    public var id: String { rawValue }

    public var systemIcon: String {
        switch self {
        case .none: return "photo"
        case .scanDoc: return "doc.viewfinder"
        case .grayscale: return "circle.righthalf.filled"
        case .sepia: return "sun.dust.fill"
        case .vivid: return "sparkles"
        case .warm: return "sun.max.fill"
        case .cool: return "snowflake"
        case .invert: return "circle.lefthalf.filled.inverse"
        }
    }
}

public enum PDFPageSizeOption: String, CaseIterable, Identifiable {
    case matchImage = "Fit to Photo"
    case a4 = "A4 Paper"
    case usLetter = "US Letter"
    case square = "Square (8×8 in)"

    public var id: String { rawValue }

    public var pointsSize: CGSize? {
        switch self {
        case .matchImage: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .usLetter: return CGSize(width: 612.0, height: 792.0)
        case .square: return CGSize(width: 576.0, height: 576.0)
        }
    }
}

public enum PDFMarginOption: String, CaseIterable, Identifiable {
    case none = "Borderless"
    case small = "Small (0.25\")"
    case normal = "Normal (0.5\")"

    public var id: String { rawValue }

    public var insetPoints: CGFloat {
        switch self {
        case .none: return 0.0
        case .small: return 18.0
        case .normal: return 36.0
        }
    }
}

public enum PDFQualityOption: String, CaseIterable, Identifiable {
    case maximum = "Maximum Quality"
    case balanced = "Balanced"
    case compressed = "Compact File"

    public var id: String { rawValue }

    public var compressionFactor: CGFloat {
        switch self {
        case .maximum: return 0.95
        case .balanced: return 0.80
        case .compressed: return 0.55
        }
    }
}

public struct PhotoPageItem: Identifiable, Equatable {
    public let id: UUID
    public let sourceURL: URL
    public var name: String
    public var fileSizeString: String
    public var originalPixelSize: CGSize

    // Geometric transforms
    public var rotationDegrees: Int = 0 // 0, 90, 180, 270 (clockwise)
    public var isFlippedHorizontal: Bool = false
    public var isFlippedVertical: Bool = false
    public var normalizedCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    public var cropPreset: PhotoCropPreset = .free

    // Visual enhancements
    public var brightness: Double = 0.0 // -0.5 ... 0.5
    public var contrast: Double = 1.0   // 0.5 ... 2.0
    public var saturation: Double = 1.0 // 0.0 ... 2.0
    public var filter: PhotoFilter = .none

    public init(url: URL) {
        self.id = UUID()
        self.sourceURL = url
        self.name = url.lastPathComponent
        self.fileSizeString = RadialMenuConfiguration.formattedFileSize(for: url)

        // Read pixel dimensions efficiently via ImageIO without decoding full bitmap
        var size = CGSize(width: 1200, height: 800)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? CGFloat ?? 1200
            let h = props[kCGImagePropertyPixelHeight] as? CGFloat ?? 800
            size = CGSize(width: w, height: h)
        }
        self.originalPixelSize = size
    }

    public var rotatedPixelSize: CGSize {
        let isSwapped = (rotationDegrees == 90 || rotationDegrees == 270)
        return isSwapped ? CGSize(width: originalPixelSize.height, height: originalPixelSize.width) : originalPixelSize
    }

    public var croppedPixelSize: CGSize {
        let base = rotatedPixelSize
        return CGSize(
            width: max(1, round(base.width * normalizedCrop.width)),
            height: max(1, round(base.height * normalizedCrop.height))
        )
    }

    public var isEdited: Bool {
        rotationDegrees != 0 || isFlippedHorizontal || isFlippedVertical ||
        normalizedCrop != CGRect(x: 0, y: 0, width: 1, height: 1) ||
        brightness != 0.0 || contrast != 1.0 || saturation != 1.0 || filter != .none
    }

    public mutating func resetEdits() {
        rotationDegrees = 0
        isFlippedHorizontal = false
        isFlippedVertical = false
        normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropPreset = .free
        brightness = 0.0
        contrast = 1.0
        saturation = 1.0
        filter = .none
    }

    public mutating func resetCrop() {
        normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropPreset = .free
    }
}

// MARK: - 2. Photo PDF Processing Engine

public final class PhotoPDFEngine: @unchecked Sendable {
    public static let shared = PhotoPDFEngine()

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: true
    ])

    private init() {}

    /// Loads downsampled or full CGImage respecting EXIF orientation.
    public func loadSourceCGImage(from url: URL, maxDimension: CGFloat? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let maxDim = maxDimension {
            opts[kCGImageSourceThumbnailMaxPixelSize] = max(Int(maxDim), 1)
        } else {
            // Read natural dimensions
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 2000
                let h = props[kCGImagePropertyPixelHeight] as? Int ?? 2000
                opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h, 1)
            }
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Processes a photo item through its complete transformation pipeline:
    /// Rotation/Flip -> Crop -> Adjustments & Filters.
    public func renderProcessedImage(item: PhotoPageItem, maxDimension: CGFloat? = nil) -> CGImage? {
        guard let baseCG = loadSourceCGImage(from: item.sourceURL, maxDimension: maxDimension) else {
            return nil
        }

        var ci = CIImage(cgImage: baseCG)

        // 1. Rotation
        let normRotation = ((item.rotationDegrees % 360) + 360) % 360
        switch normRotation {
        case 90:
            ci = ci.oriented(.right)
        case 180:
            ci = ci.oriented(.down)
        case 270:
            ci = ci.oriented(.left)
        default:
            ci = ci.oriented(.up)
        }

        // 2. Flips
        if item.isFlippedHorizontal || item.isFlippedVertical {
            let scaleX: CGFloat = item.isFlippedHorizontal ? -1.0 : 1.0
            let scaleY: CGFloat = item.isFlippedVertical ? -1.0 : 1.0
            let extent = ci.extent
            let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
                .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
            ci = ci.transformed(by: transform)
        }

        // Normalize extent to origin (0, 0)
        let currentExtent = ci.extent
        if currentExtent.origin.x != 0 || currentExtent.origin.y != 0 {
            ci = ci.transformed(by: CGAffineTransform(translationX: -currentExtent.origin.x, y: -currentExtent.origin.y))
        }

        // 3. Normalized Cropping
        let totalW = ci.extent.width
        let totalH = ci.extent.height
        let crop = item.normalizedCrop
        if crop != CGRect(x: 0, y: 0, width: 1, height: 1) && totalW > 0 && totalH > 0 {
            // Note: In CoreImage extent, Y=0 is bottom
            let cropX = max(0, min(totalW, crop.minX * totalW))
            let cropY = max(0, min(totalH, (1.0 - crop.maxY) * totalH))
            let cropW = max(1, min(totalW - cropX, crop.width * totalW))
            let cropH = max(1, min(totalH - cropY, crop.height * totalH))
            let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            ci = ci.cropped(to: cropRect)
            ci = ci.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        }

        // 4. Filters & Adjustments
        switch item.filter {
        case .none:
            break

        case .scanDoc:
            // High-contrast clean paper scan enhancer
            if let mono = CIFilter(name: "CIColorMonochrome") {
                mono.setValue(ci, forKey: kCIInputImageKey)
                mono.setValue(CIColor(red: 0, green: 0, blue: 0), forKey: kCIInputColorKey)
                mono.setValue(1.0, forKey: kCIInputIntensityKey)
                if let monoOut = mono.outputImage { ci = monoOut }
            }
            if let controls = CIFilter(name: "CIColorControls") {
                controls.setValue(ci, forKey: kCIInputImageKey)
                controls.setValue(0.18, forKey: kCIInputBrightnessKey)
                controls.setValue(1.85, forKey: kCIInputContrastKey)
                controls.setValue(0.0, forKey: kCIInputSaturationKey)
                if let out = controls.outputImage { ci = out }
            }
            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(ci, forKey: kCIInputImageKey)
                sharpen.setValue(0.65, forKey: kCIInputSharpnessKey)
                if let out = sharpen.outputImage { ci = out }
            }

        case .grayscale:
            if let mono = CIFilter(name: "CIPhotoEffectMono") {
                mono.setValue(ci, forKey: kCIInputImageKey)
                if let out = mono.outputImage { ci = out }
            }

        case .sepia:
            if let sepia = CIFilter(name: "CISepiaTone") {
                sepia.setValue(ci, forKey: kCIInputImageKey)
                sepia.setValue(0.85, forKey: kCIInputIntensityKey)
                if let out = sepia.outputImage { ci = out }
            }

        case .vivid:
            if let controls = CIFilter(name: "CIColorControls") {
                controls.setValue(ci, forKey: kCIInputImageKey)
                controls.setValue(0.02, forKey: kCIInputBrightnessKey)
                controls.setValue(1.22, forKey: kCIInputContrastKey)
                controls.setValue(1.45, forKey: kCIInputSaturationKey)
                if let out = controls.outputImage { ci = out }
            }

        case .warm:
            if let temp = CIFilter(name: "CITemperatureAndTint") {
                temp.setValue(ci, forKey: kCIInputImageKey)
                temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                temp.setValue(CIVector(x: 7600, y: 15), forKey: "inputTargetNeutral")
                if let out = temp.outputImage { ci = out }
            }

        case .cool:
            if let temp = CIFilter(name: "CITemperatureAndTint") {
                temp.setValue(ci, forKey: kCIInputImageKey)
                temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                temp.setValue(CIVector(x: 5100, y: -10), forKey: "inputTargetNeutral")
                if let out = temp.outputImage { ci = out }
            }

        case .invert:
            if let invert = CIFilter(name: "CIColorInvert") {
                invert.setValue(ci, forKey: kCIInputImageKey)
                if let out = invert.outputImage { ci = out }
            }
        }

        // Custom user slider adjustments
        if item.brightness != 0.0 || item.contrast != 1.0 || item.saturation != 1.0 {
            if let controls = CIFilter(name: "CIColorControls") {
                controls.setValue(ci, forKey: kCIInputImageKey)
                controls.setValue(item.brightness, forKey: kCIInputBrightnessKey)
                controls.setValue(item.contrast, forKey: kCIInputContrastKey)
                controls.setValue(item.saturation, forKey: kCIInputSaturationKey)
                if let out = controls.outputImage { ci = out }
            }
        }

        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Renders a thumbnail NSImage for the page sidebar.
    public func renderThumbnail(for item: PhotoPageItem) -> NSImage? {
        guard let cg = renderProcessedImage(item: item, maxDimension: 260) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Compiles all photo page items into a cohesive PDF document.
    public func compilePDF(
        items: [PhotoPageItem],
        pageSize: PDFPageSizeOption,
        margin: PDFMarginOption,
        quality: PDFQualityOption,
        title: String?,
        destinationURL: URL,
        progress: @escaping (Int, Int) -> Void
    ) throws -> URL {
        guard !items.isEmpty else {
            throw ConversionError.exportFailed("No photos provided for PDF generation")
        }

        let pdfDoc = PDFDocument()
        let total = items.count

        for (index, item) in items.enumerated() {
            try autoreleasepool {
                guard let cgImage = renderProcessedImage(item: item, maxDimension: nil) else {
                    throw ConversionError.exportFailed("Failed to render page \(index + 1) (\(item.name))")
                }

                let page: PDFPage
                let imgW = CGFloat(cgImage.width)
                let imgH = CGFloat(cgImage.height)

                if let standardSize = pageSize.pointsSize {
                    // Standard paper sizes (A4, US Letter, Square)
                    // Determine page orientation: match photo aspect ratio if portrait vs landscape
                    var targetWidth = standardSize.width
                    var targetHeight = standardSize.height

                    if standardSize.width != standardSize.height {
                        let isPhotoLandscape = imgW > imgH
                        let isPageLandscape = targetWidth > targetHeight
                        if isPhotoLandscape != isPageLandscape {
                            swap(&targetWidth, &targetHeight)
                        }
                    }

                    let pageBounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
                    let inset = margin.insetPoints
                    let drawableRect = pageBounds.insetBy(dx: inset, dy: inset)

                    // Calculate aspect-fit frame for the image
                    let scale = min(drawableRect.width / max(imgW, 1), drawableRect.height / max(imgH, 1))
                    let drawW = imgW * scale
                    let drawH = imgH * scale
                    let drawX = drawableRect.minX + (drawableRect.width - drawW) / 2.0
                    let drawY = drawableRect.minY + (drawableRect.height - drawH) / 2.0
                    let imageDrawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)

                    // Draw into high-res bitmap
                    let dpiScale: CGFloat = 2.0 // Crisp retina output
                    let bitW = Int(round(targetWidth * dpiScale))
                    let bitH = Int(round(targetHeight * dpiScale))
                    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

                    guard let ctx = CGContext(
                        data: nil,
                        width: bitW,
                        height: bitH,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else {
                        throw ConversionError.exportFailed("Failed to create page canvas for \(item.name)")
                    }

                    // Fill crisp white background
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: bitW, height: bitH))

                    ctx.scaleBy(x: dpiScale, y: dpiScale)
                    ctx.draw(cgImage, in: imageDrawRect)

                    guard let compositeCG = ctx.makeImage() else {
                        throw ConversionError.exportFailed("Failed to extract page bitmap for \(item.name)")
                    }

                    let nsImage = NSImage(cgImage: compositeCG, size: NSSize(width: targetWidth, height: targetHeight))
                    guard let createdPage = PDFPage(image: nsImage) else {
                        throw ConversionError.exportFailed("Could not instantiate PDFPage for \(item.name)")
                    }
                    page = createdPage
                } else {
                    // Match Photo Size: Native resolution at standard 72 DPI points
                    let pointsW = max(72.0, (imgW * 72.0) / 150.0)
                    let pointsH = max(72.0, (imgH * 72.0) / 150.0)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: pointsW, height: pointsH))
                    guard let createdPage = PDFPage(image: nsImage) else {
                        throw ConversionError.exportFailed("Could not instantiate PDFPage for \(item.name)")
                    }
                    page = createdPage
                }

                pdfDoc.insert(page, at: index)
                progress(index + 1, total)
            }
        }

        // Set metadata
        var docAttributes: [PDFDocumentAttribute: Any] = [
            .creatorAttribute: "OpenTangerine PDF Studio",
            .producerAttribute: "OpenTangerine",
            .creationDateAttribute: Date()
        ]
        if let t = title, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            docAttributes[.titleAttribute] = t
        }
        pdfDoc.documentAttributes = docAttributes

        guard pdfDoc.write(to: destinationURL) else {
            throw ConversionError.exportFailed("Could not write PDF to \(destinationURL.lastPathComponent)")
        }

        return destinationURL
    }
}

// MARK: - 3. Interactive Photo to PDF Studio View

public struct PhotoPDFStudioView: View {
    public let sourceURLs: [URL]
    public var onExportComplete: (URL, Int) -> Void
    public var onClose: () -> Void

    @State private var pages: [PhotoPageItem] = []
    @State private var selectedPageID: UUID?
    @State private var isCropMode: Bool = false

    // Interactive Crop Box State
    @State private var dragHandle: CropDragHandle? = nil
    @State private var dragStartRect: CGRect? = nil

    // Canvas Preview Cache
    @State private var previewImage: NSImage?
    @State private var thumbnails: [UUID: NSImage] = [:]

    // PDF Configuration Options
    @State private var pdfFileName: String = "Combined_Photos"
    @State private var pageSizeOption: PDFPageSizeOption = .matchImage
    @State private var marginOption: PDFMarginOption = .none
    @State private var qualityOption: PDFQualityOption = .maximum
    @State private var activeTab: StudioInspectorTab = .edits

    // Export State
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStatusMessage: String = ""
    @State private var errorMessage: String?

    @ObservedObject private var theme = ThemeManager.shared

    private enum CropDragHandle {
        case move
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    private enum StudioInspectorTab: String, CaseIterable, Identifiable {
        case edits = "Page Edit"
        case pdf = "PDF Settings"
        public var id: String { rawValue }
    }

    public init(
        sourceURLs: [URL],
        onExportComplete: @escaping (URL, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.sourceURLs = sourceURLs
        self.onExportComplete = onExportComplete
        self.onClose = onClose
    }

    private var selectedIndex: Int? {
        pages.firstIndex(where: { $0.id == selectedPageID })
    }

    private var currentPage: PhotoPageItem? {
        guard let idx = selectedIndex, idx < pages.count else { return nil }
        return pages[idx]
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header Bar
                headerBar

                // Studio Workspace: 3-column split layout
                HStack(spacing: 0) {
                    // 1. Left Thumbnail Strip & Order Manager
                    pageOrderSidebar
                        .frame(width: 230)

                    Divider().background(Color.white.opacity(0.12))

                    // 2. Center Live Canvas & Crop Stage
                    centerCanvasStage

                    Divider().background(Color.white.opacity(0.12))

                    // 3. Right Inspector (Edits & Document Settings)
                    inspectorSidebar
                        .frame(width: 270)
                }

                Divider().background(Color.white.opacity(0.12))

                // Bottom Action & Export Bar
                bottomActionBar
            }

            // Exporting Modal Overlay
            if isExporting {
                exportingModalOverlay
            }

            // Error Alert Toast
            if let err = errorMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(err).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Dismiss") { errorMessage = nil }
                            .buttonStyle(.plain)
                            .foregroundColor(theme.accent)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.5), lineWidth: 1))
                    .padding(24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(LiquidWindowBackground(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onExitCommand(perform: onClose)
        .onAppear {
            initializeStudio()
        }
        .onDisappear {
            thumbnails.removeAll()
            previewImage = nil
            MemoryOptimizer.reclaimMemory()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext.fill")
                    .foregroundColor(theme.accent)
                    .font(.system(size: 16, weight: .bold))
                Text("PDF Photo Studio")
                    .font(.system(size: 14, weight: .bold))

                Text("•")
                    .foregroundColor(.secondary)

                Text("\(pages.count) Pages")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.18)))
                    .foregroundColor(theme.accent)

                if let idx = selectedIndex {
                    Text("Page \(idx + 1) of \(pages.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(WindowDragHandle())
    }

    // MARK: - Left Sidebar: Page Ordering & Thumbnails

    private var pageOrderSidebar: some View {
        VStack(spacing: 0) {
            // Sidebar Header & Reorder Controls
            HStack(spacing: 6) {
                Text("PAGES")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.secondary)

                Spacer()

                // Move Up
                Button(action: moveSelectedPageUp) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == nil || selectedIndex == 0)
                .help("Move page up in PDF")

                // Move Down
                Button(action: moveSelectedPageDown) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == nil || selectedIndex == pages.count - 1)
                .help("Move page down in PDF")

                // Reverse Order
                Button(action: reversePageOrder) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(pages.count <= 1)
                .help("Reverse overall page order")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))

            Divider().background(Color.white.opacity(0.08))

            // Scrollable list of page cards
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                        pageCardView(item: item, index: index)
                    }
                }
                .padding(10)
            }

            Divider().background(Color.white.opacity(0.08))

            // Bottom Add Photos & Sort Controls
            HStack(spacing: 8) {
                Button(action: pickAndAddMorePhotos) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add Photos…")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Sort by Name (A-Z)") { sortPagesByName() }
                    Button("Sort by File Size") { sortPagesBySize() }
                    Button("Reverse Order") { reversePageOrder() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                }
                .menuStyle(.borderlessButton)
            }
            .padding(10)
        }
        .background(Color.black.opacity(0.08))
    }

    @ViewBuilder
    private func pageCardView(item: PhotoPageItem, index: Int) -> some View {
        let isSelected = item.id == selectedPageID

        HStack(spacing: 8) {
            // Page Number Badge
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isSelected ? theme.accent : Color.primary.opacity(0.12)))

            // Thumbnail Preview
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.2))
                    .frame(width: 52, height: 52)

                if let thumb = thumbnails[item.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    ProgressView().scaleEffect(0.5)
                }
            }

            // Info & Micro badges
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text("\(Int(item.croppedPixelSize.width))×\(Int(item.croppedPixelSize.height))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    if item.rotationDegrees != 0 {
                        Text("\(item.rotationDegrees)°")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.25)))
                            .foregroundColor(.blue)
                    }

                    if item.filter != .none {
                        Text(item.filter.rawValue)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.purple.opacity(0.25)))
                            .foregroundColor(.purple)
                    }
                }
            }

            Spacer()

            // Quick Delete Button
            Button {
                deletePage(item: item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove photo from PDF")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.accent.opacity(0.18) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectPage(item.id)
        }
    }

    // MARK: - Center Stage: Live Canvas & Interactive Crop

    private var centerCanvasStage: some View {
        VStack(spacing: 0) {
            // Stage Top Toolbar
            stageTopToolbar

            // Canvas Area
            GeometryReader { geo in
                ZStack {
                    // Subtle background
                    Color.black.opacity(0.15)

                    if let img = previewImage, let page = currentPage {
                        let availableW = max(geo.size.width - 40, 100)
                        let availableH = max(geo.size.height - 40, 100)

                        if isCropMode {
                            // CROP MODE: Shows uncropped (but rotated) base image with interactive crop rectangle
                            cropEditorCanvas(page: page, availableSize: CGSize(width: availableW, height: availableH))
                        } else {
                            // PREVIEW MODE: Displays final cropped & enhanced page
                            VStack(spacing: 12) {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: availableW, maxHeight: availableH)
                                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Rendering photo preview…")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Canvas Bottom Status Pill
            if let page = currentPage {
                HStack(spacing: 12) {
                    Text("\(Int(page.croppedPixelSize.width)) × \(Int(page.croppedPixelSize.height)) px")
                        .font(.system(size: 11, weight: .semibold))

                    if page.rotationDegrees != 0 {
                        Text("• Rotated \(page.rotationDegrees)°")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if page.filter != .none {
                        Text("• \(page.filter.rawValue)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isCropMode {
                        Text("Drag edges or corners to adjust crop")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accent)
                    } else {
                        Text("Click ✂️ Crop to adjust crop box")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
            }
        }
    }

    private var stageTopToolbar: some View {
        HStack(spacing: 8) {
            // Previous / Next Page Buttons
            HStack(spacing: 2) {
                Button(action: selectPreviousPage) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == nil || selectedIndex == 0)

                Button(action: selectNextPage) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == nil || selectedIndex == pages.count - 1)
            }

            Divider().frame(height: 18)

            // Rotation & Flip Buttons
            HStack(spacing: 4) {
                Button(action: rotateCurrentLeft) {
                    HStack(spacing: 3) {
                        Image(systemName: "rotate.left.fill")
                        Text("90° Left")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Rotate 90° Counter-Clockwise")

                Button(action: rotateCurrentRight) {
                    HStack(spacing: 3) {
                        Image(systemName: "rotate.right.fill")
                        Text("90° Right")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Rotate 90° Clockwise")

                Button(action: flipCurrentHorizontal) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Flip Horizontal")

                Button(action: flipCurrentVertical) {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down.fill")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Flip Vertical")
            }

            Spacer()

            // Mode Selector: Preview vs Crop
            HStack(spacing: 2) {
                Button {
                    isCropMode = false
                    updatePreview()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                        Text("Preview")
                    }
                    .font(.system(size: 11, weight: !isCropMode ? .bold : .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(!isCropMode ? theme.accent : Color.clear))
                    .foregroundColor(!isCropMode ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
                }
                .buttonStyle(.plain)

                Button {
                    isCropMode = true
                    updatePreview()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "crop")
                        Text("Crop")
                    }
                    .font(.system(size: 11, weight: isCropMode ? .bold : .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isCropMode ? theme.accent : Color.clear))
                    .foregroundColor(isCropMode ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Crop Canvas with Handles

    @ViewBuilder
    private func cropEditorCanvas(page: PhotoPageItem, availableSize: CGSize) -> some View {
        let baseSize = page.rotatedPixelSize
        let scale = min(availableSize.width / max(baseSize.width, 1), availableSize.height / max(baseSize.height, 1))
        let frameW = baseSize.width * scale
        let frameH = baseSize.height * scale
        let frame = CGRect(x: (availableSize.width - frameW) / 2.0, y: (availableSize.height - frameH) / 2.0, width: frameW, height: frameH)

        let crop = page.normalizedCrop
        let cropRect = CGRect(
            x: frame.minX + crop.minX * frame.width,
            y: frame.minY + crop.minY * frame.height,
            width: max(10, crop.width * frame.width),
            height: max(10, crop.height * frame.height)
        )

        ZStack {
            // Base Image Display (Uncropped base)
            if let baseCG = PhotoPDFEngine.shared.loadSourceCGImage(from: page.sourceURL, maxDimension: 1200) {
                let rotNorm = ((page.rotationDegrees % 360) + 360) % 360
                let baseNS = NSImage(cgImage: baseCG, size: NSSize(width: baseCG.width, height: baseCG.height))
                Image(nsImage: baseNS)
                    .resizable()
                    .interpolation(.high)
                    .rotationEffect(.degrees(Double(rotNorm)))
                    .scaleEffect(x: page.isFlippedHorizontal ? -1 : 1, y: page.isFlippedVertical ? -1 : 1)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }

            // Dimmed mask outside crop box
            Group {
                // Top
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: frame.width, height: max(0, cropRect.minY - frame.minY))
                    .position(x: frame.midX, y: frame.minY + max(0, cropRect.minY - frame.minY) / 2.0)
                // Bottom
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: frame.width, height: max(0, frame.maxY - cropRect.maxY))
                    .position(x: frame.midX, y: cropRect.maxY + max(0, frame.maxY - cropRect.maxY) / 2.0)
                // Left
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(0, cropRect.minX - frame.minX), height: cropRect.height)
                    .position(x: frame.minX + max(0, cropRect.minX - frame.minX) / 2.0, y: cropRect.midY)
                // Right
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(0, frame.maxX - cropRect.maxX), height: cropRect.height)
                    .position(x: cropRect.maxX + max(0, frame.maxX - cropRect.maxX) / 2.0, y: cropRect.midY)
            }

            // Grid Lines (Rule of Thirds)
            Path { path in
                let cw = cropRect.width
                let ch = cropRect.height
                path.move(to: CGPoint(x: cropRect.minX + cw / 3.0, y: cropRect.minY))
                path.addLine(to: CGPoint(x: cropRect.minX + cw / 3.0, y: cropRect.maxY))
                path.move(to: CGPoint(x: cropRect.minX + 2.0 * cw / 3.0, y: cropRect.minY))
                path.addLine(to: CGPoint(x: cropRect.minX + 2.0 * cw / 3.0, y: cropRect.maxY))
                path.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + ch / 3.0))
                path.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + ch / 3.0))
                path.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + 2.0 * ch / 3.0))
                path.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + 2.0 * ch / 3.0))
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.8)

            // Crop Frame Stroke
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)

            // Interior Drag Area (Move crop window)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(1, cropRect.width - 24), height: max(1, cropRect.height - 24))
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { val in
                            handleCropDrag(handle: .move, translation: val.translation, frame: frame, preset: page.cropPreset)
                        }
                        .onEnded { _ in
                            dragStartRect = nil
                            updateThumbnailForCurrentPage()
                        }
                )

            // 4 Corner Handles
            cropCornerHandle(x: cropRect.minX, y: cropRect.minY, handle: .topLeft, frame: frame, preset: page.cropPreset)
            cropCornerHandle(x: cropRect.maxX, y: cropRect.minY, handle: .topRight, frame: frame, preset: page.cropPreset)
            cropCornerHandle(x: cropRect.minX, y: cropRect.maxY, handle: .bottomLeft, frame: frame, preset: page.cropPreset)
            cropCornerHandle(x: cropRect.maxX, y: cropRect.maxY, handle: .bottomRight, frame: frame, preset: page.cropPreset)

            // 4 Edge Handles
            cropEdgeHandle(x: cropRect.midX, y: cropRect.minY, width: 28, height: 6, handle: .top, frame: frame, preset: page.cropPreset)
            cropEdgeHandle(x: cropRect.midX, y: cropRect.maxY, width: 28, height: 6, handle: .bottom, frame: frame, preset: page.cropPreset)
            cropEdgeHandle(x: cropRect.minX, y: cropRect.midY, width: 6, height: 28, handle: .left, frame: frame, preset: page.cropPreset)
            cropEdgeHandle(x: cropRect.maxX, y: cropRect.midY, width: 6, height: 28, handle: .right, frame: frame, preset: page.cropPreset)
        }
    }

    @ViewBuilder
    private func cropCornerHandle(x: CGFloat, y: CGFloat, handle: CropDragHandle, frame: CGRect, preset: PhotoCropPreset) -> some View {
        ZStack {
            Color.clear.frame(width: 30, height: 30).contentShape(Rectangle())
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(theme.accent, lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 2)
        }
        .position(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    handleCropDrag(handle: handle, translation: val.translation, frame: frame, preset: preset)
                }
                .onEnded { _ in
                    dragStartRect = nil
                    updateThumbnailForCurrentPage()
                }
        )
    }

    @ViewBuilder
    private func cropEdgeHandle(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, handle: CropDragHandle, frame: CGRect, preset: PhotoCropPreset) -> some View {
        ZStack {
            Color.clear.frame(width: 32, height: 32).contentShape(Rectangle())
            Capsule()
                .fill(Color.white)
                .frame(width: width, height: height)
                .overlay(Capsule().stroke(theme.accent, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 2)
        }
        .position(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    handleCropDrag(handle: handle, translation: val.translation, frame: frame, preset: preset)
                }
                .onEnded { _ in
                    dragStartRect = nil
                    updateThumbnailForCurrentPage()
                }
        )
    }

    private func handleCropDrag(handle: CropDragHandle, translation: CGSize, frame: CGRect, preset: PhotoCropPreset) {
        guard let idx = selectedIndex, frame.width > 0, frame.height > 0 else { return }
        if dragStartRect == nil {
            dragStartRect = pages[idx].normalizedCrop
        }
        guard let start = dragStartRect else { return }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height

        var rect = start

        switch handle {
        case .move:
            let maxX = 1.0 - start.width
            let maxY = 1.0 - start.height
            rect.origin.x = max(0, min(maxX, start.minX + dx))
            rect.origin.y = max(0, min(maxY, start.minY + dy))

        case .topLeft:
            let newMinX = max(0, min(start.maxX - 0.05, start.minX + dx))
            let newMinY = max(0, min(start.maxY - 0.05, start.minY + dy))
            rect = CGRect(x: newMinX, y: newMinY, width: start.maxX - newMinX, height: start.maxY - newMinY)

        case .topRight:
            let newMaxX = min(1.0, max(start.minX + 0.05, start.maxX + dx))
            let newMinY = max(0, min(start.maxY - 0.05, start.minY + dy))
            rect = CGRect(x: start.minX, y: newMinY, width: newMaxX - start.minX, height: start.maxY - newMinY)

        case .bottomLeft:
            let newMinX = max(0, min(start.maxX - 0.05, start.minX + dx))
            let newMaxY = min(1.0, max(start.minY + 0.05, start.maxY + dy))
            rect = CGRect(x: newMinX, y: start.minY, width: start.maxX - newMinX, height: newMaxY - start.minY)

        case .bottomRight:
            let newMaxX = min(1.0, max(start.minX + 0.05, start.maxX + dx))
            let newMaxY = min(1.0, max(start.minY + 0.05, start.maxY + dy))
            rect = CGRect(x: start.minX, y: start.minY, width: newMaxX - start.minX, height: newMaxY - start.minY)

        case .top:
            let newMinY = max(0, min(start.maxY - 0.05, start.minY + dy))
            rect = CGRect(x: start.minX, y: newMinY, width: start.width, height: start.maxY - newMinY)

        case .bottom:
            let newMaxY = min(1.0, max(start.minY + 0.05, start.maxY + dy))
            rect = CGRect(x: start.minX, y: start.minY, width: start.width, height: newMaxY - start.minY)

        case .left:
            let newMinX = max(0, min(start.maxX - 0.05, start.minX + dx))
            rect = CGRect(x: newMinX, y: start.minY, width: start.maxX - newMinX, height: start.height)

        case .right:
            let newMaxX = min(1.0, max(start.minX + 0.05, start.maxX + dx))
            rect = CGRect(x: start.minX, y: start.minY, width: newMaxX - start.minX, height: start.height)
        }

        // Apply aspect ratio constraints if a preset is active
        if let targetAspect = preset.targetAspectRatio(for: pages[idx].rotatedPixelSize) {
            let currentAspect = (rect.width * frame.width) / max(rect.height * frame.height, 1)
            if currentAspect > targetAspect {
                // Too wide, adjust width
                let newW = (rect.height * frame.height * targetAspect) / frame.width
                rect.size.width = min(1.0 - rect.minX, newW)
            } else {
                // Too tall, adjust height
                let newH = (rect.width * frame.width / targetAspect) / frame.height
                rect.size.height = min(1.0 - rect.minY, newH)
            }
        }

        pages[idx].normalizedCrop = rect
    }

    // MARK: - Right Inspector: Edits & Document Settings

    private var inspectorSidebar: some View {
        VStack(spacing: 0) {
            // Inspector Tab Picker
            Picker("Inspector", selection: $activeTab) {
                ForEach(StudioInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if activeTab == .edits {
                        pageEditsInspectorContent
                    } else {
                        pdfSettingsInspectorContent
                    }
                }
                .padding(12)
            }
        }
        .background(Color.black.opacity(0.08))
    }

    // MARK: Tab 1: Page Edits

    @ViewBuilder
    private var pageEditsInspectorContent: some View {
        if let idx = selectedIndex, idx < pages.count {
            // Crop Presets Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CROP ASPECT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset Crop") {
                        pages[idx].resetCrop()
                        updatePreview()
                        updateThumbnailForCurrentPage()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(PhotoCropPreset.allCases) { preset in
                        Button {
                            applyCropPreset(preset, to: idx)
                        } label: {
                            Text(preset.rawValue)
                                .font(.system(size: 10, weight: pages[idx].cropPreset == preset ? .bold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(pages[idx].cropPreset == preset ? theme.accent.opacity(0.25) : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(pages[idx].cropPreset == preset ? theme.accent : Color.clear, lineWidth: 1)
                                )
                                .foregroundColor(pages[idx].cropPreset == preset ? theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.08))

            // Filters Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("FILTERS & ENHANCE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Apply to All") {
                        applyFilterToAllPages(filter: pages[idx].filter)
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .help("Apply this filter to all pages in the PDF")
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(PhotoFilter.allCases) { f in
                        Button {
                            pages[idx].filter = f
                            updatePreview()
                            updateThumbnailForCurrentPage()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: f.systemIcon)
                                Text(f.rawValue)
                            }
                            .font(.system(size: 10, weight: pages[idx].filter == f ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(pages[idx].filter == f ? theme.accent.opacity(0.25) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(pages[idx].filter == f ? theme.accent : Color.clear, lineWidth: 1)
                            )
                            .foregroundColor(pages[idx].filter == f ? theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.08))

            // Sliders: Brightness, Contrast, Saturation
            VStack(alignment: .leading, spacing: 10) {
                Text("ADJUSTMENTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                // Brightness
                VStack(spacing: 2) {
                    HStack {
                        Text("Brightness").font(.system(size: 11))
                        Spacer()
                        Text("\(Int(pages[idx].brightness * 100))%").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Slider(value: $pages[idx].brightness, in: -0.5...0.5) { _ in
                        updatePreview()
                        updateThumbnailForCurrentPage()
                    }
                }

                // Contrast
                VStack(spacing: 2) {
                    HStack {
                        Text("Contrast").font(.system(size: 11))
                        Spacer()
                        Text("\(Int(pages[idx].contrast * 100))%").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Slider(value: $pages[idx].contrast, in: 0.5...2.0) { _ in
                        updatePreview()
                        updateThumbnailForCurrentPage()
                    }
                }

                // Saturation
                VStack(spacing: 2) {
                    HStack {
                        Text("Saturation").font(.system(size: 11))
                        Spacer()
                        Text("\(Int(pages[idx].saturation * 100))%").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Slider(value: $pages[idx].saturation, in: 0.0...2.0) { _ in
                        updatePreview()
                        updateThumbnailForCurrentPage()
                    }
                }

                Button("Reset Adjustments") {
                    pages[idx].brightness = 0.0
                    pages[idx].contrast = 1.0
                    pages[idx].saturation = 1.0
                    pages[idx].filter = .none
                    updatePreview()
                    updateThumbnailForCurrentPage()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
                .padding(.top, 4)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("Select a page from the left sidebar to edit")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    // MARK: Tab 2: PDF Settings

    @ViewBuilder
    private var pdfSettingsInspectorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // PDF File Name
            VStack(alignment: .leading, spacing: 4) {
                Text("PDF DOCUMENT NAME")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                HStack {
                    TextField("PDF File Name", text: $pdfFileName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    Text(".pdf")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }

            Divider().background(Color.white.opacity(0.08))

            // Page Size Format
            VStack(alignment: .leading, spacing: 6) {
                Text("PAGE FORMAT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                ForEach(PDFPageSizeOption.allCases) { opt in
                    Button {
                        pageSizeOption = opt
                    } label: {
                        HStack {
                            Image(systemName: pageSizeOption == opt ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(pageSizeOption == opt ? theme.accent : .secondary)
                            Text(opt.rawValue)
                                .font(.system(size: 11, weight: pageSizeOption == opt ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(Color.white.opacity(0.08))

            // Margins (when standard paper size selected)
            if pageSizeOption != .matchImage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PAGE MARGINS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    ForEach(PDFMarginOption.allCases) { opt in
                        Button {
                            marginOption = opt
                        } label: {
                            HStack {
                                Image(systemName: marginOption == opt ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(marginOption == opt ? theme.accent : .secondary)
                                Text(opt.rawValue)
                                    .font(.system(size: 11, weight: marginOption == opt ? .semibold : .regular))
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().background(Color.white.opacity(0.08))
            }

            // Quality / Compression
            VStack(alignment: .leading, spacing: 6) {
                Text("EXPORT QUALITY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                ForEach(PDFQualityOption.allCases) { opt in
                    Button {
                        qualityOption = opt
                    } label: {
                        HStack {
                            Image(systemName: qualityOption == opt ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(qualityOption == opt ? theme.accent : .secondary)
                            Text(opt.rawValue)
                                .font(.system(size: 11, weight: qualityOption == opt ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // Summary Info
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Compiling \(pages.count) photos into \(pdfFileName).pdf • \(pageSizeOption.rawValue)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Cancel Button
            Button("Cancel") {
                onClose()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            // Export Button
            Button(action: startExportProcess) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill")
                    Text("Export PDF…")
                }
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
            }
            .buttonStyle(.plain)
            .disabled(pages.isEmpty || isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Exporting Modal Overlay

    private var exportingModalOverlay: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: exportProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .frame(width: 240)

                VStack(spacing: 4) {
                    Text("Generating PDF…")
                        .font(.system(size: 14, weight: .bold))
                    Text(exportStatusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
    }

    // MARK: - Logic & Actions

    private func initializeStudio() {
        let items = sourceURLs.map { PhotoPageItem(url: $0) }
        if items.isEmpty { return }

        // Set default output name based on first photo or count
        if items.count == 1 {
            pdfFileName = items[0].sourceURL.deletingPathExtension().lastPathComponent
        } else {
            pdfFileName = "Combined_\(items.count)_Photos"
        }

        pages = items
        selectedPageID = items[0].id

        // Render thumbnails in background
        renderAllThumbnails()
        updatePreview()
    }

    private func selectPage(_ id: UUID) {
        selectedPageID = id
        updatePreview()
    }

    private func selectPreviousPage() {
        guard let idx = selectedIndex, idx > 0 else { return }
        selectPage(pages[idx - 1].id)
    }

    private func selectNextPage() {
        guard let idx = selectedIndex, idx < pages.count - 1 else { return }
        selectPage(pages[idx + 1].id)
    }

    private func moveSelectedPageUp() {
        guard let idx = selectedIndex, idx > 0 else { return }
        pages.swapAt(idx, idx - 1)
    }

    private func moveSelectedPageDown() {
        guard let idx = selectedIndex, idx < pages.count - 1 else { return }
        pages.swapAt(idx, idx + 1)
    }

    private func reversePageOrder() {
        withAnimation {
            pages.reverse()
        }
    }

    private func sortPagesByName() {
        withAnimation {
            pages.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func sortPagesBySize() {
        withAnimation {
            pages.sort { $0.croppedPixelSize.width * $0.croppedPixelSize.height > $1.croppedPixelSize.width * $1.croppedPixelSize.height }
        }
    }

    private func deletePage(item: PhotoPageItem) {
        withAnimation {
            if let idx = pages.firstIndex(where: { $0.id == item.id }) {
                pages.remove(at: idx)
                thumbnails.removeValue(forKey: item.id)
                if selectedPageID == item.id {
                    selectedPageID = pages.first?.id
                    updatePreview()
                }
            }
        }
    }

    private func pickAndAddMorePhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose photos to add to this PDF"
        panel.prompt = "Add Photos"

        if panel.runModal() == .OK {
            let newItems = panel.urls.map { PhotoPageItem(url: $0) }
            pages.append(contentsOf: newItems)
            for item in newItems {
                Task.detached(priority: .userInitiated) {
                    if let thumb = PhotoPDFEngine.shared.renderThumbnail(for: item) {
                        await MainActor.run {
                            thumbnails[item.id] = thumb
                        }
                    }
                }
            }
            if selectedPageID == nil {
                selectedPageID = pages.first?.id
                updatePreview()
            }
        }
    }

    private func rotateCurrentLeft() {
        guard let idx = selectedIndex else { return }
        pages[idx].rotationDegrees = (pages[idx].rotationDegrees + 270) % 360
        updatePreview()
        updateThumbnailForCurrentPage()
    }

    private func rotateCurrentRight() {
        guard let idx = selectedIndex else { return }
        pages[idx].rotationDegrees = (pages[idx].rotationDegrees + 90) % 360
        updatePreview()
        updateThumbnailForCurrentPage()
    }

    private func flipCurrentHorizontal() {
        guard let idx = selectedIndex else { return }
        pages[idx].isFlippedHorizontal.toggle()
        updatePreview()
        updateThumbnailForCurrentPage()
    }

    private func flipCurrentVertical() {
        guard let idx = selectedIndex else { return }
        pages[idx].isFlippedVertical.toggle()
        updatePreview()
        updateThumbnailForCurrentPage()
    }

    private func applyCropPreset(_ preset: PhotoCropPreset, to idx: Int) {
        pages[idx].cropPreset = preset
        if let targetAspect = preset.targetAspectRatio(for: pages[idx].rotatedPixelSize) {
            let baseW = pages[idx].rotatedPixelSize.width
            let baseH = pages[idx].rotatedPixelSize.height
            let currentAspect = baseW / max(baseH, 1)

            var normW: CGFloat = 1.0
            var normH: CGFloat = 1.0

            if currentAspect > targetAspect {
                normW = (baseH * targetAspect) / baseW
            } else {
                normH = (baseW / targetAspect) / baseH
            }
            let x = (1.0 - normW) / 2.0
            let y = (1.0 - normH) / 2.0
            pages[idx].normalizedCrop = CGRect(x: max(0, x), y: max(0, y), width: min(1, normW), height: min(1, normH))
        } else {
            pages[idx].normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        updatePreview()
        updateThumbnailForCurrentPage()
    }

    private func applyFilterToAllPages(filter: PhotoFilter) {
        for i in 0..<pages.count {
            pages[i].filter = filter
        }
        renderAllThumbnails()
        updatePreview()
    }

    private func renderAllThumbnails() {
        for page in pages {
            Task.detached(priority: .userInitiated) {
                if let thumb = PhotoPDFEngine.shared.renderThumbnail(for: page) {
                    await MainActor.run {
                        thumbnails[page.id] = thumb
                    }
                }
            }
        }
    }

    private func updateThumbnailForCurrentPage() {
        guard let page = currentPage else { return }
        Task.detached(priority: .userInitiated) {
            if let thumb = PhotoPDFEngine.shared.renderThumbnail(for: page) {
                await MainActor.run {
                    thumbnails[page.id] = thumb
                }
            }
        }
    }

    private func updatePreview() {
        guard let page = currentPage else {
            previewImage = nil
            return
        }
        let cropMode = isCropMode
        Task.detached(priority: .userInitiated) {
            // In crop mode, render rotated base image for crop overlay; in preview mode, render full edited image
            let maxDim: CGFloat = 1400
            let renderedCG: CGImage?
            if cropMode {
                var uncropped = page
                uncropped.normalizedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
                renderedCG = PhotoPDFEngine.shared.renderProcessedImage(item: uncropped, maxDimension: maxDim)
            } else {
                renderedCG = PhotoPDFEngine.shared.renderProcessedImage(item: page, maxDimension: maxDim)
            }

            if let cg = renderedCG {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run {
                    previewImage = img
                }
            }
        }
    }

    private func startExportProcess() {
        guard !pages.isEmpty else { return }

        // Choose destination URL via NSSavePanel
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.pdf]
        let cleanName = pdfFileName.trimmingCharacters(in: .whitespaces).isEmpty ? "Combined_Photos" : pdfFileName
        savePanel.nameFieldStringValue = cleanName.hasSuffix(".pdf") ? cleanName : "\(cleanName).pdf"

        if let first = sourceURLs.first {
            savePanel.directoryURL = first.deletingLastPathComponent()
        }

        savePanel.prompt = "Save PDF"
        savePanel.message = "Choose destination for your combined PDF"

        if savePanel.runModal() == .OK, let outputURL = savePanel.url {
            isExporting = true
            exportProgress = 0.0
            exportStatusMessage = "Starting PDF export…"

            let exportPages = pages
            let pageSize = pageSizeOption
            let margin = marginOption
            let quality = qualityOption
            let title = cleanName

            Task.detached(priority: .userInitiated) {
                do {
                    let outURL = try PhotoPDFEngine.shared.compilePDF(
                        items: exportPages,
                        pageSize: pageSize,
                        margin: margin,
                        quality: quality,
                        title: title,
                        destinationURL: outputURL,
                        progress: { current, total in
                            Task { @MainActor in
                                exportProgress = Double(current) / Double(max(total, 1))
                                exportStatusMessage = "Rendering page \(current) of \(total)…"
                            }
                        }
                    )

                    await MainActor.run {
                        isExporting = false
                        onExportComplete(outURL, exportPages.count)
                    }
                } catch {
                    await MainActor.run {
                        isExporting = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

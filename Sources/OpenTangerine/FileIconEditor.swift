//
//  FileIconEditor.swift
//  OpenTangerine
//
//  Created for OpenTangerine.
//  Provides interactive picture cropping, custom icon editing for videos, images, and folders,
//  and system-level Finder icon synchronization.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

// MARK: - File Icon Service

public enum FileIconService {

    /// Sets the macOS Finder custom icon for any file or folder.
    /// Also optionally propagates the icon to immediate child items or media files inside folders.
    @discardableResult
    public static func setIcon(
        image: NSImage?,
        for url: URL,
        propagateToChildren: Bool = false
    ) -> Bool {
        let path = url.path
        let success = NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        NSWorkspace.shared.noteFileSystemChanged(path)

        if propagateToChildren && FolderTools.isFolder(url) {
            propagateIconToFolderItems(image: image, folderURL: url)
        }

        DispatchQueue.main.async {
            MemoryOptimizer.reclaimMemory()
        }

        return success
    }

    /// Removes any custom Finder icon on the target file or folder, restoring the system default.
    @discardableResult
    public static func removeCustomIcon(for url: URL) -> Bool {
        let path = url.path
        let success = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        NSWorkspace.shared.noteFileSystemChanged(path)

        DispatchQueue.main.async {
            MemoryOptimizer.reclaimMemory()
        }

        return success
    }

    /// Propagates an icon to all files or audio/video tracks inside a directory.
    private static func propagateIconToFolderItems(image: NSImage?, folderURL: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let mediaExts = Set(["mp3", "m4a", "flac", "wav", "aac", "ogg", "aiff", "alac", "mp4", "mov", "mkv", "avi", "webm"])

        while let fileURL = enumerator.nextObject() as? URL {
            if mediaExts.contains(fileURL.pathExtension.lowercased()) {
                NSWorkspace.shared.setIcon(image, forFile: fileURL.path, options: [])
                NSWorkspace.shared.noteFileSystemChanged(fileURL.path)
            }
        }
    }

    /// Retrieves the current icon for the file or folder.
    public static func getIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Checks if the file or folder has a custom Finder icon set.
    public static func hasCustomIcon(for url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.customIconKey]),
              values.customIcon != nil else {
            return false
        }
        return true
    }

    /// Gets the custom Finder icon for the file or folder, if one is set.
    public static func getCustomIcon(for url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(forKeys: [.customIconKey]),
              let icon = values.customIcon else {
            return nil
        }
        return icon
    }

    /// Loads an image efficiently with downsampling to conserve RAM.
    public static func loadDownsampledImage(from url: URL, maxPixelSize: CGFloat = 1200) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(contentsOf: url)
    }

    /// Loads an image from data efficiently with downsampling.
    public static func loadDownsampledImage(from data: Data, maxPixelSize: CGFloat = 1200) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return NSImage(data: data)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(data: data)
    }

    /// Crops an NSImage according to a normalized bounding box [0..1] and returns a new NSImage.
    public static func cropImage(_ image: NSImage, normalizedCrop: CGRect) -> NSImage? {
        autoreleasepool {
            var proposedRect = CGRect(origin: .zero, size: image.size)
            if let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                return cropCGImage(cg, normalizedCrop: normalizedCrop)
            }
            // Draw into an offscreen CGContext to guarantee a valid CGImage representation
            let w = max(1, Int(image.size.width))
            let h = max(1, Int(image.size.height))
            if let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsCtx
                image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                if let cg = ctx.makeImage() {
                    return cropCGImage(cg, normalizedCrop: normalizedCrop)
                }
            }
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let fallbackCG = rep.cgImage {
                return cropCGImage(fallbackCG, normalizedCrop: normalizedCrop)
            }
            return nil
        }
    }

    private static func cropCGImage(_ cg: CGImage, normalizedCrop: CGRect) -> NSImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let x = max(0, min(w, round(normalizedCrop.minX * w)))
        let y = max(0, min(h, round(normalizedCrop.minY * h)))
        let cropW = max(1, min(w - x, round(normalizedCrop.width * w)))
        let cropH = max(1, min(h - y, round(normalizedCrop.height * h)))

        let rect = CGRect(x: x, y: y, width: cropW, height: cropH)
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropW, height: cropH))
    }
}

// MARK: - Interactive Image Crop Modal View

public struct ImageCropModalView: View {
    public let image: NSImage
    public var onApply: (NSImage) -> Void
    public var onCancel: () -> Void

    @State private var naturalPixelSize: CGSize = CGSize(width: 512, height: 512)
    @State private var normalizedCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var selectedPreset: CropAspectPreset = .square
    @State private var showSquircleGuide: Bool = true
    @State private var widthInput: String = "512"
    @State private var heightInput: String = "512"
    @State private var dragStartRect: CGRect? = nil

    @ObservedObject private var theme = ThemeManager.shared

    private enum DragHandle {
        case move
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    public init(
        image: NSImage,
        onApply: @escaping (NSImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.image = image
        self.onApply = onApply
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            // Dark dimming backdrop
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { /* Prevent clicks leaking */ }

            // Modal Card
            VStack(spacing: 0) {
                // Header Bar
                ZStack {
                    HStack(spacing: 6) {
                        Image(systemName: "crop")
                            .foregroundColor(theme.accent)
                        Text("Crop & Edit Picture")
                            .font(.system(size: 13, weight: .bold))
                    }

                    HStack {
                        Button(action: {
                            onCancel()
                            DispatchQueue.main.async { MemoryOptimizer.reclaimMemory() }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Toggle(isOn: $showSquircleGuide) {
                            HStack(spacing: 4) {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 10))
                                Text("macOS Squircle Mask")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.04))

                Divider().opacity(0.3)

                // Interactive Crop Canvas
                GeometryReader { geo in
                    let availableW = max(100, geo.size.width - 32)
                    let availableH = max(100, geo.size.height - 24)
                    let scale = min(availableW / max(naturalPixelSize.width, 1),
                                    availableH / max(naturalPixelSize.height, 1))
                    let frameW = naturalPixelSize.width * scale
                    let frameH = naturalPixelSize.height * scale
                    let frame = CGRect(
                        x: (geo.size.width - frameW) / 2,
                        y: (geo.size.height - frameH) / 2,
                        width: frameW,
                        height: frameH
                    )
                    let cropRect = CGRect(
                        x: frame.minX + normalizedCrop.minX * frame.width,
                        y: frame.minY + normalizedCrop.minY * frame.height,
                        width: normalizedCrop.width * frame.width,
                        height: normalizedCrop.height * frame.height
                    )

                    ZStack {
                        // Base Image
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frameW, height: frameH)
                            .position(x: frame.midX, y: frame.midY)

                        // Outer Dimmed Mask (4 outer rectangles)
                        Group {
                            // Top
                            Rectangle().fill(Color.black.opacity(0.55))
                                .frame(width: frame.width, height: max(0, cropRect.minY - frame.minY))
                                .position(x: frame.midX, y: frame.minY + max(0, cropRect.minY - frame.minY) / 2)
                            // Bottom
                            Rectangle().fill(Color.black.opacity(0.55))
                                .frame(width: frame.width, height: max(0, frame.maxY - cropRect.maxY))
                                .position(x: frame.midX, y: cropRect.maxY + max(0, frame.maxY - cropRect.maxY) / 2)
                            // Left
                            Rectangle().fill(Color.black.opacity(0.55))
                                .frame(width: max(0, cropRect.minX - frame.minX), height: cropRect.height)
                                .position(x: frame.minX + max(0, cropRect.minX - frame.minX) / 2, y: cropRect.midY)
                            // Right
                            Rectangle().fill(Color.black.opacity(0.55))
                                .frame(width: max(0, frame.maxX - cropRect.maxX), height: cropRect.height)
                                .position(x: cropRect.maxX + max(0, frame.maxX - cropRect.maxX) / 2, y: cropRect.midY)
                        }

                        // Squircle Guide (Finder preview)
                        if showSquircleGuide {
                            RoundedRectangle(cornerRadius: cropRect.width * 0.225, style: .continuous)
                                .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                .frame(width: cropRect.width, height: cropRect.height)
                                .position(x: cropRect.midX, y: cropRect.midY)
                        }

                        // Active Crop Border
                        Rectangle()
                            .stroke(theme.accent, lineWidth: 2)
                            .frame(width: cropRect.width, height: cropRect.height)
                            .position(x: cropRect.midX, y: cropRect.midY)

                        // Rule of Thirds Grid
                        Group {
                            Path { p in
                                p.move(to: CGPoint(x: cropRect.minX + cropRect.width / 3, y: cropRect.minY))
                                p.addLine(to: CGPoint(x: cropRect.minX + cropRect.width / 3, y: cropRect.maxY))
                                p.move(to: CGPoint(x: cropRect.minX + 2 * cropRect.width / 3, y: cropRect.minY))
                                p.addLine(to: CGPoint(x: cropRect.minX + 2 * cropRect.width / 3, y: cropRect.maxY))
                                p.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + cropRect.height / 3))
                                p.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + cropRect.height / 3))
                                p.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + 2 * cropRect.height / 3))
                                p.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + 2 * cropRect.height / 3))
                            }
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                        }

                        // Move Gesture Area
                        Color.white.opacity(0.001)
                            .frame(width: max(20, cropRect.width - 32), height: max(20, cropRect.height - 32))
                            .position(x: cropRect.midX, y: cropRect.midY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .move, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )

                        // Corner Handles
                        handleCircle()
                            .position(x: cropRect.minX, y: cropRect.minY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .topLeft, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                        handleCircle()
                            .position(x: cropRect.maxX, y: cropRect.minY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .topRight, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                        handleCircle()
                            .position(x: cropRect.minX, y: cropRect.maxY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .bottomLeft, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                        handleCircle()
                            .position(x: cropRect.maxX, y: cropRect.maxY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .bottomRight, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )

                        // Edge Handles
                        handleCapsule(width: 22, height: 6)
                            .position(x: cropRect.midX, y: cropRect.minY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .top, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                        handleCapsule(width: 22, height: 6)
                            .position(x: cropRect.midX, y: cropRect.maxY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .bottom, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                        handleCapsule(width: 6, height: 22)
                            .position(x: cropRect.minX, y: cropRect.midY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .left, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                        handleCapsule(width: 6, height: 22)
                            .position(x: cropRect.maxX, y: cropRect.midY)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in handleDrag(handle: .right, translation: v.translation, frame: frame) }
                                    .onEnded { _ in dragStartRect = nil; syncDimensions() }
                            )
                    }
                }
                .frame(minHeight: 280)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider().opacity(0.3)

                // Controls: Aspect Ratio Presets & Dimensions
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Ratio")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)

                        Button("1:1 (Icon)") { selectPreset(.square) }
                            .buttonStyle(PresetButtonStyle(isSelected: selectedPreset == .square))

                        Button("Free") { selectPreset(.free) }
                            .buttonStyle(PresetButtonStyle(isSelected: selectedPreset == .free))

                        Button("4:3") { selectPreset(.standard) }
                            .buttonStyle(PresetButtonStyle(isSelected: selectedPreset == .standard))

                        Button("16:9") { selectPreset(.widescreen) }
                            .buttonStyle(PresetButtonStyle(isSelected: selectedPreset == .widescreen))

                        Button("3:2") { selectPreset(.photo32) }
                            .buttonStyle(PresetButtonStyle(isSelected: selectedPreset == .photo32))

                        Spacer()

                        Text("\(Int(round(normalizedCrop.width * naturalPixelSize.width))) × \(Int(round(normalizedCrop.height * naturalPixelSize.height))) px")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    // Action Buttons Bar
                    HStack(spacing: 12) {
                        Button("Reset") {
                            selectPreset(.square)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Cancel") {
                            onCancel()
                            DispatchQueue.main.async { MemoryOptimizer.reclaimMemory() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 6)

                        Button(action: applyAndClose) {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark")
                                Text("Apply Crop")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
                            .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.04))
            }
            .frame(width: 480, height: 520)
            .background(LiquidWindowBackground(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            initNaturalSize()
        }
    }

    // MARK: - Handle Views

    private func handleCircle() -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(theme.accent, lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    private func handleCapsule(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: width, height: height)
            .overlay(Capsule().stroke(theme.accent, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    // MARK: - Logic & Drag Calculation

    private func initNaturalSize() {
        if let rep = image.representations.first {
            let w = rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) : image.size.width
            let h = rep.pixelsHigh > 0 ? CGFloat(rep.pixelsHigh) : image.size.height
            naturalPixelSize = CGSize(width: max(1, w), height: max(1, h))
        } else {
            naturalPixelSize = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
        }
        selectPreset(.square)
    }

    private func selectPreset(_ preset: CropAspectPreset) {
        selectedPreset = preset
        guard let r = preset.ratio else {
            normalizedCrop = CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
            syncDimensions()
            return
        }

        let imgRatio = naturalPixelSize.width / max(naturalPixelSize.height, 1)
        if imgRatio > r {
            let normW = min(1.0, r / imgRatio)
            normalizedCrop = CGRect(x: (1.0 - normW) / 2, y: 0, width: normW, height: 1.0)
        } else {
            let normH = min(1.0, imgRatio / r)
            normalizedCrop = CGRect(x: 0, y: (1.0 - normH) / 2, width: 1.0, height: normH)
        }
        syncDimensions()
    }

    private func syncDimensions() {
        widthInput = "\(Int(round(normalizedCrop.width * naturalPixelSize.width)))"
        heightInput = "\(Int(round(normalizedCrop.height * naturalPixelSize.height)))"
    }

    private func handleDrag(handle: DragHandle, translation: CGSize, frame: CGRect) {
        if dragStartRect == nil {
            dragStartRect = normalizedCrop
        }
        guard let start = dragStartRect, frame.width > 0, frame.height > 0 else { return }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        let minNormW = max(24.0 / frame.width, 0.04)
        let minNormH = max(24.0 / frame.height, 0.04)

        switch handle {
        case .move:
            let newX = min(max(0, start.minX + dx), 1.0 - start.width)
            let newY = min(max(0, start.minY + dy), 1.0 - start.height)
            normalizedCrop = CGRect(x: newX, y: newY, width: start.width, height: start.height)

        case .topLeft:
            var newMinX = max(0, min(start.maxX - minNormW, start.minX + dx))
            var newMinY = max(0, min(start.maxY - minNormH, start.minY + dy))
            if selectedPreset != .free, let r = selectedPreset.ratio {
                let normAspect = r * (naturalPixelSize.height / max(naturalPixelSize.width, 1))
                let targetW = (start.maxY - newMinY) * normAspect
                newMinX = max(0, start.maxX - targetW)
                newMinY = max(0, start.maxY - (start.maxX - newMinX) / normAspect)
            }
            normalizedCrop = CGRect(x: newMinX, y: newMinY, width: start.maxX - newMinX, height: start.maxY - newMinY)

        case .topRight:
            var newMaxX = min(1.0, max(start.minX + minNormW, start.maxX + dx))
            var newMinY = max(0, min(start.maxY - minNormH, start.minY + dy))
            if selectedPreset != .free, let r = selectedPreset.ratio {
                let normAspect = r * (naturalPixelSize.height / max(naturalPixelSize.width, 1))
                let targetW = (start.maxY - newMinY) * normAspect
                newMaxX = min(1.0, start.minX + targetW)
                newMinY = max(0, start.maxY - (newMaxX - start.minX) / normAspect)
            }
            normalizedCrop = CGRect(x: start.minX, y: newMinY, width: newMaxX - start.minX, height: start.maxY - newMinY)

        case .bottomLeft:
            var newMinX = max(0, min(start.maxX - minNormW, start.minX + dx))
            var newMaxY = min(1.0, max(start.minY + minNormH, start.maxY + dy))
            if selectedPreset != .free, let r = selectedPreset.ratio {
                let normAspect = r * (naturalPixelSize.height / max(naturalPixelSize.width, 1))
                let targetW = (newMaxY - start.minY) * normAspect
                newMinX = max(0, start.maxX - targetW)
                newMaxY = min(1.0, start.minY + (start.maxX - newMinX) / normAspect)
            }
            normalizedCrop = CGRect(x: newMinX, y: start.minY, width: start.maxX - newMinX, height: newMaxY - start.minY)

        case .bottomRight:
            var newMaxX = min(1.0, max(start.minX + minNormW, start.maxX + dx))
            var newMaxY = min(1.0, max(start.minY + minNormH, start.maxY + dy))
            if selectedPreset != .free, let r = selectedPreset.ratio {
                let normAspect = r * (naturalPixelSize.height / max(naturalPixelSize.width, 1))
                let targetW = (newMaxY - start.minY) * normAspect
                newMaxX = min(1.0, start.minX + targetW)
                newMaxY = min(1.0, start.minY + (newMaxX - start.minX) / normAspect)
            }
            normalizedCrop = CGRect(x: start.minX, y: start.minY, width: newMaxX - start.minX, height: newMaxY - start.minY)

        case .top:
            let newMinY = max(0, min(start.maxY - minNormH, start.minY + dy))
            if selectedPreset == .free {
                normalizedCrop = CGRect(x: start.minX, y: newMinY, width: start.width, height: start.maxY - newMinY)
            }
        case .bottom:
            let newMaxY = min(1.0, max(start.minY + minNormH, start.maxY + dy))
            if selectedPreset == .free {
                normalizedCrop = CGRect(x: start.minX, y: start.minY, width: start.width, height: newMaxY - start.minY)
            }
        case .left:
            let newMinX = max(0, min(start.maxX - minNormW, start.minX + dx))
            if selectedPreset == .free {
                normalizedCrop = CGRect(x: newMinX, y: start.minY, width: start.maxX - newMinX, height: start.height)
            }
        case .right:
            let newMaxX = min(1.0, max(start.minX + minNormW, start.maxX + dx))
            if selectedPreset == .free {
                normalizedCrop = CGRect(x: start.minX, y: start.minY, width: newMaxX - start.minX, height: start.height)
            }
        }
    }

    private func applyAndClose() {
        if let cropped = FileIconService.cropImage(image, normalizedCrop: normalizedCrop) {
            onApply(cropped)
        } else {
            onApply(image)
        }
        DispatchQueue.main.async {
            MemoryOptimizer.reclaimMemory()
        }
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool
    @ObservedObject private var theme = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: isSelected ? .bold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accent : Color.primary.opacity(0.06))
            )
            .foregroundColor(isSelected ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - File Icon Editor View

public enum IconPreviewShape: String, CaseIterable, Identifiable {
    case squircle = "Squircle (macOS)"
    case square = "Square"
    case circle = "Circle"

    public var id: String { rawValue }
}

public struct FileIconEditorView: View {
    public let sourceURL: URL
    public var onClose: () -> Void

    @State private var category: FileCategory = .image
    @State private var currentFinderIcon: NSImage?
    @State private var chosenImage: NSImage?
    @State private var previewShape: IconPreviewShape = .squircle
    @State private var setAsFinderIcon: Bool = true
    @State private var propagateToFolderItems: Bool = false

    @State private var isCropping: Bool = false
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
        ZStack {
            VStack(spacing: 0) {
                // Window Header
                ZStack {
                    Text(headerTitle)
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

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        // Target item summary banner
                        HStack(spacing: 12) {
                            Image(nsImage: currentFinderIcon ?? NSWorkspace.shared.icon(forFile: sourceURL.path))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(sourceURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 6) {
                                    Text(category.badgeText)
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.accent.opacity(0.18)))
                                        .foregroundColor(theme.accent)

                                    Text(RadialMenuConfiguration.formattedFileSize(for: sourceURL))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                        // Big Icon Preview Box
                        VStack(spacing: 12) {
                            ZStack {
                                if let img = chosenImage {
                                    applyShapeMask(to: img)
                                        .frame(width: 140, height: 140)
                                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                                } else if let def = currentFinderIcon {
                                    applyShapeMask(to: def)
                                        .frame(width: 140, height: 140)
                                        .opacity(0.9)
                                } else {
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(width: 140, height: 140)
                                        .overlay(
                                            VStack(spacing: 6) {
                                                Image(systemName: "photo.badge.plus")
                                                    .font(.system(size: 32))
                                                    .foregroundColor(.secondary)
                                                Text("Drop Image")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                        )
                                }

                                if isTargetedForDrop {
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(theme.accent, lineWidth: 3)
                                        .background(RoundedRectangle(cornerRadius: 24).fill(theme.accent.opacity(0.2)))
                                }
                            }
                            .frame(width: 140, height: 140)
                            .onDrop(of: [.fileURL, .image], isTargeted: $isTargetedForDrop) { providers in
                                handleDroppedImage(providers)
                            }

                            Text(chosenImage != nil ? "Icon ready to apply" : "Drag & drop any image above, or choose below")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            // Action Buttons: Choose Picture / Edit Crop / Remove
                            HStack(spacing: 8) {
                                Button(action: selectImageFromDisk) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "photo.badge.plus")
                                        Text("Choose Picture…")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)

                                if chosenImage != nil {
                                    // Option beside Choose Picture to edit the chosen picture
                                    Button(action: { isCropping = true }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "crop")
                                            Text("Edit / Crop")
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent.opacity(0.18)))
                                        .foregroundColor(theme.accent)
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { chosenImage = nil }) {
                                        HStack(spacing: 3) {
                                            Image(systemName: "trash")
                                            Text("Remove")
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.red.opacity(0.85))
                                        .padding(.horizontal, 9).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.03)))

                        // Options & Configuration
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ICON SETTINGS")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)

                            Toggle(isOn: $setAsFinderIcon) {
                                Text("Set as macOS Finder icon")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .toggleStyle(.checkbox)

                            if category == .folder {
                                Toggle(isOn: $propagateToFolderItems) {
                                    Text("Apply custom icon to media files inside this folder")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .toggleStyle(.checkbox)
                            }

                            // Shape mask picker
                            HStack(spacing: 8) {
                                Text("Preview Mask:")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                ForEach(IconPreviewShape.allCases) { shape in
                                    Button(shape.rawValue) {
                                        previewShape = shape
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: previewShape == shape ? .bold : .regular))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(previewShape == shape ? theme.accent.opacity(0.2) : Color.primary.opacity(0.04))
                                    )
                                    .foregroundColor(previewShape == shape ? theme.accent : .primary)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                Divider().opacity(0.3)

                // Footer Bar
                HStack(spacing: 10) {
                    Button(action: revertToDefaultIcon) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Revert to Default")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("Cancel", action: onClose)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 6)

                    Button(action: applyIconChanges) {
                        HStack(spacing: 5) {
                            if isSaving {
                                ProgressView().controlSize(.small)
                            } else if saveSuccess {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            Text(saveSuccess ? "Icon Applied!" : (isSaving ? "Applying…" : "Apply Icon"))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                        .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving || chosenImage == nil)
                }
                .padding(14)
            }
            .frame(width: 500, height: 600)
            .background(LiquidWindowBackground(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // Inline Crop Modal Overlay
            if isCropping, let img = chosenImage {
                ImageCropModalView(
                    image: img,
                    onApply: { cropped in
                        self.chosenImage = cropped
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
        .onAppear {
            category = FileCategory.detect(from: sourceURL)
            currentFinderIcon = FileIconService.getIcon(for: sourceURL)
        }
    }

    // MARK: - Mask Helpers

    @ViewBuilder
    private func applyShapeMask(to image: NSImage) -> some View {
        switch previewShape {
        case .squircle:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1.5))
        case .square:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        case .circle:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5))
        }
    }

    private var headerTitle: String {
        switch category {
        case .video: return "Video Icon & Poster Editor"
        case .image: return "Picture Icon Editor"
        case .folder: return "Folder Icon Editor"
        default: return "Custom File Icon Editor"
        }
    }

    // MARK: - Actions

    private func handleDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let img = FileIconService.loadDownsampledImage(from: data, maxPixelSize: 1200) {
                        DispatchQueue.main.async {
                            withAnimation { self.chosenImage = img }
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
                            withAnimation { self.chosenImage = img }
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
        panel.prompt = "Choose Icon"

        if panel.runModal() == .OK, let url = panel.url,
           let img = FileIconService.loadDownsampledImage(from: url, maxPixelSize: 1200) {
            withAnimation {
                self.chosenImage = img
            }
        }
    }

    private func revertToDefaultIcon() {
        FileIconService.removeCustomIcon(for: sourceURL)
        currentFinderIcon = FileIconService.getIcon(for: sourceURL)
        chosenImage = nil
        withAnimation { saveSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onClose()
        }
    }

    private func applyIconChanges() {
        guard let img = chosenImage, !isSaving else { return }
        isSaving = true
        errorMessage = nil

        Task {
            let success = FileIconService.setIcon(
                image: img,
                for: sourceURL,
                propagateToChildren: propagateToFolderItems
            )

            await MainActor.run {
                isSaving = false
                if success {
                    withAnimation { saveSuccess = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        onClose()
                    }
                } else {
                    errorMessage = "Failed to apply custom icon to \(sourceURL.lastPathComponent)"
                }
            }
        }
    }
}

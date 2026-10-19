//
//  BackgroundRemoval.swift
//  OpenTangerine
//
//  Intelligent Background Removal Engine & Interactive Masking Editor
//  Supports Apple Vision AI instance/person segmentation and interactive Point & Autoselect Magic Wand.
//

import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import Vision

// MARK: - Transparency Checkerboard Canvas

public struct CheckerboardBackground: View {
    public var tileSize: CGFloat = 10
    public var lightColor: Color = Color(white: 0.22)
    public var darkColor: Color = Color(white: 0.15)

    public init(tileSize: CGFloat = 10, lightColor: Color = Color(white: 0.22), darkColor: Color = Color(white: 0.15)) {
        self.tileSize = tileSize
        self.lightColor = lightColor
        self.darkColor = darkColor
    }

    public var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))
            for r in 0..<rows {
                for c in 0..<cols {
                    let rect = CGRect(x: CGFloat(c) * tileSize, y: CGFloat(r) * tileSize, width: tileSize, height: tileSize)
                    let isEven = (r + c) % 2 == 0
                    context.fill(Path(rect), with: .color(isEven ? lightColor : darkColor))
                }
            }
        }
    }
}

// MARK: - Background Removal Engine

public final class BackgroundRemovalEngine: @unchecked Sendable {
    public static let shared = BackgroundRemovalEngine()

    public enum RemovalMode: String, CaseIterable, Identifiable {
        case autoMask = "AI Auto Mask"
        case pointSelect = "Point & Select"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .autoMask: return "sparkles"
            case .pointSelect: return "wand.and.stars"
            }
        }
    }

    public enum SelectionAction: String, CaseIterable, Identifiable {
        case remove = "Remove Area"
        case keep = "Keep Area"

        public var id: String { rawValue }
    }

    public enum PreviewBackdrop: String, CaseIterable, Identifiable {
        case checkerboard = "Checkerboard"
        case rubyMask = "Ruby Mask"
        case white = "White"
        case black = "Black"

        public var id: String { rawValue }
    }

    /// Automatically remove background using Apple Vision AI (foreground instance segmentation or person segmentation),
    /// with intelligent corner/border color flood-fill fallback for graphics/logos.
    public func removeBackgroundAI(from sourceCG: CGImage) async throws -> CGImage {
        // 1. Try Vision Foreground Instance Mask (macOS 14+)
        if #available(macOS 14.0, *) {
            if let result = try await performForegroundMask(on: sourceCG) {
                return result
            }
        }

        // 2. Try Person Segmentation (macOS 13+)
        if let result = try await performPersonSegmentation(on: sourceCG) {
            return result
        }

        // 3. Fallback: Edge & Corner Color Flood Fill
        return try performBorderColorCutout(on: sourceCG)
    }

    @available(macOS 14.0, *)
    private func performForegroundMask(on cgImage: CGImage) async throws -> CGImage? {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let maskedBuffer = try observation.generateMaskedImage(
                    ofInstances: observation.allInstances,
                    from: handler,
                    croppedToInstancesExtent: false
                )
                let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
                let ciContext = CIContext(options: [.useSoftwareRenderer: false])
                if let outCG = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    continuation.resume(returning: outCG)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func performPersonSegmentation(on cgImage: CGImage) async throws -> CGImage? {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first as? VNPixelBufferObservation else {
                    continuation.resume(returning: nil)
                    return
                }
                let maskCI = CIImage(cvPixelBuffer: observation.pixelBuffer)
                let sourceCI = CIImage(cgImage: cgImage)

                let scaleX = sourceCI.extent.width / max(maskCI.extent.width, 1)
                let scaleY = sourceCI.extent.height / max(maskCI.extent.height, 1)
                let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

                guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
                    continuation.resume(returning: nil)
                    return
                }
                blendFilter.setValue(sourceCI, forKey: kCIInputImageKey)
                blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
                blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)

                guard let outputCI = blendFilter.outputImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let ciContext = CIContext(options: [.useSoftwareRenderer: false])
                if let outCG = ciContext.createCGImage(outputCI, from: sourceCI.extent) {
                    continuation.resume(returning: outCG)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func performBorderColorCutout(on cgImage: CGImage) throws -> CGImage {
        let corners: [CGPoint] = [
            CGPoint(x: 0.01, y: 0.01),
            CGPoint(x: 0.99, y: 0.01),
            CGPoint(x: 0.01, y: 0.99),
            CGPoint(x: 0.99, y: 0.99)
        ]
        return removeBackgroundAtPoints(
            from: cgImage,
            points: corners,
            tolerance: 0.22,
            action: .remove,
            invert: false
        )
    }

    /// Point & Autoselect Smart Wand: Removes or isolates areas matching the clicked point(s) with edge-aware flood fill.
    public func removeBackgroundAtPoints(
        from sourceCG: CGImage,
        points: [CGPoint],
        tolerance: Double,
        action: SelectionAction,
        invert: Bool,
        rubyTint: Bool = false
    ) -> CGImage {
        guard !points.isEmpty else { return sourceCG }
        let w = sourceCG.width
        let h = sourceCG.height
        guard w > 0 && h > 0 else { return sourceCG }

        var rawData = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rawData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return sourceCG }

        ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: w, height: h))

        var mask = [UInt8](repeating: 0, count: w * h)
        let maxDist = 255.0 * 2.0
        let threshSq = Int(pow(tolerance * maxDist, 2))

        for pt in points {
            let sx = min(w - 1, max(0, Int(pt.x * CGFloat(w))))
            let sy = min(h - 1, max(0, Int(pt.y * CGFloat(h))))
            let seedPixel = sy * w + sx
            if mask[seedPixel] == 1 { continue }

            let sIdx = seedPixel * 4
            let r0 = Int(rawData[sIdx])
            let g0 = Int(rawData[sIdx + 1])
            let b0 = Int(rawData[sIdx + 2])
            let a0 = Int(rawData[sIdx + 3])

            var queue = [Int]()
            queue.reserveCapacity(min(w * h / 4, 150_000))
            queue.append(seedPixel)
            mask[seedPixel] = 1

            var head = 0
            while head < queue.count {
                let curr = queue[head]
                head += 1
                let cx = curr % w
                let cy = curr / w

                let neighbors = [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
                for (nx, ny) in neighbors {
                    guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                    let nPixel = ny * w + nx
                    if mask[nPixel] == 0 {
                        let nIdx = nPixel * 4
                        let dr = Int(rawData[nIdx]) - r0
                        let dg = Int(rawData[nIdx + 1]) - g0
                        let db = Int(rawData[nIdx + 2]) - b0
                        let da = Int(rawData[nIdx + 3]) - a0
                        if dr * dr + dg * dg + db * db + da * da <= threshSq {
                            mask[nPixel] = 1
                            queue.append(nPixel)
                        }
                    }
                }
            }
        }

        // Apply transparency or ruby mask overlay
        for i in 0..<(w * h) {
            let isSelected = (mask[i] == 1)
            let shouldRemove: Bool
            switch action {
            case .remove:
                shouldRemove = invert ? !isSelected : isSelected
            case .keep:
                shouldRemove = invert ? isSelected : !isSelected
            }

            let idx = i * 4
            if shouldRemove {
                if rubyTint {
                    // Quick Mask tint: overlay semi-transparent ruby coral over removed areas
                    rawData[idx] = UInt8(min(255, Int(rawData[idx]) / 2 + 128))     // R
                    rawData[idx + 1] = UInt8(Int(rawData[idx + 1]) / 3)            // G
                    rawData[idx + 2] = UInt8(Int(rawData[idx + 2]) / 3)            // B
                    rawData[idx + 3] = 255                                         // A
                } else {
                    // Transparent cutout
                    rawData[idx] = 0
                    rawData[idx + 1] = 0
                    rawData[idx + 2] = 0
                    rawData[idx + 3] = 0
                }
            }
        }

        guard let outCG = ctx.makeImage() else { return sourceCG }
        return outCG
    }
}

// MARK: - Interactive Background Removal Editor View

public struct BackgroundRemovalEditorView: View {
    public let sourceURL: URL
    public var onComplete: (URL) -> Void
    public var onClose: () -> Void

    @State private var originalCGImage: CGImage?
    @State private var previewCGImage: CGImage?
    @State private var processedPreviewImage: NSImage?
    @State private var naturalPixelSize: CGSize = CGSize(width: 1000, height: 1000)

    @State private var currentMode: BackgroundRemovalEngine.RemovalMode = .autoMask
    @State private var selectionAction: BackgroundRemovalEngine.SelectionAction = .remove
    @State private var tolerance: Double = 0.25
    @State private var invertMask: Bool = false
    @State private var clickedPoints: [CGPoint] = []
    @State private var previewBackdrop: BackgroundRemovalEngine.PreviewBackdrop = .checkerboard

    @State private var isProcessing: Bool = false
    @State private var statusMessage: String = "Detecting foreground subject…"
    @State private var ripplePoint: CGPoint? = nil
    @State private var rippleOpacity: Double = 0.0

    @ObservedObject private var theme = ThemeManager.shared

    public init(sourceURL: URL, onComplete: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.onComplete = onComplete
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "person.and.background.dotted")
                        .foregroundColor(theme.accent)
                    Text("Remove Background")
                        .font(.system(size: 14, weight: .bold))
                }
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
            .background(WindowDragHandle())

            // Mode Toggle (AI Auto Mask vs Point & Select)
            HStack(spacing: 8) {
                ForEach(BackgroundRemovalEngine.RemovalMode.allCases) { mode in
                    Button {
                        currentMode = mode
                        if mode == .autoMask {
                            runAutoMask()
                        } else {
                            if clickedPoints.isEmpty {
                                statusMessage = "Click anywhere on the image to autoselect that area"
                            } else {
                                updatePointSelection()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon)
                            Text(mode.rawValue)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(currentMode == mode ? theme.accent : Color.primary.opacity(0.05))
                        )
                        .foregroundColor(currentMode == mode ? (theme.currentTheme == .monochrome ? .black : .white) : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // Backdrop Preview Switcher
                HStack(spacing: 4) {
                    ForEach(BackgroundRemovalEngine.PreviewBackdrop.allCases) { backdrop in
                        Button {
                            previewBackdrop = backdrop
                            if currentMode == .pointSelect {
                                updatePointSelection()
                            }
                        } label: {
                            Text(backdrop.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(previewBackdrop == backdrop ? theme.accent.opacity(0.2) : Color.clear)
                                )
                                .foregroundColor(previewBackdrop == backdrop ? theme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            // Canvas Area
            GeometryReader { geo in
                let scale = min((geo.size.width - 24) / max(naturalPixelSize.width, 1),
                                (geo.size.height - 20) / max(naturalPixelSize.height, 1))
                let w = naturalPixelSize.width * scale
                let h = naturalPixelSize.height * scale
                let frame = CGRect(x: (geo.size.width - w) / 2, y: (geo.size.height - h) / 2, width: w, height: h)

                ZStack {
                    // Backdrop canvas
                    Group {
                        switch previewBackdrop {
                        case .checkerboard:
                            CheckerboardBackground(tileSize: 12)
                        case .rubyMask:
                            Color(white: 0.12)
                        case .white:
                            Color.white
                        case .black:
                            Color.black
                        }
                    }
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .position(x: frame.midX, y: frame.midY)

                    // Rendered cutout image
                    if let img = processedPreviewImage {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: w, height: h)
                            .position(x: frame.midX, y: frame.midY)
                    } else if isProcessing {
                        ProgressView()
                            .scaleEffect(1.2)
                            .position(x: frame.midX, y: frame.midY)
                    }

                    // Click Ripple Indicator
                    if let rp = ripplePoint {
                        Circle()
                            .stroke(theme.accent, lineWidth: 2)
                            .frame(width: 32, height: 32)
                            .position(rp)
                            .opacity(rippleOpacity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { val in
                            handleCanvasTap(location: val.location, frame: frame)
                        }
                )
            }
            .frame(height: 380)
            .padding(.horizontal, 16)

            // Interactive Controls Bar
            VStack(alignment: .leading, spacing: 12) {
                if currentMode == .pointSelect {
                    // Tolerance Slider & Action Toggle
                    HStack(spacing: 12) {
                        Text("Tolerance").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Slider(value: $tolerance, in: 0.05...0.70) { editing in
                            if !editing { updatePointSelection() }
                        }
                        .onChange(of: tolerance) { _ in
                            updatePointSelection()
                        }
                        .tint(theme.accent)

                        Text("\(Int(round(tolerance * 100)))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)

                        Divider().frame(height: 16)

                        // Action: Remove vs Keep
                        Picker("", selection: $selectionAction) {
                            ForEach(BackgroundRemovalEngine.SelectionAction.allCases) { action in
                                Text(action.rawValue).tag(action)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                        .onChange(of: selectionAction) { _ in
                            updatePointSelection()
                        }
                    }

                    // Secondary Tools
                    HStack {
                        Button {
                            invertMask.toggle()
                            updatePointSelection()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.arrow.right")
                                Text("Invert")
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(invertMask ? theme.accent.opacity(0.2) : Color.primary.opacity(0.05)))
                            .foregroundColor(invertMask ? theme.accent : .primary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            clickedPoints.removeAll()
                            invertMask = false
                            processedPreviewImage = previewCGImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                            statusMessage = "Cleared selection. Click any area to select."
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Clear Points")
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    // AI Mode Info Row
                    HStack {
                        Image(systemName: "wand.and.sparkles")
                            .foregroundColor(theme.accent)
                        Text(statusMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Re-detect") {
                            runAutoMask()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }

                Divider()

                // Bottom Action Bar: Reset & Done
                HStack {
                    Button("Reset") {
                        resetToOriginal()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))

                    Spacer()

                    Button {
                        applyCutoutAndFinish()
                    } label: {
                        HStack(spacing: 6) {
                            if isProcessing {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text("Done")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 24).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
                        .foregroundColor(theme.currentTheme == .monochrome ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                }
            }
            .padding(18)
        }
        .frame(width: 540, height: 660)
        .background(LiquidWindowBackground(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onExitCommand(perform: onClose)
        .onAppear {
            loadPreviewImage()
        }
        .onDisappear {
            originalCGImage = nil
            previewCGImage = nil
            processedPreviewImage = nil
            MemoryOptimizer.reclaimMemory()
        }
    }

    // MARK: - Canvas Tap Handling

    private func handleCanvasTap(location: CGPoint, frame: CGRect) {
        guard frame.contains(location) else { return }

        // Switch to pointSelect mode if not already
        if currentMode != .pointSelect {
            currentMode = .pointSelect
        }

        let normX = (location.x - frame.minX) / frame.width
        let normY = (location.y - frame.minY) / frame.height
        let normPt = CGPoint(x: normX, y: normY)

        clickedPoints.append(normPt)

        // Show pulsing ripple
        ripplePoint = location
        rippleOpacity = 1.0
        withAnimation(.easeOut(duration: 0.45)) {
            rippleOpacity = 0.0
        }

        updatePointSelection()
    }

    // MARK: - Point & Autoselect Execution

    private func updatePointSelection() {
        guard let base = previewCGImage, !clickedPoints.isEmpty else { return }
        autoreleasepool {
            let isRuby = (previewBackdrop == .rubyMask)
            let resultCG = BackgroundRemovalEngine.shared.removeBackgroundAtPoints(
                from: base,
                points: clickedPoints,
                tolerance: tolerance,
                action: selectionAction,
                invert: invertMask,
                rubyTint: isRuby
            )
            processedPreviewImage = NSImage(cgImage: resultCG, size: NSSize(width: resultCG.width, height: resultCG.height))
            let count = clickedPoints.count
            statusMessage = "Point selected (\(count) seed\(count > 1 ? "s" : "")). Adjust tolerance or click Done."
        }
    }

    // MARK: - AI Auto Mask Execution

    private func runAutoMask() {
        guard let base = previewCGImage else { return }
        isProcessing = true
        statusMessage = "Analyzing image subjects…"

        Task {
            do {
                let cutoutCG = try await BackgroundRemovalEngine.shared.removeBackgroundAI(from: base)
                await MainActor.run {
                    self.processedPreviewImage = NSImage(cgImage: cutoutCG, size: NSSize(width: cutoutCG.width, height: cutoutCG.height))
                    self.isProcessing = false
                    self.statusMessage = "Foreground subject isolated! Press Done to export."
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = "Auto detection: falling back to Point & Select mode"
                    self.currentMode = .pointSelect
                }
            }
        }
    }

    // MARK: - Image Loading

    private func loadPreviewImage() {
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return }

        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w > 0 && h > 0 {
                naturalPixelSize = CGSize(width: w, height: h)
            }
        }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceShouldCache: false
        ]

        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            previewCGImage = cg
            processedPreviewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        // Keep reference to full resolution source if needed
        let fullOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(naturalPixelSize.width, naturalPixelSize.height),
            kCGImageSourceShouldCache: false
        ]
        originalCGImage = CGImageSourceCreateThumbnailAtIndex(src, 0, fullOpts as CFDictionary) ??
                          CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)

        // Run initial AI mask automatically
        runAutoMask()
    }

    private func resetToOriginal() {
        clickedPoints.removeAll()
        invertMask = false
        selectionAction = .remove
        tolerance = 0.25
        if let cg = previewCGImage {
            processedPreviewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        statusMessage = "Reset to original image"
    }

    // MARK: - Save High-Res Cutout

    private func applyCutoutAndFinish() {
        isProcessing = true
        statusMessage = "Exporting high-resolution cutout…"

        Task {
            guard let fullCG = originalCGImage ?? previewCGImage else { return }

            var finalCG: CGImage? = nil

            if currentMode == .autoMask {
                finalCG = try? await BackgroundRemovalEngine.shared.removeBackgroundAI(from: fullCG)
            } else if !clickedPoints.isEmpty {
                finalCG = BackgroundRemovalEngine.shared.removeBackgroundAtPoints(
                    from: fullCG,
                    points: clickedPoints,
                    tolerance: tolerance,
                    action: selectionAction,
                    invert: invertMask,
                    rubyTint: false
                )
            }

            guard let outputCG = finalCG ?? previewCGImage else {
                await MainActor.run { isProcessing = false }
                return
            }

            let outURL = FileConversionEngine.shared.uniqueOutputURL(
                in: sourceURL.deletingLastPathComponent(),
                baseName: sourceURL.deletingPathExtension().lastPathComponent,
                suffix: "No Background",
                ext: "png"
            )

            let success = (try? FileConversionEngine.shared.writeCGImage(outputCG, to: outURL, format: "png")) != nil

            await MainActor.run {
                isProcessing = false
                if success {
                    onComplete(outURL)
                }
            }
        }
    }
}

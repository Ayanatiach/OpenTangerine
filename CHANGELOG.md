# Changelog

All notable changes to OpenTangerine will be documented in this file.

## [1.1.0] - 2026-10-23

### 🚀 Highlights
- **Multi-Photo to PDF Studio (Interactive Page Ordering & Per-Photo Editing)**:
  - When multiple pictures are dragged or selected and the **PDF** slice is chosen, a dedicated studio window pops up to preview, organize, and compile them into a unified PDF.
  - **Live Page Ordering**: Move pages up/down, reverse overall order (perfect for reverse-scanned pages), sort by name or size, and append additional photos from disk.
  - **Per-Photo Interactive Crop**: Crop mode with 8-handle resizer, rule-of-thirds grid, center pan drag, and aspect ratio presets (Free, Original, 1:1, 4:3, 16:9, 3:2, A4 Portrait, A4 Landscape, US Letter).
  - **Rotation & Flips**: Individual 90° clockwise/counter-clockwise rotations and horizontal/vertical flips.
  - **Document Scan & Color Filters**: High-contrast **Doc Scan** filter for paper/receipt whitening and ink sharpening, plus B&W, Sepia, Vivid, Warm, Cool, and Negative filters with "Apply to All Pages" batch enhancement.
  - **Adjustments**: Manual Brightness, Contrast, and Saturation sliders with real-time preview.
  - **PDF Page & Layout Options**: Choose between Fit to Photo, A4, US Letter, and Square; configure margins (None, Small, Normal); and select compression quality (Maximum, Balanced, Compact).
  - **Menu Bar Integration**: Quick access via **"Create PDF from Photos…"** in the OpenTangerine menu bar.

---

## [1.0.9] - 2026-10-23

### 🚀 Highlights
- **Universal Release Build & Repository Synchronization**:
  - Re-compiled and validated the full universal binary (`arm64` Apple Silicon M1-M4 and `x86_64` Intel) with ad-hoc runtime code signatures.
  - Bundled standalone `libopencore-amrnb.dylib` dynamically for native AMR encoding.
  - Integrated in-app update service fallback to v1.0.9.
  - Enhanced `README.md` with release status badges, verified curl installation commands, and feature tables.

---

## [1.0.8] - 2026-10-21

### 🚀 Highlights
- **Audio ↔ Video Cross-Conversion Engine (Option + Shift + Drag)**:
  - Hold **Option + Shift (⌥⇧) + Drag** on any audio or video file to trigger the cross-conversion radial wheel.
  - **Audio to Video Transcoding**: Transcode audio tracks into video files (**MP4**, **MOV**, **WEBM**, **MKV**, **AVI**, **WMV**, **FLV**, **3GP**, **OGV**), rendering embedded album art or Finder custom icon onto a 1280×720 visual card (2fps still-image looping with `-shortest` and AVFoundation fallback).
  - **Video to Audio Extraction**: Extract pure, uncompressed/high-bitrate audio streams directly into **MP3**, **M4A**, **AAC**, **WAV**, **FLAC**, **OGG**, **AIFF**, **ALAC**, or **WMA** via FFmpeg `-vn` or Apple `afconvert`.
  - Background asynchronous task pipeline with macOS system notification dispatch and Finder reveal.
- **Custom File & Folder Icon Studio with Interactive Cropper**:
  - Added dedicated **ICON** slice in the tools radial wheel.
  - **Inline Crop / Edit Button**: Interactively adjust and crop source images prior to assigning them as Finder icons.
  - **macOS Continuous Squircle Guide**: Interactive 8-handle box resizer, center drag panning, aspect ratio presets (1:1 Square, Free, 4:3, 16:9, 3:2), and Apple Squircle contour overlay.
  - Universal support across Folders (with child file propagation), Videos (poster artwork), Images, and Audio.
  - 1-click **Reset to Default System Icon** button.
- **Multi-Format Music Transcoder & VLC-Compatible Metadata**:
  - Convert between 10 core audio formats: **AAC**, **AIFF**, **ALAC**, **AMR**, **FLAC**, **M4A**, **MP3**, **OGG**, **WAV**, and **WMV/WMA**.
  - **VLC-Compatible Metadata Name & Tag Editor**: Edit Track Title (synced across VLC Media Player, Apple Music, and external media players), Artist, Album, Album Artist, Year, Genre, and Track Number.
  - Custom album artwork embedding (ID3v2 APIC, MP4/ALAC covr, FLAC picture blocks).
- **Beginner's Guide to Homebrew & FFmpeg**:
  - Detailed step-by-step instructions for non-technical users to install Homebrew and FFmpeg in under 2 minutes.
- **Zero-Leak Memory Optimization & Universal Architecture**:
  - Built for both Apple Silicon (M1/M2/M3/M4) and Intel x86_64 architectures.
  - Active heap sweeps (`malloc_zone_pressure_relief`) keep live resting RAM footprint around ~80 MB.

---

## [1.0.6] - 2026-10-20

### 🚀 Highlights
- **Multi-Format Video Transcoding Engine (Shift + Drag)**:
  - Added full video conversion support to the radial wheel menu when dragging video files in Finder with **Shift (⇧)**.
  - Supports converting video files to and from: **3GP**, **AVI**, **FLV**, **MKV**, **MOV**, **MP4**, **OGV**, **WEBM**, and **WMV**.
  - Slices are dynamically generated and filtered to display all other target formats with custom `film` iconography.
- **Dedicated Video Inspector ("INFO" Wheel Slice)**:
  - Added dedicated **"INFO"** slice with `info.circle` iconography to both convert and tools wheels for video files, providing seamless continuity with image metadata and folder/archive inspection.
  - **Comprehensive Technical Breakdown**: Live video frame thumbnail extraction (via FFmpeg piped frame with AVAssetImageGenerator fallback), video codec & profile, resolution, display aspect ratio, nominal frame rate, pixel format, video bitrate, audio codec, audio channels & layout, sample rate, duration, and container format specs.
  - Quick action buttons to **"Copy All Info"**, **"Show in Finder"**, and **"Open in Player"**.
- **Dual-Engine Architecture (FFmpeg + Apple AVFoundation)**:
  - **FFmpeg Integration**: Automatic discovery of system FFmpeg & FFprobe (`/opt/homebrew`, `/usr/local`, `~/.local/bin`, or `PATH`) enabling full container and codec support (H.264, VP9, Theora, Sorenson Spark FLV, WMV2, AAC, Opus, MP3).
  - **AVFoundation Native Fallback**: 100% offline fallback for standard macOS formats (MP4, MOV, 3GP) using Apple's `AVAssetExportSession` when FFmpeg is not installed.
  - **Odd-Dimension Safe Scaling**: Automatically applies dimension normalization filter (`scale=trunc(iw/2)*2:trunc(ih/2)*2`) to prevent video encoder crashes on odd-dimension crops or screen recordings.
- **Asynchronous & Non-Blocking Workflow**:
  - Video conversions process on background threads with real-time menu bar status (`Converting video.mp4 → WEBM…`), system notifications upon completion, and Finder selection.
- **Settings & Appearance Integration**:
  - Added **Video Conversion Engine** card in **Theme & Appearance Settings (`⌘,`)** displaying active engine status (`FFMPEG READY` vs `AVFOUNDATION`), detected binary path, and quick copy command for `brew install ffmpeg`.
- **Command-Line Interface (CLI)**:
  - Direct video conversions via `swift run -c release OpenTangerine --convert <format> <video-file>`.

---

## [1.0.5] - 2026-10-19

### 🚀 Highlights
- **Flawless Multi-Side & Corner Crop Editor**:
  - Full interactive resizing from all 4 sides (Top, Bottom, Left, Right) and all 4 corners (Top-Left, Top-Right, Bottom-Left, Bottom-Right).
  - Interior drag to pan the selection rectangle smoothly within image boundaries.
  - Compositional Photography **Rule-of-Thirds (3×3)** grid lines inside the active crop frame.
  - Edge-to-edge dark dimmed mask overlay outside the selection rectangle for crystal-clear framing.
  - Aspect ratio presets: Free, 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3 with aspect locking on corner adjustments and smooth unlocking on edge adjustments.
  - Interactive manual width and height (`W` and `H`) pixel text fields with live synchronization and pixel-perfect cropping.
- **Background Removal Engine & Interactive Editor ("REMOVE BG")**:
  - Added dedicated **REMOVE BG** tool to the radial tools wheel with `person.and.background.dotted` symbol.
  - **AI Auto Masking**: 1-click automatic foreground subject isolation using Apple Vision instance/person segmentation with intelligent border-color fallback for non-photos, logos, and graphics.
  - **Point & Autoselect (Magic Wand)**: Click anywhere on the image canvas to autoselect connected background or foreground regions using an edge-aware flood fill algorithm.
  - Dynamic **Tolerance Slider** (5% - 70%) with live visual recalculation.
  - Mode toggle: "Remove Area" vs "Keep Area", plus "Invert Mask" and "Clear Points".
  - Preview Modes: Cutout (Transparent Checkerboard), Ruby Mask Tint (Quick Mask glow), White, and Black.
  - Prominent **Done** button that exports studio-quality transparent PNGs and reveals them in Finder.
- **Subject Isolation in Backdrop Editor ("ADD BG")**:
  - Integrated "Remove Photo Background" toggle directly into the backdrop editor to isolate subjects before placing them onto colorful gradient backdrops.
- **Linear & Continuous Mac Squircle Bevels**:
  - Harmonized all window corners to continuous 18pt macOS squircles (`RoundedRectangle(cornerRadius: 18, style: .continuous)`) across all themes and views.
  - Eliminated sharp edges on modal windows, theme settings, updates, and metadata inspector.
  - Configured AppKit `NSHostingView` layer properties (`cornerCurve = .continuous`, `masksToBounds = true`) and window shadow invalidation for perfect system drop shadows.

---

## [1.0.4] - 2026-10-19

### 🚀 Highlights
- **Shift-Only Folder & Archive Actions**: Dragging directories or ZIP files in Finder with **Shift (⇧)** now presents a dedicated Folder wheel featuring **Zip Folder**, **Unzip Archive**, and **Folder / Archive Info**.
- **Deep Folder & Archive Inspector**: Instant recursive metadata inspection (total files, subfolders, nesting levels, disk space vs logical bytes, breakdown of file categories, top largest files, and POSIX permissions).
- **In-App GitHub Auto-Updater (`⌘U`)**: Check for updates and install new releases with 1-click in-place update and automatic relaunch.
- **Draggable Appearance & Tool Windows**: Theme Settings (`⌘,`), Folder Inspector, Metadata Inspector, and Updater windows can now be moved and dragged by their titlebars/headers.
- **Zero Memory Leaks & Multi-Zone Memory Optimization**: Eliminated URLSession delegate retain cycles, downsampled Finder icon representations, unmounted SwiftUI view hierarchies immediately upon window close, and enabled multi-zone Mach VM memory relief.

### 🛡️ Optimizations & Bug Fixes
- **URLSession Delegate Invalidation**: Fixed `<__NSURLSessionLocal>` retain cycle in `AppUpdateService` by adding `defer { session.finishTasksAndInvalidate() }`.
- **Multi-Zone Heap Pressure Relief**: Swept all malloc zones using `malloc_get_all_zones` and `malloc_zone_pressure_relief`, actively releasing unpurged ImageIO and CoreGraphics caches.
- **Icon Representation Downsampling**: Replaced direct multi-resolution `NSWorkspace.shared.icon(forFile:)` loads with 32×32 and 58×58 rasterized bitmaps, saving several megabytes of heap memory.
- **Immediate SwiftUI View Graph Teardown**: Explicitly set `contentView = nil` upon window and panel close to force immediate ARC deallocation of hosting view trees.
- **Tracking Area Detachment**: Cleanly unhooked tracking areas and mouse event handlers in `WheelInteractionView.viewDidMoveToWindow` when views detach.
- **Active Modal Flush on Disappear**: Added `.onDisappear` memory reclamation hooks across `ThemeSettingsView`, `RadialWheelView`, and `UpdateView`.

---

## [1.0.3] - 2026-10-19

### 🚀 Highlights
- **Ultra-Low Memory Footprint (~16 MB)**: Integrated Darwin heap pressure relief (`malloc_zone_pressure_relief`) that automatically returns unused heap blocks, decoded image caches, and temporary view graphs to the macOS Mach VM whenever the wheel or editors close.
- **Zero-Crash Window Architecture**: Diagnosed and permanently fixed the use-after-free crash (`SIGSEGV` in `objc_msgSend`) occurring on theme change or metadata inspection.

### 🛡️ Bug Fixes & Stability Optimizations
- **Window Lifecycle Deallocation**: Explicitly set `win.isReleasedWhenClosed = false` on all modal windows and panels to prevent AppKit from destroying window instances behind ARC's back.
- **Dangling Pointer Elimination**: Implemented `EditorWindowDelegate: NSWindowDelegate` and `closeEditor()`, cleanly setting `contentView = nil`, removing observers, and nullifying references immediately upon window close.
- **Menu Bar Menu Tracking Stability**: Made the MenuBarExtra theme submenu title static (`Menu("Theme")`) with live checkmarks on active items to prevent AppKit `NSMenuTrackingSession` internal deallocation faults while navigating the menu.
- **Dismissed Wheel View Deallocation**: Setting `panel.contentView = nil` upon wheel dismissal prevents orphaned SwiftUI hierarchies from executing background layout cascades when switching themes.
- **Hardened Image IO & Metadata**: Added image count validation (`CGImageSourceGetCount > 0`) and verified non-zero thumbnail dimensions before invoking CoreGraphics and AppKit image decoders.
- **Keyboard Dismissal**: Added `.onExitCommand(perform: onClose)` across all modal views (`ThemeSettingsView`, `MetadataInspectorView`, `CropEditorView`, `BackgroundEditorView`), allowing instant dismissal with the `Escape` key.
- **Multi-File Drag Safety**: Protected interactive tool actions to ensure a single clean editor window is launched when multiple files are dropped, while preserving parallel batch conversion for format exports.
- **Built-in Automated Verification**: Added `--test-stability` CLI argument to exercise all theme switches, window lifecycles, and metadata inspection without GUI interaction.

---

## [1.0.2] - 2026-10-19

### 🎨 Customizable Themes & Liquid Glass
- Added 7 themes: **Tangerine Sunset**, **Liquid Glass**, **Cyber Cyan**, **Neon Violet**, **Emerald Mint**, **Solar Gold**, and **Monochrome**.
- Added **Liquid Glass** theme with customizable base opacity slider and live preview disc.
- Added live synchronization with macOS System Settings (*Accessibility → Display → Reduce Transparency*).
- Added **Theme & Appearance Settings** window (`⌘,`).

### 🔍 Metadata Inspector & Cleaner
- Added **Inspect EXIF & GPS** tool slice to the Option + Shift Tools wheel.
- Detailed file specifications: dimensions, megapixels, color profile, format, and file size.
- Camera and shooting details: make, model, lens, exposure time, aperture, ISO, and focal length.
- GPS coordinate extraction with **Open in Apple Maps** button.
- **Strip & Save Copy** button to export privacy-clean images without EXIF/GPS tags.
- One-click **Copy All Info** button for clipboard export.

---

## [1.0.1] - 2026-10-19

### 🎯 Interactivity & Hit-Testing
- Fixed wheel hit-testing and slice selection in Finder drag sessions.
- Added `WheelInteractionView` drop target and mouse tracking area.
- Fixed image format conversion and output path generation.

---

## [1.0.0] - 2026-10-19

### 🎉 Initial Release
- Initial open-source release of OpenTangerine for macOS.
- Shift + Drag radial conversion wheel for documents and images.
- Option + Shift + Drag tools wheel (Crop, Add Background, Compress).
- Menu-bar-only agent app (`LSUIElement = true`).

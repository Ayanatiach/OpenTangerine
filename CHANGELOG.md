# Changelog

All notable changes to OpenTangerine will be documented in this file.

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

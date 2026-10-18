# Changelog

All notable changes to OpenTangerine will be documented in this file.

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

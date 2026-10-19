<p align="center">
  <img src="Assets/AppIcon.png" width="160" alt="OpenTangerine icon">
</p>

<h1 align="center">OpenTangerine</h1>

<p align="center">
  Open-source macOS radial file converter &amp; image toolkit — triggered by <b>Shift + Drag</b> in Finder.
</p>

---

## ✨ Features

OpenTangerine lives in your menu bar. Start dragging any file in Finder, then hold a modifier key and a radial
"wheel" menu pops up under your cursor. Release over a slice to run the action — the result is saved next to the
original file and revealed in Finder.

| Gesture | Target | Wheel | What you get |
|---|---|---|---|
| **⇧ Shift + Drag** | Files | Convert | PDF → DOCX / JPG / PNG / TXT · Images → PNG / WEBP / HEIC / JPG / AVIF / BMP / PDF / DOCX / TIFF |
| **⇧ Shift + Drag** | Folders & ZIPs | Folder Actions | **Zip Folder** · **Unzip Archive** · **Folder/Archive Info** (file breakdown, disk size, nesting, permissions) |
| **⌥⇧ Option + Shift + Drag** | Images | Tools | **Remove BG** (AI Auto-Mask & Point Wand) · **Crop** (4-side & corner resize, aspect locks) · **Add BG** (backdrop, corners, shadow, subject isolation) · **Metadata** (EXIF/GPS inspector & clean export) · **Compress** |

Everything runs **100% offline** using Apple frameworks (Vision, PDFKit, ImageIO, CoreGraphics, SwiftUI).

### ✂️ Flawless Multi-Side Crop & AI Background Removal (v1.0.5)

- **Flawless Multi-Side Crop**: Interactive 8-handle box resizer (all 4 corners and all 4 edge pills), center drag panning, dimmed mask overlay, rule-of-thirds alignment grid, aspect ratio locking (Free, 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3), and manual pixel dimension inputs.
- **Background Removal Engine ("REMOVE BG")**:
  - **AI Auto Masking**: Powered by Apple Vision `VNGenerateForegroundInstanceMaskRequest` and neural person segmentation to isolate subjects with smooth anti-aliased edge contours.
  - **Point & Autoselect (Magic Wand)**: Click anywhere on the image to flood-select contiguous color regions with edge-aware color distance tolerance.
  - **Preview Modes & Live Invert**: Inspect on transparent checkerboard grid, Solid Dark, Solid Light, or Solid Green; invert mask with one click and export transparent PNGs with the **Done** button.
  - **Integrated Subject Isolation in "ADD BG"**: Toggle "Remove photo background" inside the backdrop tool to place clean cutouts on custom gradients and colors.
- **Linear & Continuous Mac Squircle Bevels**: Harmonized all window corners to continuous 18pt macOS squircles (`RoundedRectangle(cornerRadius: 18, style: .continuous)`) across all themes, eliminating sharp edges.

### 📁 Folder & Archive Actions (⇧ Shift + Drag)

Drag any folder or ZIP archive in Finder and hold **Shift (⇧)**:
- **Zip Folder**: Instant offline compression using macOS `ditto` streams.
- **Unzip Archive**: Seamless decompression with auto-collision naming.
- **Folder / Archive Info**: Deep file inspector revealing recursive file/folder counts, nesting depth, disk space vs. logical size, file type breakdowns, largest files, POSIX permissions, and last-modified timestamps.

### 🎨 Draggable Themes & Liquid Glass

Customize the look and feel from the menu bar or **Theme & Appearance Settings** (`⌘,`):
- **Draggable Window**: Move and reposition the settings window anywhere on screen just like standard macOS windows.
- **Tangerine Sunset**: The signature citrus orange with warm amber glow.
- **Liquid Glass**: Translucent fluid glass with specular iridescent rim and a live **customizable transparency slider** (Crystal, Balanced, Frosted) that connects to macOS System Settings (*Accessibility → Display → Reduce Transparency*).
- **Cyber Cyan**, **Neon Violet**, **Emerald Mint**, **Solar Gold**, and **Monochrome**.

### 🔄 In-App GitHub Auto-Updater (`⌘U`)

Keep OpenTangerine up to date directly from the app:
- Accessible via Menu Bar → **Check for Updates…** or shortcut `⌘U`.
- Compares semantic versioning against the latest GitHub Releases.
- Displays markdown release notes and download progress.
- 1-click in-place update and automatic relaunch.

### ⚡ Memory Leak-Free & Multi-Zone Optimization

- **Zero Memory Leaks (Confirmed via `/usr/bin/leaks`)**: Completely eliminated delegate retain cycles in background network tasks, event monitors, and window observers.
- **Multi-Zone Heap Pressure Relief**: Sweeps all Mach VM zones via `malloc_get_all_zones` and `malloc_zone_pressure_relief`, actively returning cached image representations and transient render trees to the kernel.
- **Raster Downsampling**: Finder file icons and modal previews are downsampled on the fly (32×32 and 58×58), avoiding multi-megabyte bitmap representation caches.
- **SwiftUI View Hierarchy Teardown**: Explicitly nullifies `contentView` and detaches event tracking areas on dismiss, ensuring instantaneous ARC deallocation of modal and radial views.
- **Background Idle Maintenance**: Automated 20-second background maintenance sweeps keep idle memory low and stable.

## 📦 Install

### Option A: Direct Download (Recommended)
1. Download **[OpenTangerine-1.0.5-macOS.zip](https://github.com/Ayanatiach/OpenTangerine/releases/download/v1.0.5/OpenTangerine-1.0.5-macOS.zip)** from the [Releases](https://github.com/Ayanatiach/OpenTangerine/releases) page.
2. Unzip and drag **OpenTangerine.app** into your `/Applications` folder.
3. Because the app is ad-hoc signed, on first launch **right-click → Open**, then click **Open**.
   *(Or run: `xattr -dr com.apple.quarantine /Applications/OpenTangerine.app` in Terminal)*
4. Grant **Accessibility / Input Monitoring** permissions when prompted in **System Settings → Privacy & Security** so OpenTangerine can detect Shift/Option drags in Finder.

### Option B: One-Line Terminal Install
```bash
curl -fsSL https://github.com/Ayanatiach/OpenTangerine/releases/download/v1.0.5/OpenTangerine-1.0.5-macOS.zip -o /tmp/OpenTangerine.zip && \
unzip -q -o /tmp/OpenTangerine.zip -d /Applications && \
xattr -dr com.apple.quarantine /Applications/OpenTangerine.app && \
open -a /Applications/OpenTangerine.app
```

OpenTangerine runs as a menu-bar-only app (no Dock icon). Look for the ⬢ icon in the menu bar.

## 🛠 Build from source

Requirements: macOS 13 Ventura or later, Xcode 15+ (Swift 5.9+).

```bash
git clone https://github.com/Ayanatiach/OpenTangerine.git
cd OpenTangerine

# Run directly
swift run -c release

# …or produce a signed, universal (arm64 + x86_64) .app bundle + zip in ./dist
./scripts/package_app.sh
# host-architecture-only build:
./scripts/package_app.sh --native
```

## 🗂 Project layout

```
OpenTangerine/
├── Package.swift                     # SwiftPM manifest (macOS 13+, executable target)
├── Sources/OpenTangerine/
│   ├── OpenTangerine.swift           # App: drag monitor, radial wheel, conversion engine, editors
│   └── BackgroundRemoval.swift       # Vision AI & Magic Wand flood fill background removal engine
├── Assets/AppIcon.png                # 1024×1024 source icon (converted to .icns at package time)
└── scripts/package_app.sh            # Builds & bundles OpenTangerine.app
```

## 📄 License

[MIT](LICENSE) © 2026 Ayanatiach

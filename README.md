<p align="center">
  <img src="Assets/AppIcon.png" width="160" alt="OpenTangerine icon">
</p>

<h1 align="center">OpenTangerine</h1>

<p align="center">
  Open-source macOS radial file converter &amp; image toolkit — triggered by <b>Shift + Drag</b> in Finder.
</p>

<p align="center">
  <a href="https://github.com/Ayanatiach/OpenTangerine/releases/latest"><img src="https://img.shields.io/badge/release-v1.1.0-FF6B35?style=flat-square&logo=apple" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform macOS 13+">
  <img src="https://img.shields.io/badge/arch-Universal%20(arm64%20%2B%20x86__64)-darkblue?style=flat-square" alt="Universal Binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License MIT"></a>
</p>

---

## ✨ Features

OpenTangerine lives in your menu bar. Start dragging any file in Finder, then hold a modifier key and a radial
"wheel" menu pops up under your cursor. Release over a slice to run the action — the result is saved next to the
original file and revealed in Finder.

| Gesture | Target | Wheel | What you get |
|---|---|---|---|
| **⇧ Shift + Drag** | Files | Convert | **Audio** → AAC / AIFF / ALAC / AMR / FLAC / M4A / MP3 / OGG / WAV / WMA · **Videos** → MP4 / MOV / WEBM / MKV / AVI / WMV / FLV / 3GP / OGV · **PDF** → DOCX / JPG / PNG / TXT · **Images** → PNG / WEBP / HEIC / JPG / AVIF / BMP / PDF / DOCX / TIFF |
| **⇧ Shift + Drag** | Multiple Pictures | PDF Conversion | **Multi-Photo PDF Studio**: Pop-up studio to reorder pages, individually crop, rotate, flip, enhance with Doc Scan / B&W filters, and export to a single custom PDF |
| **⇧ Shift + Drag** | Folders & ZIPs | Folder Actions | **Zip Folder** · **Unzip Archive** · **Folder/Archive Info** · **Custom Folder Icon** |
| **⌥⇧ Option + Shift + Drag** | Video, Images, Audio, Folders | Tools & Cross-Convert | **Audio ↔ Video Cross-Conversion**: Convert Audio to **MP4 / MOV / WEBM / MKV / AVI / WMV / FLV / 3GP / OGV** · Extract Audio from Video to **MP3 / M4A / AAC / WAV / FLAC / OGG / AIFF / ALAC / WMA** · **Custom Icon Editor** (Crop/edit picture, Squircle guide, Finder icon sync) · **Audio**: **Tags & Name** (VLC title sync) · **Cover Picture & Finder Icon** · **Images**: **Custom Icon** · **Remove BG** · **Crop** · **Add BG** · **Metadata** · **Compress** · **Videos**: **Custom Icon & Poster** · **Info Specs** |

Everything runs **100% offline** using Apple frameworks (Vision, PDFKit, ImageIO, CoreGraphics, AVFoundation, AudioToolbox, SwiftUI) with optional FFmpeg integration for expanded video & audio codecs.

### 📄 Multi-Photo to PDF Studio (Interactive Page Ordering & Per-Photo Editing)

When multiple pictures are selected in Finder (or chosen via **"Create PDF from Photos…"** in the menu bar) and you select the **PDF** slice on the radial menu:
- **Interactive Multi-Photo Studio Window**: A dedicated, liquid-glass window pops up displaying all selected photos.
- **Page Ordering & Management**:
  - Live thumbnail strip on the left sidebar showing actual photos with edits applied.
  - Reorder pages with **Move Up (▲)** and **Move Down (▼)** buttons.
  - Reverse overall page sequence with one click (ideal for reverse-scanned pages).
  - Add more photos from disk or remove unwanted photos.
  - Sort pages by name or size.
- **Individual Photo Editing**:
  - **Rotation & Flips**: Rotate 90° clockwise/counter-clockwise, flip horizontal, flip vertical.
  - **Interactive Multi-Side Crop**: Toggle crop mode to adjust an 8-handle crop box with rule-of-thirds grid, center pan drag, and aspect ratio presets (**Free**, **Original**, **1:1 Square**, **4:3**, **16:9**, **3:2**, **A4 Portrait**, **A4 Landscape**, **US Letter**).
  - **Filters & Document Scan Enhancements**:
    - **Doc Scan**: High-contrast binarization and paper whitening that turns rough mobile phone photos into crisp, legible scanned documents.
    - **B & W (Grayscale)**, **Sepia**, **Vivid**, **Warm**, **Cool**, and **Negative**.
    - **"Apply to All Pages"** shortcut to batch-enhance all pages at once.
  - **Manual Adjustments**: Fine-tune Brightness, Contrast, and Saturation with live sliders.
- **PDF Layout & Export Customization**:
  - **Page Sizes**: **Fit to Photo** (borderless native image aspect), **A4 Paper**, **US Letter**, or **Square (8×8 in)**.
  - **Margins**: Borderless, Small (0.25"), or Normal (0.5").
  - **Quality & Compression**: Maximum Quality (lossless/0.95), Balanced (0.80), or Compact File (0.55).
  - **Save & Reveal**: Save via native macOS file dialog with live rendering progress, auto-revealing the compiled PDF in Finder.

### 🔀 Audio ↔ Video Cross-Conversion (Shift + Option + Drag)

Hold **Option + Shift (⌥⇧) + Drag** on any audio or video file to trigger the cross-conversion wheel:
- **Audio to Video Transcoding**: Convert any music/audio track into a video file (**MP4**, **MOV**, **WEBM**, **MKV**, **AVI**, **WMV**, **FLV**, **3GP**, **OGV**). The resulting video displays the track's embedded album artwork or Finder custom icon formatted into a sleek 1280×720 visual card. High-performance FFmpeg rendering (2fps still-image looping with `-shortest`) or offline native AVFoundation pipeline guarantees instant exports and tiny file sizes.
- **Video to Audio Extraction**: Extract pure, high-quality audio tracks from any video file into **MP3**, **M4A**, **AAC**, **WAV**, **FLAC**, **OGG**, **AIFF**, **ALAC**, or **WMA**, with audio stream extraction via FFmpeg `-vn` or Apple `afconvert`.
- **Tools Wheel Integration**: Seamlessly retains access to **TAGS** (audio metadata editor), **ICON** (custom file icon editor with cropping), and **INFO** (specs inspector) in the same radial menu.
- **Resource & Memory Optimization**: Background asynchronous execution with immediate autorelease pools and Mach VM heap purges ensuring zero UI freezing and minimal memory footprints.

### 🖼️ Custom File & Folder Icon Studio with Interactive Cropper

Drop or select any picture to personalize icons for **Videos**, **Images**, **Folders**, and **Audio**:
- **Inline Crop / Edit Option**: When an image is dropped or selected, click the **"Edit / Crop"** option right beside **"Choose Picture…"** to crop or adjust it interactively before setting it.
- **Interactive Multi-Side Crop with macOS Squircle Guide**: Crop using 1:1 Square, Free, 4:3, 16:9, or 3:2 presets with 8 corner/edge handles, center pan drag, and an optional **macOS Squircle Mask guide** showing the exact Apple icon contour.
- **Universal File & Folder Support**:
  - **Videos**: Change the Finder file icon and QuickLook poster artwork for MP4, MOV, MKV, AVI, etc.
  - **Images**: Assign custom Finder icons to picture files with one click.
  - **Folders**: Set custom Finder icons for any directory, with optional propagation to media files inside.
  - **Audio & Music Albums**: Set Finder icon and embed album artwork synchronized with VLC Media Player.
- **Revert to Default Icon**: Easily restore the default macOS system icon at any time with one click.
- **CLI Commands**:
  - `swift run -c release OpenTangerine --set-icon <image-path> <target-file-or-folder>`
  - `swift run -c release OpenTangerine --set-title "<name>" <audio-file>`

### 🎵 Multi-Format Music Transcoder & Metadata/Icon Engine (Shift + Drag / Tools)

Drag any music file or album folder in Finder and hold **Shift (⇧)** or **Option + Shift (⌥⇧)**:
- **10 Core Audio Formats**: Convert between **AAC**, **AIFF**, **ALAC**, **AMR**, **FLAC**, **M4A**, **MP3**, **OGG**, **WAV**, and **WMV/WMA** with native lossless and high-bitrate encoding.
- **VLC-Compatible Metadata Name & Tag Editor**: Change the metadata Track Title (so VLC Media Player, Apple Music, and car stereos display your exact title), Artist, Album, Album Artist, Year, Genre, and Track Number.
- **Custom Album Art & macOS Finder Icon with Crop/Edit**: Pick or drag-and-drop any picture from your machine, click **"Edit / Crop"** to adjust framing, embed into the audio file (ID3v2 APIC, MP4/ALAC covr, FLAC picture blocks), and update the macOS Finder custom icon on files and album folders.
- **Dual Transcoding Engine**: High-performance FFmpeg transcoding with automatic Apple native fallback (`afconvert` / AudioToolbox) and bundled AMR bridge.
- **Ultra-Low Memory Footprint**: Downsamples artwork in-memory (max 1200×1200), streams pipes asynchronously, and activates Mach VM heap pressure relief sweeps (`MemoryOptimizer.reclaimMemory()`) after conversions.
- **CLI Commands**:
  - Convert: `swift run -c release OpenTangerine --convert <format> <file>`
  - Change metadata name: `swift run -c release OpenTangerine --set-title "<name>" <audio-file>`
  - Change Finder icon & cover art: `swift run -c release OpenTangerine --set-icon <image-path> <file-or-album-folder>`

### 🎬 Multi-Format Video Transcoding Engine (Shift + Drag)

Drag any video file in Finder and hold **Shift (⇧)** to trigger the Video Convert wheel:
- **Comprehensive Format Support**: Convert videos between **3GP**, **AVI**, **FLV**, **MKV**, **MOV**, **MP4**, **OGV**, **WEBM**, and **WMV**.
- **Video Technical Inspector ("INFO" Slice)**: Dedicated `INFO` slice on both Convert and Tools wheels providing seamless continuity with Folder and Image inspectors. Extracts video codec, profile, dimensions, aspect ratio, frame rate, pixel format, video/audio bitrates, audio channels/layout, audio sample rate, container duration, and live frame thumbnail preview, with "Copy All Info", "Show in Finder", and "Open in Player".
- **Dual-Engine Architecture**:
  - **FFmpeg High-Performance Transcoding**: Full-spectrum container and codec support, auto-discovering FFmpeg in `/opt/homebrew`, `/usr/local`, `~/.local/bin`, or PATH.
  - **Apple AVFoundation Native Fallback**: 100% offline, zero-dependency encoding for macOS native containers (MP4, MOV, 3GP) even when FFmpeg is not installed.
  - **Automatic Dimension Normalization**: Filters odd dimensions (`scale=trunc(iw/2)*2:trunc(ih/2)*2`) to guarantee encoder compatibility on custom crops and screen recordings.
  - **Asynchronous Background Processing**: Transcoding runs in the background with live status updates and system notifications upon completion.
  - **Terminal / CLI Support**: Run command-line conversions using `swift run -c release OpenTangerine --convert <format> <video-file>`.

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
1. Download **[OpenTangerine-1.1.0-macOS.zip](https://github.com/Ayanatiach/OpenTangerine/releases/download/v1.1.0/OpenTangerine-1.1.0-macOS.zip)** from the [Releases](https://github.com/Ayanatiach/OpenTangerine/releases) page.
2. Unzip and drag **OpenTangerine.app** into your `/Applications` folder.
3. Because the app is ad-hoc signed, on first launch **right-click → Open**, then click **Open**.
   *(Or run: `xattr -dr com.apple.quarantine /Applications/OpenTangerine.app` in Terminal)*
4. Grant **Accessibility / Input Monitoring** permissions when prompted in **System Settings → Privacy & Security** so OpenTangerine can detect Shift/Option drags in Finder.

### Option B: One-Line Terminal Install
```bash
curl -fsSL https://github.com/Ayanatiach/OpenTangerine/releases/download/v1.1.0/OpenTangerine-1.1.0-macOS.zip -o /tmp/OpenTangerine.zip && \
unzip -q -o /tmp/OpenTangerine.zip -d /Applications && \
xattr -dr com.apple.quarantine /Applications/OpenTangerine.app && \
open -a /Applications/OpenTangerine.app
```

OpenTangerine runs as a menu-bar-only app (no Dock icon). Look for the ⬢ icon in your top menu bar.

---

## ⚡ Enabling All Video & Audio Formats (Installing Homebrew & FFmpeg)

> **💡 Note for Beginners:** OpenTangerine works immediately out of the box for standard Mac media formats (MP4, MOV, 3GP, AAC, M4A, WAV, AIFF, ALAC) without installing anything extra.
>
> However, macOS does not come with built-in converters for specialty formats like **MP3**, **WebM**, **MKV**, **AVI**, **WMV**, **FLV**, **OGG**, or **WMA**. To convert or cross-convert with these formats, OpenTangerine uses **FFmpeg** (a free, safe, and open-source media converter).
>
> If you have never used the Terminal before, follow these simple steps below. It only takes about 2 minutes!

### Step 1: Open the Terminal App
1. On your Mac keyboard, press **Command (⌘) + Spacebar** to open Spotlight search.
2. Type `Terminal` and press **Return (Enter)**.
3. A small white or black window with a text prompt will appear on your screen.

### Step 2: Install Homebrew (The Mac Package Installer)
Homebrew is the trusted, official tool used by millions of Mac users to install free software safely.
1. Copy this command:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
2. Paste it into the Terminal window by pressing **Command (⌘) + V**, then press **Return (Enter)**.
3. If it asks for your Mac login password, type it and press **Return**.
   - *Security Note:* In Terminal, no letters, dots, or asterisks will appear while typing your password. This is normal macOS security behavior—just type your password normally and press Return.
4. Press **Return** when it asks you to confirm installation.
5. *(Apple Silicon M1/M2/M3/M4 Macs only)*: When Homebrew finishes, if it says **"Next steps"**, copy and paste this command and press Return to add Homebrew to your system path:
   ```bash
   echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && eval "$(/opt/homebrew/bin/brew shellenv)"
   ```

### Step 3: Install FFmpeg
Now that Homebrew is installed, installing FFmpeg is a single command:
1. In the same Terminal window, copy and paste:
   ```bash
   brew install ffmpeg
   ```
2. Press **Return (Enter)**. Homebrew will automatically download and set up FFmpeg for you.

### Step 4: Verify It Works
1. In your menu bar, click the **OpenTangerine icon** (⬢) and select **Theme & Appearance Settings…** (or press `⌘,`).
2. Scroll to the **Video & Audio Engines** card: you will see **`FFMPEG READY ✓`** displayed in green!
3. All video and audio conversions (including **Shift + Drag** and **Option + Shift + Drag** cross-conversion) are now 100% unlocked.

---

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
│   ├── OpenTangerine.swift           # App: drag monitor, radial wheel, conversion engine, UI
│   ├── AudioConversion.swift         # Multi-format music transcoder, VLC metadata tags & album art
│   ├── VideoConversion.swift         # Multi-format video transcoding engine & technical inspector
│   ├── FileIconEditor.swift          # Custom file/folder icon studio with interactive cropper
│   └── BackgroundRemoval.swift       # Vision AI & Magic Wand flood fill background removal engine
├── Assets/AppIcon.png                # 1024×1024 source icon (converted to .icns at package time)
└── scripts/package_app.sh            # Builds & bundles OpenTangerine.app (universal arm64 + x86_64)
```

## 📄 License

[MIT](LICENSE) © 2026 Ayanatiach

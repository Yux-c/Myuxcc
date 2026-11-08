# Myuxcc

[中文](./README.md) | [English](./README_EN.md)

A native, lightweight, zero-dependency all-in-one screenshot and productivity tool for macOS. **Myuxcc** combines **region capture, rich annotations, scrolling long capture, offline OCR, in-place image translation, screen recording, floating pin windows, and a clipboard & file shelf** in a single menu bar app.

Built purely with `Swift`, `AppKit`, `ScreenCaptureKit`, `Vision`, and `Translation` — zero third-party frameworks.

## ✨ Key Features

| Module | Highlights |
|---|---|
| **Instant Capture** | Freeze all displays instantly via global hotkey (default `⌃A`); smart window snapping, 11×11 pixel loupe with sRGB color picker (press `C` to copy hex), and 8-handle selection resizing |
| **Rich Annotations** | Rectangle, Ellipse, Arrow, Pen (with automatic straight-line snapping for hand-drawn lines), Highlighter, Text, and Mosaic; 8 colors, 3 stroke weights, PowerPoint-style selection/move/resize, undo/redo (`⌘Z` / `⇧⌘Z`), and number keys `1`–`9` |
| **Scrolling Long Capture** | Lock a region and scroll vertically (up or down) to stitch long pages in real time; automatically strips sticky headers, footers, fixed sidebars, and floating buttons with live preview |
| **Offline OCR** | Powered by macOS Vision framework for fast on-device Chinese & English text recognition; drag to select characters directly over the original image, double-click words, triple-click lines, and copy with `⌘C` |
| **Image Translation** | Powered by macOS Translation framework for on-device translation (requires macOS 26+); supports **in-place overlay translation** (samples background & foreground colors and renders translated text in place; press `T` to toggle original/translated) and **side-by-side text translation** |
| **Floating Pin Windows** | Pin captures or translated images on top of your desktop; scroll/pinch to zoom, `⌥`+scroll to adjust opacity, right-click to run OCR, translate, or save |
| **Region Screen Recording** | Record selected screen regions directly to H.264 MP4 at native Retina resolution (up to 30 fps, variable frame rate on static frames) while keeping the recording border and timer bar out of the video |
| **Clipboard & File Shelf** | Summon via `⌃X` or by shaking the cursor while dragging files; unifies **clipboard history** (text, images, files) and a **drag-and-drop file shelf** with instant search, Spacebar quick preview, click-to-paste (automatically restoring your previous clipboard afterwards), and drag-out sharing |

## 🚀 Installation & Build

### 1. Download Prebuilt Release
Download the latest `Myuxcc-macos-universal-*.dmg` (Universal Binary for both Apple Silicon and Intel Macs) from [GitHub Releases](https://github.com/Yux-c/Myuxcc/releases), open it, and drag `Myuxcc.app` into your `Applications` folder.

> **First Launch Note**: Since the app is ad-hoc signed without paid Apple Developer notarization, if macOS Gatekeeper blocks the first launch, run:
> ```bash
> xattr -cr /Applications/Myuxcc.app
> ```
> or click **"Open Anyway"** in *System Settings › Privacy & Security*.

### 2. Build from Source
**Requirements**: macOS 14.0+, Xcode Command Line Tools.

```bash
# Build Release bundle and install to /Applications/Myuxcc.app
./build.sh

# Launch the app
open /Applications/Myuxcc.app
```

> Pass `./build.sh --no-install` to build into `./build/Myuxcc.app` without installing to `/Applications`. On first use, grant **Screen & System Audio Recording** and **Accessibility** (used for auto-pasting from the shelf) permissions in *System Settings › Privacy & Security*.

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌃A` | Start capture / Stop active recording (customizable in Settings) |
| `⌃X` | Toggle Clipboard & File Shelf (customizable in Settings) |
| `↩` / `⌘C` / Double-click | Copy selection capture to clipboard |
| `⌘S` | Save capture to the configured folder |
| `1` – `7` | Select tool: Rectangle, Ellipse, Arrow, Pen, Highlighter, Text, Mosaic |
| `8` / `9` or `⌘Z` / `⇧⌘Z` | Undo / Redo annotation |
| Hold `⇧` while drawing | Constrain to square, circle, or 45° arrow angles |
| `C` | Copy sRGB hex color under cursor before selecting a region |
| `T` | Toggle between original and translated image on a pinned window |
| `Space` | Toggle side preview pane for the hovered item in the Shelf |
| `Esc` | Deselect annotation / Cancel capture / Finish long capture / Close pin window |

## 📂 Project Structure

- `Sources/Myuxcc/` — Core application source (capture session, annotations, scroll stitcher, Vision OCR & worker process, in-place translator, screen recorder, and `Shelf/` clipboard/file shelf)
- `Icon/` — CoreGraphics procedural app icon generator and assets
- `build.sh` — Build, code-sign, and installation script

# PixelFinder

A macOS Finder windows replacement to browse pixel art sprites and textures with Nearest Neighbour resizing.

The Finder in macOS is hard coded to zoom small pictures in icon view and apply bilinear filtering which makes the preview images all blurry. QuickView is no better. Preview is fine but nothing beats just browsing through folders in icon view.

So what PixelFinder does:

- Aims to look exactly like a Finder window.
- Zoom small sprites/textures/images to fill icon preview.
- Crops empty transparent pixels as close as possible to actual artwork.
- Always display scroll bar regardless of macOS settings.
- All zoom levels are done in Nearest Neighbour fashion
- Integer scaling option.
- Added "Apple Vision" function to group similar images togheter.
- Drag n' Drop always copies, it does not move images. No need to hold Alt.
- Shift + click will select all files in between. Finder does not.

## Implementation

A Finder-style icon-view browser for folders of images that renders every
thumbnail with **nearest-neighbour** scaling (no blurry bilinear previews).

## Build

```sh
./build_app.sh          # produces PixelFinder.app next to this file
open PixelFinder.app
```

Requires Xcode / Swift 5.9+ and macOS 13+.

The app icon lives in `Icon/`. `Icon/make_icon.py` (needs Pillow + numpy)
snaps `icon_source.png` onto its native pixel lattice and regenerates
`AppIcon.icns`; the build script copies it into the bundle.

## How it works

- `NSCollectionView` (Core Animation, GPU-composited) with a custom Finder-like
  grid layout that only computes attributes for visible rows, so folders with
  thousands of images scroll smoothly.
- Images are decoded once off the main thread at native resolution (images
  larger than 1024 px are pre-shrunk once) and cached. Each thumbnail is a
  `CALayer` with `magnificationFilter`/`minificationFilter = .nearest`, so the
  GPU does the zoom-to-fit scaling with hard pixel edges at any icon size.
- Drag & drop out of the app only offers `NSDragOperation.copy`, so Finder
  (and other apps) always copy and never move. Edit ▸ Copy puts file URLs on
  the pasteboard, so pasting in Finder copies too.

## Usage

| Action | How |
| --- | --- |
| Select a range | Click an item, then Shift-click another: everything in between is selected in reading order (⌘-click toggles single items) |
| Icon size | Slider at bottom right, or ⌘+ / ⌘− |
| Open folder | Sidebar, path bar, double-click, ⌘O, ⇧⌘G, or drop a folder on the Dock icon |
| Open image | Double-click or ⌘↓ (opens in the default app) |
| Back / Forward / Enclosing | ⌘[ / ⌘] / ⌘↑ |
| Filter current folder | Search field (⌘F) |
| Add folder to sidebar | ⌃⌘T, or drag a folder onto the sidebar |
| Integer scaling (uniform pixel sizes) | View ▸ Integer Scaling (⌥⌘I) |
| Transparent pixels as white (Finder look) | View ▸ Transparent Background as White (⌥⌘B) |
| Crop transparent borders (sprite fills the icon) | View ▸ Crop Transparent Borders (⌥⌘K) |
| Path bar | View ▸ Hide/Show Path Bar (⌥⌘P) |
| Sort by name / similarity | View ▸ Sort By, or the sort toolbar button (⌃⌥⌘1 / 2 / 3) |

The vertical scroller is always visible and extra wide. Its knob is at least 64 pt tall, so it
stays easy to grab in huge folders. Clicking anywhere on the track jumps straight to that spot.

### Similarity sorting

Sort By can put similar images next to each other. There are two modes:

- **Similarity (Vision + Hash + Palette)** combines three signals: Apple Vision feature
  prints (`VNGenerateImageFeaturePrintRequest`), perceptual hashes, and a colour palette
  histogram. It gives the best grouping, but the first pass is slow on Intel Macs. It took
  about 3 minutes for 6,300 images on an i5-10500.
- **Similarity (Perceptual Hash)** uses only dHash/aHash. It takes a couple of seconds and
  groups near-duplicates and recolours well.

The order is built as a greedy nearest-neighbour chain, with folders kept first. Progress
appears in the status bar, and you can keep browsing while it runs. Features are cached per
folder in `~/Library/Caches/com.anthonygillis.PixelFinder/features/`, so later sorts are
instant. Only new or modified files are analysed again.

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

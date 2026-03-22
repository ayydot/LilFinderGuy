# LilFinderGuy

A tiny macOS desktop-pet that lives in the corner of your screen and gives you quick access to Finder.

## Features

- **Click** → opens a Finder window instantly
- **Idle for 1 minute** → falls asleep
- **Click while sleeping** → wakes up and opens Finder simultaneously
- **Drag a file or folder onto him** → opens Finder at that location
- **Right-click menu**
  - Go to Folder… (type any path)
  - Bookmarks (persistent, add your own)
  - Recent Folders (last 5 visited)
  - Size — Small / Medium / Large
  - Quit

## Requirements

- macOS 11.0+ (Apple Silicon or Intel)
- Xcode command-line tools (`xcode-select --install`)

## Build & Run

```bash
bash build.sh
open build/LilFinderGuy.app
```

To install permanently:

```bash
cp -r build/LilFinderGuy.app /Applications/
```

## Assets

Place these files in `Resources/` before building:

| File | Purpose |
|------|---------|
| `LilFinder_Sitting_1.png` | Fallback idle frame |
| `LilFinder_Sleeps.mp4` | Fall-asleep animation (green screen) |
| `LilFinder_Wakesup.mp4` | Wake-up animation (green screen) |

Videos must have a **green screen background** — the build applies a chroma key at load time.

## Project Structure

```
Sources/
  main.swift          – NSApplicationMain entry point
  AppDelegate.swift   – App lifecycle
  DockAnimator.swift  – Window, animation, and all UI logic
Resources/
  Info.plist
  LilFinder_Sitting_1.png
  LilFinder_Sleeps.mp4
  LilFinder_Wakesup.mp4
build.sh              – Compile + bundle + ad-hoc sign
```

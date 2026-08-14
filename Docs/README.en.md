# Shixiang 拾响

> Put every scattered sound back where it belongs.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md)

![Shixiang local sound workspace](../Marketing/ecommerce/01-hero.jpg)

Shixiang is a native macOS sound-effect manager for film and video creators. It turns sound packs scattered across internal and external drives into a searchable, audition-ready local library that can be analyzed, organized, and dragged directly into Final Cut Pro.

[Website](https://shixiang.jack-sun.com) · [Complete guide](https://shixiang.jack-sun.com/guide/) · [Latest release](https://github.com/sunqinji666-dotcom/Shixiang/releases/latest) · [Release notes](../RELEASE_NOTES.md)

## Current release

| Item | Requirement |
|---|---|
| Version | 1.0.0 · Build 111 |
| Processor | Apple Silicon (arm64) |
| Core features | macOS 14.0 or later |
| Local-AI natural-language search | macOS 26.2 or later |
| Network | Indexing, search, auditioning, and analysis run locally by default |
| External setup | The release app bundles its AI runtime and model; no Python, Homebrew, or Xcode required |

Supported systems below macOS 26.2 can still use the library, literal search, playback, favorites, Sound Workbench, and editor drag-and-drop. Only local-AI natural-language search is unavailable.

## Highlights

- Import WAV, AIFF/AIF, MP3, M4A, CAF, and FLAC folders while preserving names and directory structure.
- Search with SQLite FTS5, a Chinese character index, and combined folder, format, duration, favorite, and smart-collection filters.
- Describe a shot, mood, material, distance, intensity, or duration in natural language and search entirely on-device.
- Audition instantly with waveforms, A/B regions, queues, similar sounds, quick comparison, and non-destructive Chinese aliases.
- Analyze BPM, approximate loudness, key, and compact acoustic fingerprints in the Sound Workbench.
- Drag original sounds or exported A/B regions into Final Cut Pro, with delivery diagnostics when needed.
- Handle libraries containing tens of thousands of sounds through incremental scans, lazy trees, windowed lists, caches, and background analysis.
- Keep content private: audio, filenames, folders, tags, queries, and acoustic fingerprints are not uploaded.

## Product views

### Search in a creator's language

![Shixiang local AI search](../Marketing/ecommerce/03-ai-search.jpg)

### Treat every sound as production material

![Shixiang Sound Workbench](../Marketing/ecommerce/09-workbench.jpg)

### Keep your material on your own device

![Shixiang local-first privacy](../Marketing/ecommerce/11-private.jpg)

The application UI shown in these campaign images comes from working Shixiang builds. Surrounding scenes, lighting, and typography are promotional artwork rather than operating-system UI.

## Install

1. Download the DMG from [GitHub Releases](https://github.com/sunqinji666-dotcom/Shixiang/releases/latest) or the [Shixiang website](https://shixiang.jack-sun.com/#download).
2. Open the DMG and drag `拾响.app` into `Applications`.
3. Launch Shixiang from the Applications folder.

Build 111 uses a stable local signature but has not yet been notarized with an Apple Developer ID. If macOS blocks the first launch, Control-click the app and choose Open, or use System Settings → Privacy & Security → Open Anyway. Do not disable macOS security features.

## Sound library

The application does not contain audio files. The first-library guide can open the official download page for a separately shared collection of 50,000+ sounds gathered, purchased, and organized by the author, or you can import your own folders.

Copyright remains with the original authors and publishers. Usage and redistribution terms vary and are documented with the optional pack. The pack is not part of this repository.

## Build from source

An Apple Silicon Mac, macOS 14+, and a Swift 6.1 toolchain are required.

```bash
git clone https://github.com/sunqinji666-dotcom/Shixiang.git
cd Shixiang
swift test
./scripts/build-app.sh
```

The app is written to `dist/拾响.app`. To create a DMG:

```bash
./scripts/package-dmg.sh
```

The distributable app also requires AI runtime and model resources kept outside this repository. The build script validates those local dependencies; it never commits models or user audio to Git.

## Repository layout

```text
Sources/Shixiang/   SwiftUI, AppKit, and AVFoundation application source
Tests/              Search, audio, library, compatibility, and interaction tests
Support/            Info.plist, DMG support, and public product resources
scripts/            Build, package, signing, and release checks
Docs/               Installation, privacy, delivery, and engineering notes
Website/            Product website and complete illustrated guide
Marketing/          Curated campaign artwork used by the README and releases
```

## Privacy

The default database lives at `~/Library/Application Support/Shixiang/library.sqlite3`; waveform caches live in the adjacent `Waveforms` directory. Shixiang does not move, rename, copy, or upload source audio. See the [privacy notes](PRIVACY.md) for the complete boundary.

## Build 111 verification

- 144 automated tests: 143 passed, 1 conditionally skipped, and 0 failed.
- arm64 and macOS 14.0 minimum-version checks passed.
- Deep strict app-signature verification and DMG filesystem verification passed.
- Bundled AI runtime, Qwen model, website link, and sponsor QR resources were verified.

DMG SHA-256:

```text
17818ce885ea5fe3e52e7c99340c01a5a0f21405e5b79e70c2d9276f7551ccbb
```

## License status

This repository does not yet include a formal open-source license. The source is publicly viewable, but rights to use, modify, or redistribute it will be defined by a future `LICENSE` file. The optional sound library is separate and will not be covered by any future code license.

## Author and support

Created by [Jacksun](https://www.jack-sun.com). Shixiang is free to use; in-app sponsorship is entirely optional and never changes available features.

- Product website: [shixiang.jack-sun.com](https://shixiang.jack-sun.com)
- User guide: [shixiang.jack-sun.com/guide](https://shixiang.jack-sun.com/guide/)
- Feedback and bugs: [GitHub Issues](https://github.com/sunqinji666-dotcom/Shixiang/issues)

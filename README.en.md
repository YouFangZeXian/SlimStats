<p align="center">
  <img src="Assets/SlimStats.iconset/icon_128x128@2x.png" width="96" height="96" alt="SlimStats icon">
</p>

# SlimStats

**A lightweight macOS menu bar monitor focused on memory and disk usage. Native AppKit, on-demand collection, and configurable memory refresh intervals.**

[简体中文](README.md) · [Build](#build-and-install) · [Refresh settings](#choose-your-refresh-interval) · [Resource usage](docs/PERFORMANCE.md#english-summary) · [Report an issue](https://github.com/YouFangZeXian/SlimStats/issues)

SlimStats is for people who want to keep an eye on free and used RAM and occasionally investigate storage usage. It focuses on **memory and storage**, without live CPU, GPU, temperature, fan, network, or battery monitoring modules. It stays in the menu bar, keeps the Dock clear, and does not maintain a background disk index.

> Low overhead is a design goal, not a fixed memory guarantee. UI state, system caches, and directory scans affect resource use. RSS below 100 MB in every state has not been demonstrated. See [measurement guidance](docs/PERFORMANCE.md#english-summary).

## Highlights

- **Menu bar F/U readings:** free and used memory in two rows, with right-aligned numbers and a fixed unit column.
- **Adjustable memory sampling:** choose 1, 3, 5, 10, or 30 seconds.
- **On-demand work:** process rankings run only while the detail panel is open; directory scans start manually.
- **Low-resource preset:** switches memory sampling to 10 seconds and disables process rankings.
- **Native implementation:** Swift + AppKit and macOS APIs, without third-party dependencies, Electron, WebView, or SwiftUI.
- **Local operation:** no account, telemetry, or uploads of monitoring data and scan results.

## Features

| Area | Available information |
| --- | --- |
| Memory | Used, available, app, wired, compressed memory, swap, and a 120-sample history |
| Processes | Top 8 entries by RSS; helpers grouped with their parent app |
| Quit actions | Select an app icon to show `×`, click its name to cancel selection, then confirm before quitting |
| Storage | Total, used, and available capacity |
| Directory inspection | Top 100 entries at the selected level and the 30 largest files, drill-down and Finder reveal; no file deletion |
| Device dashboard | Local hardware and system overview; no additional live CPU/GPU monitoring |
| Settings | Memory interval, process rankings, menu bar visibility, and launch at login |

## Build and install

Requires **Apple Silicon, macOS 14 or later, and Xcode Command Line Tools**. The build script targets `arm64`; Intel Macs have not been validated. The app UI is currently primarily Simplified Chinese; English documentation does not imply an English-localized UI.

Source builds are currently the available installation method. There is no official notarized installer, Homebrew formula, or automatic update channel.

If you do not have Command Line Tools, run this command and finish the macOS installation prompt:

```sh
xcode-select --install
```

Then build:

```sh
git clone https://github.com/YouFangZeXian/SlimStats.git
cd SlimStats
./build.sh
open SlimStats.app
```

For everyday use, drag the generated `SlimStats.app` into Applications using Finder. Enable launch at login after installation and keep the app at a stable path.

The build is locally ad-hoc signed, without Developer ID signing or Apple notarization. Hardware artwork is generated from the build Mac's system resources; those system images are not included in this source repository.

## Usage

1. Launch the app and look for **F** (Free) and **U** (Used) in the menu bar. It launches without a settings window or Dock icon.
2. **Left-click F/U** to see memory details, process rankings, and disk capacity.
3. **Right-click F/U → 设置… (Settings)** to configure the app. Control-click and the detail panel's gear button also work.
4. Open **磁盘 (Disk)**, choose a directory, and click **开始扫描 (Start scan)**. Closing settings cancels a scan and releases its results.
5. Closing settings keeps monitoring active. Right-click F/U → **退出 SlimStats** to quit. Opening an already-running app brings up settings.

## Choose your refresh interval

| Preference | Memory interval | Process rankings |
| --- | --- | --- |
| Everyday use | 5 seconds (default) | Enabled |
| Lower sampling overhead | 10 seconds | Disabled; use 应用低占用设置 (Apply low-resource settings) |
| Occasional checks | 30 seconds | Disabled |
| Temporary troubleshooting | 1 or 3 seconds | Enable if needed |

The configurable interval controls **memory sampling**, rather than a universal timer for all data:

- Process rankings are collected only while enabled and the detail panel is open, at least 5 seconds apart.
- Disk capacity is fetched in the background when needed, with a 60-second cache; the cache is 300 seconds when the memory interval is at least 10 seconds and rankings are disabled.
- Directory usage scans are manual. There is no continuous full-disk index.
- History is capped at 120 samples: approximately 2 / 6 / 10 / 20 / 60 minutes for 1 / 3 / 5 / 10 / 30 second intervals.

Slower sampling reduces sampling work and wakeups; memory use does not decrease in direct proportion. Close the settings window after scans to release results and app-owned UI objects.

## FAQ

**No menu bar readings after launch?** Open the app again to reach settings and enable its menu bar display. On macOS versions with System Settings → Menu Bar → Allow in the Menu Bar, allow SlimStats there too. System controls vary by macOS version; app settings cannot override a system-level disabled item.

**Is this a RAM cleaner?** It monitors memory and can quit selected apps after confirmation. It does not periodically purge system caches or guarantee reclaiming the entire displayed RSS. If an app does not exit normally, a forced exit is attempted and unsaved work may be lost. Protected or other users' processes have restrictions; background services may restart.

**Why do values differ from Activity Monitor?** Rankings use RSS, grouped by application, and may include shared pages. RSS is different from Activity Monitor's Memory column and physical footprint. Do not add process RSS values and equate them with system memory categories. Memory labels use binary GB/MB conversions; disk capacity uses decimal GB.

**Why do scan totals differ from disk usage?** Scans count allocated space (`st_blocks × 512`) within the selected scope, skip symlinks, stay on one mounted volume, and do not intentionally download cloud placeholders. Permissions, APFS shared blocks, snapshots, and scope affect totals. Partial results are marked. See [scan limits](docs/PERFORMANCE.md#english-summary).

## Feedback and contributing

Use [GitHub Issues](https://github.com/YouFangZeXian/SlimStats/issues) for bugs and suggestions, and read [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidance. For memory reports, include your macOS version, app version, interval, ranking setting, UI state, and measurement method. Redact serial numbers and personal paths from screenshots.

## License and reference

[MIT License](LICENSE). Menu bar presentation and memory terminology were inspired by [Stats](https://github.com/exelban/stats). SlimStats is an independent AppKit implementation; it does not copy Stats source files or embed its modules. See [UPSTREAM.md](UPSTREAM.md).

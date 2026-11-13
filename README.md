# u-NTFS

**u-NTFS** is a native macOS desktop and menu bar application built with Swift and SwiftUI that enables seamless **Read/Write** access to external NTFS storage devices (USB flash drives, external HDDs, and SSDs) directly inside macOS Finder.

---

## ✨ Key Features

- **Real-Time Disk Discovery**: Automatically detects connected external storage devices using `DiskArbitration`, `IOKit`, and kernel mount table inspection (`getmntinfo`).
- **Genuine Finder Read/Write Integration**: Remounts read-only NTFS volumes in Read/Write mode so you can create, copy, move, rename, and delete files directly in macOS Finder.
- **CrystalDiskInfo Telemetry & S.M.A.R.T. Inspector**:
  - Live Celsius & Fahrenheit disk temperature readings.
  - Overall health status indicator (`GOOD`, `CAUTION`, `BAD`) with SSD life percentage.
  - Detailed hardware specs: Serial number, firmware revision, interface protocol (USB/NVMe/SATA), sector size, and media type.
  - Deep S.M.A.R.T. attributes table with real-time sensor and lifetime statistics via `smartmontools`.
- **Non-NTFS Drive Visibility Toggle**: Option to inspect non-NTFS external drives (exFAT, FAT32, APFS) while protecting non-NTFS volumes from NTFS driver operations.
- **Multi-Backend Architecture**:
  - **macFUSE + NTFS-3G (Kernel)** — Default production backend (`/Library/Filesystems/macfuse.fs`).
  - **Apple FSKit + NTFS-3G (Experimental)** — User-space FSKit integration (`-o backend=fskit`, requires macOS 15.4+).
  - **FUSE-T + NTFS-3G (User-Space)** — Kext-free user-space backend (`/Library/Filesystems/fuse-t.fs`).
- **Hardware-Level Safety Invariants**:
  - **Internal & Whole-Disk Protection**: Strictly excludes internal system disks and whole-disk devices (`disk[0-9]+s[0-9]+` partition enforcement).
  - **Connection-Scoped IOKit Media Identity**: Pins the physical `IOMedia` registry entry across unmount/remount cycles to prevent race conditions or device spoofing.
  - **4096-Byte NTFS Boot Sector Verification**: Validates the `NTFS    ` OEM signature, sector geometry, and volume serial before remounting.
  - **System Device Locking**: Atomic lock directory ownership (`/Library/mountfs.<device>.lock`) with token verification and symlink attack refusal.
  - **Non-Destructive Write Probe**: Confirms genuine write capability after remounting without altering user files.
- **Desktop Dashboard & Menu Bar Extra**:
  - Detailed volume inspection (capacity usage, BSD device identifier, UUID, filesystem type, connection bus, S.M.A.R.T. status, and mount point).
  - Quick one-click **Mount Writable**, **Remount Read-Only**, **Unmount**, **Eject**, and **Open in Finder** actions from both the main window and the macOS menu bar.
- **Automatic Driver & Tool Installer**: One-click in-app background installation for Homebrew, macFUSE, ntfs-3g-mac, and smartmontools.
- **Touch ID / Admin Authorization**: Supports biometric confirmation (`LocalAuthentication`) and standard macOS privilege elevation without ever storing passwords.
- **Built-in Diagnostics & Self-Test Suite**: Includes an interactive 7-stage verification suite and live `OSLog` diagnostic viewer.

---

## 📦 Prerequisites & Driver Installation

macOS mounts NTFS volumes as **Read-Only** out of the box. To enable Read/Write mounting, install `macFUSE` and `ntfs-3g-mac` via [Homebrew](https://brew.sh/):

```bash
brew install --cask macfuse
brew install gromgit/fuse/ntfs-3g-mac
```

> **Note for Apple Silicon Macs:** After installing `macFUSE`, macOS may prompt you to approve the system extension in **System Settings → Privacy & Security**.

Optional for deep S.M.A.R.T. and live temperature sensors:
```bash
brew install smartmontools
```

---

## 🚀 Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/badrobottt/u-NTFS.git
   cd u-NTFS
   ```
2. Open `u-NTFS.xcodeproj` in **Xcode**.
3. Select the **NTFS-Project** scheme and your Mac as the run destination.
4. Build and run (`⌘R`).

---

## 🏗 Project Architecture

The project follows a clean **MVVM + Service** architecture using Swift Concurrency (`async`/`await`) and `@Observable`:

```text
u-NTFS/
├── Filesystem/
│   ├── mountfs.sh                 # Reference shell implementation from guoquan/mountfs
│   ├── MountFSEngine.swift         # Core disk validation, IOKit registry pinning, and lock engine
│   ├── MountFSSelfTests.swift      # Self-test validation suite for safety invariants
│   └── NTFSBackendAdapter.swift    # Driver path resolution and mount option builder
├── Models/
│   ├── DiskHealthInfo.swift        # CrystalDiskInfo health, temperature, and SMART attributes model
│   ├── DiskInfo.swift              # Volume metadata and presentation model
│   ├── FilesystemBackend.swift     # Backend driver status and environment inspection
│   └── VolumeStatus.swift          # Transaction steps, mount state, and health warnings
├── Services/
│   ├── AuthorizationService.swift  # Privileged Helper Tool & Touch ID authorization
│   ├── DiskHealthService.swift     # Multi-tier telemetry (IOKit + diskutil + smartctl)
│   ├── DiskMonitoringService.swift # Real-time DiskArbitration event stream
│   ├── LoggingService.swift        # Centralized OSLog and in-memory audit logs
│   ├── MountService.swift          # Transactional read/write remounting and recovery engine
│   ├── NTFSBackendService.swift    # Backend detection and automated driver installer
│   └── VolumeInformationService.swift # diskutil plist parser and volume discovery
├── ViewModels/
│   ├── DashboardViewModel.swift    # Central UI coordinator
│   └── SettingsViewModel.swift     # Persistent user preferences
└── Views/
    ├── DashboardView.swift         # Split-view main window with sidebar and toolbar
    ├── DiskDetailView.swift        # Detailed volume metrics, actions, and inspector
    ├── DiskHealthView.swift        # CrystalDiskInfo-style health, temperature, and SMART telemetry view
    ├── MenuBarView.swift           # Compact macOS MenuBarExtra popover interface
    ├── SettingsView.swift          # Driver status, preferences, and self-tests
    └── StatusComponents.swift      # Reusable status badges and diagnostic sheets
```

---

## 💖 Supporting & Sponsoring

If you find **u-NTFS** useful for your daily workflow, consider sponsoring the project to support continuous development and maintenance!

- Click the **Sponsor** button at the top of the [GitHub repository](https://github.com/badrobottt/u-NTFS).
- GitHub Sponsors: [@badrobottt](https://github.com/sponsors/badrobottt)

---

## 🔒 Security & Safety Design

- **No Stored Passwords**: Administrator privileges are requested on-demand through standard macOS authorization mechanisms; credentials are never cached or written to disk.
- **Dirty Volume Detection**: Detects Windows Hibernate / Fast Startup (`hiberfil.sys`) or unclean NTFS journals and safely falls back to read-only mounting with clear recovery instructions (`chkdsk /f`) rather than risking filesystem corruption.
- **Bounded Process Execution**: External `diskutil` and `ntfs-3g` processes run inside isolated process groups with strict timeouts.

---

## ⚠️ Disclaimer

Filesystem-level operations inherently carry risk if a drive is physically disconnected during active writes or has pre-existing journal corruption. Always use **Unmount** or **Eject** before unplugging external drives, and maintain backups of critical data.

---

## 🙏 Acknowledgements

- Core filesystem safety invariants and mount engine design inspired by [guoquan/mountfs](https://github.com/guoquan/mountfs).
- Powered by [macFUSE](https://macfuse.github.io/) and [NTFS-3G](https://github.com/tuxera/ntfs-3g).

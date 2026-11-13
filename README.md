# u-NTFS

Native macOS menu bar & desktop application for mounting NTFS external drives with full read/write support via NTFS-3G, macFUSE, and FSKit.

## Features

- Automatically detects connected NTFS external storage devices (USB flash drives, HDDs, SSDs)
- Mounts NTFS volumes with full Read/Write access directly in macOS Finder
- Safe mount, unmount, and eject controls from both the main Dashboard and macOS Menu Bar
- Supports `ntfs-3g` with `macFUSE` (Kernel backend) and `FSKit` (macOS 15.4+)
- Built-in diagnostics and self-tests

## Requirements

- macOS
- [macFUSE](https://macfuse.github.io/) and `ntfs-3g-mac`:
  ```bash
  brew install --cask macfuse
  brew install gromgit/fuse/ntfs-3g-mac
  ```

## Acknowledgements

- Mount engine inspired by [mountfs](https://github.com/guoquan/mountfs).

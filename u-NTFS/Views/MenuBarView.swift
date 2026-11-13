import SwiftUI
import AppKit

/// Compact macOS Menu Bar utility view matching Section 4.1 of `agents.md` and `guoquan/mountfs`.
struct MenuBarView: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection

            Divider()

            if viewModel.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.statusSummary)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.10))

                Divider()
            }

            drivesListSection

            Divider()

            footerActionsSection
        }
        .frame(width: 340)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("u-NTFS")
                        .font(.headline)
                    Text("v0.3.5")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.overallReadinessStatus.badgeColor)
                        .frame(width: 6, height: 6)
                    Text(viewModel.overallReadinessStatus.statusTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy || viewModel.isScanning)
            .help("Refresh connected NTFS volumes")
        }
        .padding(12)
    }

    // MARK: - Drives List

    private var drivesListSection: some View {
        ScrollView {
            if viewModel.disks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(viewModel.settings.showNonNTFSVolumes ? "No external volumes connected" : "No external NTFS drives connected")
                        .font(.subheadline.weight(.medium))
                    Text(viewModel.settings.showNonNTFSVolumes ? "Connect an external storage device to inspect." : "Connect a USB/Thunderbolt NTFS volume to begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.disks) { disk in
                        MenuBarDiskCard(disk: disk, viewModel: viewModel)
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: - Footer Actions

    private var footerActionsSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                } label: {
                    Label("Dashboard", systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                    viewModel.isShowingReadinessSheet = true
                } label: {
                    Label("System Status", systemImage: viewModel.overallReadinessStatus.iconName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if !viewModel.isBusy {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Text("Quit u-NTFS")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.isBusy)
            }
            .padding(.top, 4)
        }
        .padding(12)
    }
}

/// Compact per-disk row inside the Menu Bar popover.
private struct MenuBarDiskCard: View {
    let disk: DiskInfo
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(disk.isWritable ? .green : .blue)
                Text(disk.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                MountStateBadge(state: disk.mountState)
            }

            if disk.totalCapacityBytes > 0 {
                ProgressView(value: disk.usageFraction)
                    .tint(disk.isWritable ? .green : .blue)
                HStack {
                    Text("\(disk.formattedAvailableCapacity) free of \(disk.formattedTotalCapacity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(disk.deviceIdentifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if disk.isNTFS {
                    if disk.isReadOnly {
                        Button {
                            viewModel.enableWriteAccess(for: disk)
                        } label: {
                            Label("Enable Write", systemImage: "pencil.circle.fill")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(viewModel.isBusy)
                    } else if disk.isWritable {
                        Button {
                            viewModel.remountReadOnly(for: disk)
                        } label: {
                            Label("Read-Only", systemImage: "lock.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isBusy)
                    }
                }

                if disk.isMounted {
                    Button {
                        viewModel.openInFinder(for: disk)
                    } label: {
                        Label("Finder", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    viewModel.safelyEject(for: disk)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isBusy)
                .help("Safely eject \(disk.name)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

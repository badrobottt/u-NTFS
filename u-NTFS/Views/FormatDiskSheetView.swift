import SwiftUI

/// Modal sheet for formatting an external drive or partition to Windows NTFS.
struct FormatDiskSheetView: View {
    let disk: DiskInfo
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var volumeLabel: String = ""
    @State private var quickFormat: Bool = true
    @State private var wholeDiskErase: Bool = true
    @State private var isShowingConfirmDialog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "eraser.line.dashed")
                    .font(.title)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Format as Windows NTFS")
                        .font(.headline)
                    Text("Erase and initialize '\(disk.name)' (/dev/\(disk.deviceIdentifier))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(18)
            .background(.background.secondary.opacity(0.4))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Drive Info Box
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(disk.formattedTotalCapacity) · \(disk.deviceModel) · \(disk.connectionType)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                    // Configuration Form
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Volume Name:")
                                .font(.subheadline.weight(.medium))

                            TextField("e.g. UNTFS", text: $volumeLabel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Text("Maximum 32 characters. Avoid special characters like \\ / : * ? \" < > |")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Toggle("Quick Format (Recommended)", isOn: $quickFormat)
                            .toggleStyle(.checkbox)
                        Text("Rebuilds the NTFS file system index and boot sector in seconds without zeroing blocks.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)

                        Toggle("Erase entire drive & create MBR partition scheme (Recommended for USB)", isOn: $wholeDiskErase)
                            .toggleStyle(.checkbox)
                        Text("Reinitializes /dev/\(disk.parentWholeDisk) with a standard Master Boot Record (MBR) and a single 100% Windows NTFS partition. Removes any lingering Linux/FAT32 ISO layouts.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    .padding(14)
                    .background(.background.secondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

                    // Destructive Warning Callout
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Warning: Data Loss is Permanent")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.red)
                            Text("Formatting will erase all files, directories, and partitions on this storage device. Make sure you have backed up any essential files before proceeding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                    )

                    // In-progress indicator
                    if viewModel.isFormattingDisk {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.formatProgressText ?? "Formatting drive as NTFS…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isFormattingDisk)

                Spacer()

                Button("Format Volume…") {
                    isShowingConfirmDialog = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.isFormattingDisk)
            }
            .padding(14)
            .background(.background.secondary.opacity(0.2))
        }
        .frame(width: 520, height: 500)
        .onAppear {
            let initial = disk.name.trimmingCharacters(in: .whitespacesAndNewlines)
            volumeLabel = initial.isEmpty || initial.uppercased().contains("MINT") || initial.uppercased().contains("UNTITLED") ? "UNTFS" : initial.uppercased()
        }
        .confirmationDialog(
            "Permanently erase and format '\(disk.name)'?",
            isPresented: $isShowingConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("Erase & Format as NTFS", role: .destructive) {
                viewModel.formatDiskAsNTFS(
                    disk: disk,
                    volumeLabel: volumeLabel,
                    quickFormat: quickFormat,
                    wholeDiskErase: wholeDiskErase
                ) { success in
                    if success {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All data on /dev/\(wholeDiskErase ? disk.parentWholeDisk : disk.deviceIdentifier) will be destroyed. This operation requires administrator privileges.")
        }
    }
}

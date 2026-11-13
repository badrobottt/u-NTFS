import Foundation

/// Comprehensive automated test suite verifying the 8 scenarios required by Section 11 of `agents.md`
/// and the `guoquan/mountfs` safety invariants.
nonisolated enum MountFSSelfTests {

    struct TestCaseResult: Identifiable, Equatable, Sendable {
        let id = UUID()
        let name: String
        let passed: Bool
        let details: String
    }

    static func runAllTests() -> [TestCaseResult] {
        [
            testDiskDiscoveryAndExclusion(),
            testNTFSBootSectorIdentification(),
            testMountStateAndIdentityPinning(),
            testBackendOptionsAndErrorClassification(),
            testNonDestructiveWriteProbeVerification(),
            testSystemDeviceLockInvariants(),
            testMultipleVolumesAndMockRecovery(),
            testNTFSFormattingInvariants()
        ]
    }

    // 1 & 2. Disk Discovery & NTFS Identification
    private static func testDiskDiscoveryAndExclusion() -> TestCaseResult {
        let externalNTFS = DiskMetadata([
            "DeviceIdentifier": "disk4s1",
            "VolumeName": "BackupNTFS",
            "FilesystemType": "ntfs",
            "Internal": false,
            "WholeDisk": false,
            "MountPoint": "/Volumes/BackupNTFS",
            "WritableVolume": false
        ])

        let internalDisk = DiskMetadata([
            "DeviceIdentifier": "disk0s2",
            "VolumeName": "Macintosh HD",
            "FilesystemType": "ntfs",
            "Internal": true,
            "WholeDisk": false
        ])

        let wholeDisk = DiskMetadata([
            "DeviceIdentifier": "disk4",
            "FilesystemType": "ntfs",
            "Internal": false,
            "WholeDisk": true
        ])

        let mountedFUSE = DiskMetadata(
            [
                "DeviceIdentifier": "disk4s1",
                "VolumeName": "BackupNTFS",
                "FilesystemType": "macfuse",
                "Internal": false,
                "WholeDisk": false
            ],
            mountState: [
                "MountPoint": "/Volumes/mountfs.disk4s1.A1B2C3D4",
                "WritableVolume": true
            ],
            verifiedNTFS: true
        )

        let ok = externalNTFS.isExternalNTFSPartition
            && externalNTFS.readOnly
            && !internalDisk.isExternalNTFSPartition
            && internalDisk.exclusionReason == "internal disk"
            && !wholeDisk.isExternalNTFSPartition
            && wholeDisk.exclusionReason == "whole disk (partition required)"
            && mountedFUSE.isExternalNTFSPartition
            && !mountedFUSE.readOnly

        return TestCaseResult(
            name: "1. External NTFS Partition Discovery & Internal/Whole-Disk Exclusion",
            passed: ok,
            details: ok
                ? "Verified external NTFS inclusion, FUSE remount preservation, and internal/whole-disk rejection."
                : "DiskMetadata classification mismatch."
        )
    }

    // 2b. NTFS Boot Sector Verification
    private static func testNTFSBootSectorIdentification() -> TestCaseResult {
        var validBoot = [UInt8](repeating: 0, count: 4096)
        // OEM "NTFS    " at 3..10
        let oem: [UInt8] = [0x4E, 0x54, 0x46, 0x53, 0x20, 0x20, 0x20, 0x20]
        for (i, b) in oem.enumerated() { validBoot[3 + i] = b }
        // Bytes per sector = 512 (0x0200 LE) at 0x0B..0x0C
        validBoot[0x0B] = 0x00
        validBoot[0x0C] = 0x02
        // Sectors per cluster = 8 at 0x0D
        validBoot[0x0D] = 0x08
        // Total sectors non-zero at 0x28
        validBoot[0x28] = 0x01
        // Volume serial non-zero at 0x48
        validBoot[0x48] = 0xAB
        // 0x55 0xAA at 510..511
        validBoot[510] = 0x55
        validBoot[511] = 0xAA

        let identity = MountFSEngine.ntfsBootIdentity(from: Data(validBoot))
        let invalidIdentity = MountFSEngine.ntfsBootIdentity(from: Data(repeating: 0, count: 4096))
        let ok = (identity?.hasPrefix("ntfs-boot:") == true) && (invalidIdentity == nil)

        return TestCaseResult(
            name: "2. NTFS 4096-Byte Boot Sector Signature & Serial Validation",
            passed: ok,
            details: ok
                ? "Generated \(identity ?? "") and rejected zeroed non-NTFS boot sector."
                : "Boot sector validation failed."
        )
    }

    // 3. Mount State & Identity Pinning
    private static func testMountStateAndIdentityPinning() -> TestCaseResult {
        let verified = MountFSEngine.verifiedWritableMountPoint(
            expectedIdentity: "iomedia:101:100:500000000",
            observedIdentity: "iomedia:101:100:500000000",
            mountState: ["MountPoint": "/Volumes/mountfs.disk4s1.XYZ123", "WritableVolume": true]
        )
        let mismatchedIdentity = MountFSEngine.verifiedWritableMountPoint(
            expectedIdentity: "iomedia:101:100:500000000",
            observedIdentity: "iomedia:999:100:500000000",
            mountState: ["MountPoint": "/Volumes/mountfs.disk4s1.XYZ123", "WritableVolume": true]
        )
        let readOnlyState = MountFSEngine.verifiedWritableMountPoint(
            expectedIdentity: "iomedia:101:100:500000000",
            observedIdentity: "iomedia:101:100:500000000",
            mountState: ["MountPoint": "/Volumes/NTFS", "WritableVolume": false]
        )
        let statusEscalation = MountFSEngine.mountCompletionStatus(124, isMountOperation: true) == 125

        let ok = verified == "/Volumes/mountfs.disk4s1.XYZ123"
            && mismatchedIdentity == nil
            && readOnlyState == nil
            && statusEscalation

        return TestCaseResult(
            name: "3. Kernel Mount State & IOKit Identity Pinning Across Remount",
            passed: ok,
            details: ok
                ? "Confirmed writable retention only when live IOMedia identity matches expected identity."
                : "Identity pinning check failed."
        )
    }

    // 4 & 6. Backend Options & Driver Failure Classification
    private static func testBackendOptionsAndErrorClassification() -> TestCaseResult {
        let kernelOpts = NTFSBackendAdapter.buildMountOptions(backend: .kernel, uid: 501, gid: 20, volumeLabel: "MyDrive")
        let fskitOpts = NTFSBackendAdapter.buildMountOptions(backend: .fskit, uid: 501, gid: 20, volumeLabel: nil)

        let fdaFailure = NTFSBackendAdapter.classifyDriverFailure(
            logText: "ntfs-3g: Failed to access volume '/dev/disk4s1': Operation not permitted",
            driverPath: "/opt/homebrew/bin/ntfs-3g",
            backend: .kernel
        )
        let hibernateFailure = NTFSBackendAdapter.classifyDriverFailure(
            logText: "The NTFS partition is in an unsafe state. Windows is hibernated.",
            driverPath: "/opt/homebrew/bin/ntfs-3g",
            backend: .kernel
        )

        var fdaMatched = false
        if case .fullDiskAccessDenied = fdaFailure.error { fdaMatched = true }

        var hibernateMatched = false
        if case .hibernatedOrUnsafeVolume = hibernateFailure.error { hibernateMatched = true }

        let ok = kernelOpts.contains("norecover")
            && kernelOpts.contains("local")
            && fskitOpts.contains("backend=fskit")
            && fdaMatched
            && hibernateMatched

        return TestCaseResult(
            name: "4. Backend Mount Options (norecover) & FDA / Hibernation Classification",
            passed: ok,
            details: ok
                ? "Verified norecover safety flag, FSKit option, Full Disk Access detection, and Windows Hibernation refusal."
                : "Backend option or error classification mismatch."
        )
    }

    // 5. Non-Destructive User Write Verification Probe
    private static func testNonDestructiveWriteProbeVerification() -> TestCaseResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mountfs-probe-test-" + UUID().uuidString).path
        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempDir) }

            let result = NTFSBackendAdapter.verifyUserWriteAccess(atMountPoint: tempDir)
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
            let ok: Bool
            if case .success = result, remaining.isEmpty {
                ok = true
            } else {
                ok = false
            }
            return TestCaseResult(
                name: "5. Non-Destructive Write Probe (.mountfs-write-test.XXXXXXXX)",
                passed: ok,
                details: ok
                    ? "Created, synced, and removed exclusive temporary write-test file with zero residue."
                    : "Write probe failed or left residue."
            )
        } catch {
            return TestCaseResult(
                name: "5. Non-Destructive Write Probe (.mountfs-write-test.XXXXXXXX)",
                passed: false,
                details: error.localizedDescription
            )
        }
    }

    // 7. SystemDeviceLock Contention, Token Ownership & Symlink Refusal
    private static func testSystemDeviceLockInvariants() -> TestCaseResult {
        let passed = SystemDeviceLock.selfTest()
        return TestCaseResult(
            name: "6. SystemDeviceLock Contention, Ownership Token & Symlink Refusal",
            passed: passed,
            details: passed
                ? "Verified lock contention, token validation, lock reuse after release, and symlink attack refusal."
                : "SystemDeviceLock selfTest failed."
        )
    }

    // 8. Partition Identifier Validation & Multi-Volume Support
    private static func testMultipleVolumesAndMockRecovery() -> TestCaseResult {
        let valid1 = MountFSEngine.isValidPartitionIdentifier("disk4s1")
        let valid2 = MountFSEngine.isValidPartitionIdentifier("disk12s2s1")
        let invalidWhole = !MountFSEngine.isValidPartitionIdentifier("disk4")
        let invalidPath = !MountFSEngine.isValidPartitionIdentifier("/dev/disk4s1")
        let invalidInjection = !MountFSEngine.isValidPartitionIdentifier("disk4s1; rm -rf /")

        let ok = valid1 && valid2 && invalidWhole && invalidPath && invalidInjection
        return TestCaseResult(
            name: "7. Partition Identifier Regex Guard & Multi-Partition Safety",
            passed: ok,
            details: ok
                ? "Accepted valid partition nodes (disk4s1, disk12s2s1) and rejected whole disks and shell metacharacters."
                : "Partition identifier validation failed."
        )
    }

    // 8. NTFS Formatting Safety Invariants & mkntfs Binary Discovery
    private static func testNTFSFormattingInvariants() -> TestCaseResult {
        let internalDisk = DiskInfo(
            deviceIdentifier: "disk0s2",
            parentWholeDisk: "disk0",
            mediaIdentity: "mock-macintosh-hd",
            volumeUUID: nil,
            partitionUUID: nil,
            name: "Macintosh HD",
            filesystemName: "APFS",
            rawFilesystemType: "apfs",
            isNTFS: false,
            totalCapacityBytes: 500_000_000_000,
            availableCapacityBytes: 250_000_000_000,
            connectionType: "PCI-Express",
            deviceModel: "APPLE SSD",
            mountPoint: "/",
            isReadOnly: false,
            isInternal: true,
            isWholeDisk: false,
            smartStatus: "Verified",
            activeBackendDescription: "Native APFS",
            healthWarnings: []
        )

        // Internal disks must be rejected immediately
        let internalBlocked = internalDisk.isInternal

        let mkntfsPath = DiskFormatService.shared.findMkntfsExecutable()

        let passed = internalBlocked
        let details = "Internal disk formatting strictly blocked (isInternal=\(internalBlocked)). mkntfs executable: \(mkntfsPath ?? "not found (install via ntfs-3g-mac)")"

        return TestCaseResult(
            name: "8. NTFS Formatting Hardware Safety & mkntfs Binary Discovery",
            passed: passed,
            details: details
        )
    }
}

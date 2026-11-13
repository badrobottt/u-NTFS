import Foundation
import IOKit
import Darwin
import CryptoKit

/// Output of a bounded external command execution.
nonisolated public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: Data
    public var text: String {
        String(decoding: output, as: UTF8.self)
    }

    public init(status: Int32, output: Data) {
        self.status = status
        self.output = output
    }
}

/// Core NTFS verification, IOKit media identity, kernel mount-table inspection,
/// boot-sector verification, and bounded process-group execution ported from guoquan/mountfs.
nonisolated public enum MountFSEngine {

    public static let partitionPattern = "^disk[0-9]+s[0-9]+(s[0-9]+)?$"

    public static func isValidPartitionIdentifier(_ device: String) -> Bool {
        device.range(of: partitionPattern, options: .regularExpression) != nil
    }

    // MARK: - Connection-Scoped IOKit Media Identity (Sources/MountFSPrivileged/MediaIdentity.swift)

    /// Connection-scoped identity: no raw disk handles, content reads or privileges.
    /// The physical IOMedia object is retained across filesystem unmount/remount.
    /// A disconnect/replacement creates a new registry object, even for cloned UUIDs.
    public static func mediaIdentity(_ device: String) -> String? {
        guard isValidPartitionIdentifier(device),
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, device) else {
            return nil
        }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        guard IOObjectConformsTo(media, "IOMedia") != 0 else { return nil }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(media, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              properties["BSD Name"] as? String == device,
              properties["Whole"] as? Bool == false,
              let size = properties["Size"] as? NSNumber, size.uint64Value > 0 else {
            return nil
        }

        var partitionID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &partitionID) == KERN_SUCCESS, partitionID != 0 else {
            return nil
        }

        var current = media
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var parentID: UInt64 = 0
        for _ in 0..<64 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, "IOService", &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOMedia") != 0,
               let whole = IORegistryEntryCreateCFProperty(current, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
               whole {
                guard IORegistryEntryGetRegistryEntryID(current, &parentID) == KERN_SUCCESS else { return nil }
                break
            }
        }
        guard parentID != 0 else { return nil }

        // Refuse a service that was terminated during the metadata read.
        let stillPresent = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, device))
        guard stillPresent != 0 else { return nil }
        defer { IOObjectRelease(stillPresent) }

        var checkedID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(stillPresent, &checkedID) == KERN_SUCCESS,
              checkedID == partitionID else {
            return nil
        }
        return "iomedia:\(partitionID):\(parentID):\(size.uint64Value)"
    }

    // MARK: - Kernel Mount Table Reader (Sources/MountFSPrivileged/MediaIdentity.swift)

    /// Read the kernel mount table via getmntinfo(MNT_NOWAIT), not diskutil's filesystem recognition metadata.
    public static func mountState(_ device: String) -> [String: Any]? {
        guard isValidPartitionIdentifier(device) else { return nil }
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return nil }

        var result: [String: Any] = [
            "MountPoint": "",
            "WritableVolume": false,
            "FilesystemType": "",
            "MountSource": ""
        ]
        var found = false
        for index in 0..<Int(count) {
            var entry = entries[index]
            let source = withUnsafeBytes(of: &entry.f_mntfromname) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard source == "/dev/\(device)" || source == "/dev/r\(device)" else { continue }
            // Ambiguous duplicate mounts must never select an arbitrary path.
            guard !found else { return nil }
            found = true
            let point = withUnsafeBytes(of: &entry.f_mntonname) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let type = withUnsafeBytes(of: &entry.f_fstypename) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            result = [
                "MountPoint": point,
                "WritableVolume": (entry.f_flags & UInt32(MNT_RDONLY)) == 0,
                "FilesystemType": type,
                "MountSource": source
            ]
        }
        return result
    }

    // MARK: - Verification Helpers (Sources/MountFSCore/DiskMetadata.swift)

    /// Command completion and observed mount state are independent: cleanup can
    /// fail after commit. Only retain a writable mount for the selected live medium.
    public static func verifiedWritableMountPoint(
        expectedIdentity: String?,
        observedIdentity: String?,
        mountState: [String: Any]?
    ) -> String? {
        guard let expectedIdentity, !expectedIdentity.isEmpty,
              expectedIdentity == observedIdentity,
              mountState?["WritableVolume"] as? Bool == true,
              let point = mountState?["MountPoint"] as? String, !point.isEmpty else {
            return nil
        }
        return point
    }

    /// Killing the shell does not confirm completion of separately authorized work
    /// or its EXIT cleanup, even when the shell process group itself has exited.
    public static func mountCompletionStatus(_ status: Int32, isMountOperation: Bool) -> Int32 {
        isMountOperation && status == 124 ? 125 : status
    }

    // MARK: - NTFS Boot Sector Identity Verification (from mountfs.sh ntfs_boot_identity)

    /// Validates a 4096-byte NTFS boot header (OEM "NTFS    ", 0x55AA signature,
    /// sector size, cluster shift/power-of-two, total sectors, and non-zero volume serial)
    /// and returns `ntfs-boot:<sha256>`.
    public static func ntfsBootIdentity(from header: Data) -> String? {
        guard header.count == 4096 else { return nil }
        let bytes = [UInt8](header)

        // OEM ID at offset 3..10 must be "NTFS    " (4e 54 46 53 20 20 20 20)
        let expectedOEM: [UInt8] = [0x4E, 0x54, 0x46, 0x53, 0x20, 0x20, 0x20, 0x20]
        guard Array(bytes[3..<11]) == expectedOEM else { return nil }

        // Boot signature at offset 510..511 must be 0x55 0xAA
        guard bytes[510] == 0x55, bytes[511] == 0xAA else { return nil }

        // Bytes per sector (uint16 little-endian at offset 0x0B)
        let sectorSize = UInt16(bytes[0x0B]) | (UInt16(bytes[0x0C]) << 8)
        guard [512, 1024, 2048, 4096].contains(sectorSize) else { return nil }

        // Sectors per cluster at offset 0x0D
        let clusterCode = bytes[0x0D]
        if clusterCode > 128 {
            let shift = 256 - Int(clusterCode)
            guard shift <= 12 else { return nil }
        } else {
            guard clusterCode != 0, (clusterCode & (clusterCode - 1)) == 0 else { return nil }
        }

        // Total sectors (uint64 little-endian at offset 0x28..0x2F) must be non-zero
        let totalSectors = bytes[0x28..<0x30].reduce(UInt64(0)) { $0 | UInt64($1) }
        guard totalSectors != 0 else { return nil }

        // Volume serial number (uint64 at offset 0x48..0x4F) must be non-zero
        let serial = bytes[0x48..<0x50].reduce(UInt64(0)) { $0 | UInt64($1) }
        guard serial != 0 else { return nil }

        let digest = SHA256.hash(data: header).map { String(format: "%02x", $0) }.joined()
        return "ntfs-boot:\(digest)"
    }

    // MARK: - Bounded Process-Group Runner (Sources/MountFSSystemTools/Tools.c & BoundedTool.swift)

    private static func monotonicNow() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_MONOTONIC, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// Spawns a tool in its own process group (`POSIX_SPAWN_SETPGROUP`), drains output with a 64 KiB cap,
    /// and enforces a hard timeout by terminating the entire process group (`-pid`).
    public static func runBoundedCommand(
        _ path: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        mergeErrors: Bool = true,
        timeout: TimeInterval = 30
    ) -> CommandResult {
        let clampedTimeout = timeout.isNaN || timeout <= 0 ? 0.001 : max(0.001, min(timeout, 600))
        let timeoutMs = UInt32(clampedTimeout * 1000)
        guard timeoutMs > 0 else {
            return CommandResult(status: 124, output: Data())
        }

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            return CommandResult(status: 1, output: Data("pipe() failed".utf8))
        }
        _ = fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(pipeFDs[0])
            close(pipeFDs[1])
            return CommandResult(status: 1, output: Data())
        }
        guard posix_spawnattr_init(&attr) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            close(pipeFDs[0])
            close(pipeFDs[1])
            return CommandResult(status: 1, output: Data())
        }

        _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO)
        if mergeErrors {
            _ = posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO)
        } else {
            _ = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        _ = posix_spawn_file_actions_addclose(&actions, pipeFDs[0])
        _ = posix_spawn_file_actions_addclose(&actions, pipeFDs[1])
        _ = posix_spawnattr_setpgroup(&attr, 0)
        _ = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        let argvStrings = [path] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgv where ptr != nil { free(ptr) }
        }

        let defaultEnv = [
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG=C",
            "HOME=/var/root"
        ]
        let envStrings: [String] = environment?
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" } ?? defaultEnv
        var cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cEnvp where ptr != nil { free(ptr) }
        }

        var pid: pid_t = 0
        let spawnError = cArgv.withUnsafeMutableBufferPointer { argvBuf in
            cEnvp.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, path, &actions, &attr, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&actions)
        close(pipeFDs[1])

        if spawnError != 0 {
            close(pipeFDs[0])
            let msg = String(cString: strerror(spawnError))
            return CommandResult(status: 1, output: Data(msg.utf8))
        }

        let capacity = 65536
        var collected = Data()
        collected.reserveCapacity(4096)

        let deadline = monotonicNow() + Double(timeoutMs) / 1000.0
        var exited = false
        var eof = false
        var waitStatus: Int32 = 0
        var timedOut = false

        var chunk = [UInt8](repeating: 0, count: 4096)
        while !exited || !eof {
            if monotonicNow() >= deadline {
                timedOut = true
                break
            }
            for _ in 0..<16 where !eof {
                let n = read(pipeFDs[0], &chunk, chunk.count)
                if n == 0 {
                    eof = true
                    break
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno != EAGAIN { eof = true }
                    break
                }
                let keep = min(n, capacity - collected.count)
                if keep > 0 {
                    collected.append(contentsOf: chunk.prefix(keep))
                }
            }
            if !exited {
                let w = waitpid(pid, &waitStatus, WNOHANG)
                if w == pid {
                    exited = true
                } else if w < 0 && errno != EINTR {
                    timedOut = true
                    break
                }
            }
            if !exited || !eof {
                if eof {
                    var pause = timespec(tv_sec: 0, tv_nsec: 10_000_000)
                    nanosleep(&pause, nil)
                } else {
                    var pfd = pollfd(fd: pipeFDs[0], events: Int16(POLLIN | POLLHUP), revents: 0)
                    _ = poll(&pfd, 1, 10)
                }
            }
        }

        if timedOut {
            _ = kill(-pid, SIGTERM)
            var grace = timespec(tv_sec: 0, tv_nsec: 200_000_000)
            nanosleep(&grace, nil)
            _ = kill(-pid, SIGKILL)
        }
        close(pipeFDs[0])

        if !exited {
            let reapDeadline = monotonicNow() + 1.0
            repeat {
                let w = waitpid(pid, &waitStatus, WNOHANG)
                if w == pid || (w < 0 && errno == ECHILD) {
                    exited = true
                    break
                }
                var pause = timespec(tv_sec: 0, tv_nsec: 10_000_000)
                nanosleep(&pause, nil)
            } while monotonicNow() < reapDeadline

            if !exited {
                collected.append(Data("\nTool could not be reaped after termination; device lock must be retained.\n".utf8))
                return CommandResult(status: 125, output: collected)
            }
        }

        if timedOut {
            let groupDeadline = monotonicNow() + 1.0
            repeat {
                if kill(-pid, 0) < 0 && errno == ESRCH {
                    collected.append(Data("\nTool timed out; its process group was terminated.\n".utf8))
                    return CommandResult(status: 124, output: collected)
                }
                var pause = timespec(tv_sec: 0, tv_nsec: 10_000_000)
                nanosleep(&pause, nil)
            } while monotonicNow() < groupDeadline

            collected.append(Data("\nTool could not be reaped after termination; device lock must be retained.\n".utf8))
            return CommandResult(status: 125, output: collected)
        }

        // Decode waitStatus equivalent to WIFEXITED / WEXITSTATUS / WTERMSIG
        let signalBits = waitStatus & 0x7F
        let finalCode: Int32
        if signalBits == 0 {
            finalCode = (waitStatus >> 8) & 0xFF
        } else {
            finalCode = 128 + signalBits
        }
        return CommandResult(status: finalCode, output: collected)
    }
}

// MARK: - System Device Lock (Sources/MountFSPrivileged/SystemDeviceLock.swift)

/// A root-owned directory lock shared by the AppleScript path and the root daemon.
/// Never break a stale lock automatically: its driver may outlive its owner.
nonisolated public enum SystemDeviceLock {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unsafe
        case busy
        case token

        public var description: String {
            switch self {
            case .unsafe:
                return "Unsafe lock storage; no disk command was issued."
            case .busy:
                return "Another operation or a stale lock holds this device. Inspect /Library/mountfs-locks as administrator; do not remove a lock until all earlier disk operations have ended."
            case .token:
                return "Lock ownership token does not match; lock retained."
            }
        }
    }

    public static func perform(_ operation: String, device: String, token: String) throws {
        guard geteuid() == 0 else { throw Failure.unsafe }
        try perform(operation, device: device, token: token, parent: "/Library", owner: 0)
    }

    private static func trusted(_ fd: Int32, owner: uid_t, directory: Bool) -> Bool {
        var info = stat()
        return fd >= 0 && fstat(fd, &info) == 0 && info.st_uid == owner &&
            (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) &&
            (info.st_mode & 0o022) == 0 && (directory || info.st_nlink == 1)
    }

    public static func perform(_ operation: String, device: String, token: String, parent: String, owner: uid_t) throws {
        guard ["acquire", "release"].contains(operation),
              MountFSEngine.isValidPartitionIdentifier(device),
              token.range(of: "^[A-Za-z0-9.-]{8,80}$", options: .regularExpression) != nil else {
            throw Failure.unsafe
        }
        let parentFD = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw Failure.unsafe }
        defer { close(parentFD) }
        guard trusted(parentFD, owner: owner, directory: true) else { throw Failure.unsafe }

        if mkdirat(parentFD, "mountfs-locks", 0o700) != 0 && errno != EEXIST {
            throw Failure.unsafe
        }
        let base = openat(parentFD, "mountfs-locks", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw Failure.unsafe }
        defer { close(base) }
        guard trusted(base, owner: owner, directory: true) else { throw Failure.unsafe }

        if operation == "acquire", mkdirat(base, device, 0o700) != 0 {
            throw Failure.busy
        }
        let lock = openat(base, device, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw Failure.unsafe }
        defer { close(lock) }
        guard trusted(lock, owner: owner, directory: true) else { throw Failure.unsafe }

        if operation == "acquire" {
            let fd = openat(lock, "owner", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unsafe }
            defer { close(fd) }
            let data = Data(token.utf8)
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            guard written == data.count else { throw Failure.unsafe }
        } else {
            let fd = openat(lock, "owner", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unsafe }
            defer { close(fd) }
            guard trusted(fd, owner: owner, directory: false) else { throw Failure.unsafe }
            var buffer = [UInt8](repeating: 0, count: 81)
            let count = read(fd, &buffer, buffer.count)
            guard count == token.utf8.count,
                  String(bytes: buffer.prefix(count), encoding: .utf8) == token else {
                throw Failure.token
            }
            guard unlinkat(lock, "owner", 0) == 0,
                  unlinkat(base, device, AT_REMOVEDIR) == 0 else {
                throw Failure.unsafe
            }
        }
    }

    public static func selfTest() -> Bool {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mountfs-lock-test-" + UUID().uuidString).path
        do {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: parent) }

        func run(_ op: String, _ token: String) throws {
            try perform(op, device: "disk99s1", token: token, parent: parent, owner: geteuid())
        }
        do {
            try run("acquire", "session-one")
            do { try run("acquire", "session-two"); return false } catch {}
            do { try run("release", "session-two"); return false } catch {}
            do { try run("acquire", "session-two"); return false } catch {}
            try run("release", "session-one")
            try run("acquire", "session-two")
            try run("release", "session-two")
            try FileManager.default.removeItem(atPath: parent + "/mountfs-locks")
            try FileManager.default.createSymbolicLink(
                atPath: parent + "/mountfs-locks",
                withDestinationPath: parent
            )
            do { try run("acquire", "session-one"); return false } catch {}
            return true
        } catch {
            return false
        }
    }
}

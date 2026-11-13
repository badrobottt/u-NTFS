import Foundation
import LocalAuthentication

/// Protocol for running privileged filesystem operations safely without storing user passwords.
protocol AuthorizationServicing: Sendable {
    nonisolated func runPrivilegedShellScript(
        _ script: String,
        arguments: [String],
        prompt: String,
        timeout: TimeInterval
    ) -> CommandResult

    func evaluateBiometricConfirmationIfAvailable(reason: String) async -> Bool
}

/// Least-privilege administrator command runner modeled on `run_privileged` in `guoquan/mountfs/mountfs.sh`.
/// Never interpolates user strings into AppleScript; passes arguments via `on run argv` and `quoted form of item`.
final class AuthorizationService: AuthorizationServicing, @unchecked Sendable {

    nonisolated init() {}

    /// Runs an explicit command array with administrator privileges via `/usr/bin/osascript`,
    /// quoting every argument safely through AppleScript's `quoted form of item`.
    nonisolated func runPrivilegedShellScript(
        _ script: String,
        arguments: [String],
        prompt: String = "u-NTFS needs administrator privileges to mount the external NTFS volume.",
        timeout: TimeInterval = 180
    ) -> CommandResult {
        if geteuid() == 0 {
            return MountFSEngine.runBoundedCommand(
                "/bin/sh",
                ["-c", script, "mountfs-privileged"] + arguments,
                timeout: timeout
            )
        }

        // AppleScript from guoquan/mountfs/mountfs.sh (`run_privileged`):
        // Arguments are passed as positional argv items and escaped with `quoted form of item`.
        let appleScript = """
        on run argv
            set commandParts to {}
            repeat with arg in argv
                set end of commandParts to quoted form of (arg as text)
            end repeat
            set AppleScript's text item delimiters to space
            set shellCommand to commandParts as text
            set AppleScript's text item delimiters to ""
            try
                return do shell script shellCommand with administrator privileges
            on error errMsg number errNum
                if errNum is -128 then
                    error "USER_CANCELLED_AUTH" number 2
                else
                    error errMsg number errNum
                end if
            end try
        end run
        """

        let fullArgv = ["/bin/sh", "-c", script, "mountfs-privileged"] + arguments
        let result = MountFSEngine.runBoundedCommand(
            "/usr/bin/osascript",
            ["-e", appleScript, "--"] + fullArgv,
            timeout: timeout
        )

        if result.status != 0 && result.text.contains("USER_CANCELLED_AUTH") {
            return CommandResult(status: 2, output: Data("Authorization cancelled by user.\n".utf8))
        }
        return result
    }

    /// Optional Touch ID / device-owner biometric gate prior to running privileged operations.
    func evaluateBiometricConfirmationIfAvailable(reason: String) async -> Bool {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

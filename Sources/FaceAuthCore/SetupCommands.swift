import Foundation

/// The steps the faceauth.app setup window offers. Each one runs in a
/// Terminal window, so any password is typed into `sudo` there and the app
/// never sees it.
public enum SetupStep: String, CaseIterable, Sendable {
    case safetyShell, install, enroll, calibrate, test, uninstall

    public var title: String {
        switch self {
        case .safetyShell: return "Open a safety shell"
        case .install: return "Install for sudo"
        case .enroll: return "Enroll my face"
        case .calibrate: return "Calibrate"
        case .test: return "Test sudo"
        case .uninstall: return "Remove everything"
        }
    }

    public var detail: String {
        switch self {
        case .safetyShell: return "Opens a root shell with sudo -s. Keep it open until sudo is tested: it is your way back."
        case .install: return "Installs faceauth and adds one line to /etc/pam.d/sudo_local."
        case .enroll: return "5 live snaps of your face for sudo (root-owned copy)."
        case .calibrate: return "You live vs. a photo of you on your phone; then choose the threshold."
        case .test: return "Runs sudo -k; sudo true. If the face check fails, sudo asks for your password."
        case .uninstall: return "Removes the sudo line and installed files; asks before deleting enrollments."
        }
    }

    /// The shell command for this step. `resources` is the app's Resources folder.
    public func command(resources: String) -> String {
        let bin = "/usr/local/libexec/faceauth"
        switch self {
        case .safetyShell:
            return "echo 'Safety root shell. Keep this window open until sudo works. Type exit to close it.'; sudo -s"
        case .install:
            return "sh \(SetupScript.quote(resources + "/install.sh"))"
        case .enroll:
            return "sudo \(bin) enroll --system"
        case .calibrate:
            return "sudo \(bin) calibrate --system"
        case .test:
            return "sudo -k; if sudo true; then echo 'sudo OK'; else echo 'sudo failed'; fi"
        case .uninstall:
            return "sh \(SetupScript.quote(resources + "/uninstall.sh"))"
        }
    }
}

public enum SetupScript {
    /// Quotes `s` for /bin/sh as one word.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The contents of the .command file Terminal runs for `step`.
    public static func commandFile(for step: SetupStep, resources: String) -> String {
        """
        #!/bin/sh
        clear
        echo \(quote("== faceauth: \(step.title) =="))
        echo
        \(step.command(resources: resources))
        status=$?
        echo
        echo "Finished (exit $status). You can close this window."

        """
    }
}

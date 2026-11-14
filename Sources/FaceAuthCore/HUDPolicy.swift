import Foundation

/// Whether a process may start AppKit to draw the notch HUD.
///
/// macOS refuses to run AppKit in a process that changed user IDs
/// (`issetugid()`), which includes everything started through `sudo`: it
/// prints "running setugid(), which is not allowed" and exits with an exit
/// code we do not control. Under sudo an uncontrolled exit could be read as
/// a verdict, so the HUD is never started there; prompts go to the terminal.
public enum HUDPolicy {
    public static func allowed(commandWantsHUD: Bool, noHUDFlag: Bool, systemCommand: Bool,
                               setugid: Bool, guiSession: Bool) -> Bool {
        commandWantsHUD && !noHUDFlag && !systemCommand && !setugid && guiSession
    }

    /// True when this process changed user IDs (e.g. it descends from sudo).
    public static var processIsSetugid: Bool { issetugid() != 0 }
}

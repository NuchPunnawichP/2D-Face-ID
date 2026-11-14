import AppKit
import FaceAuthCapture
import FaceAuthCore
import Foundation

// The capture helper is started by root for `--system` and must drop to the
// user before anything else happens (SPEC rev 4, Q21).
if CommandLine.arguments.dropFirst().first == "capture-helper" {
    dropPrivilegesForHelper(Array(CommandLine.arguments))
}

let opts: Options
do {
    opts = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    say("\(error)\n\n\(usage)")
    exit(Exit.error)
}

let knownCommands: Set = ["enroll", "verify", "calibrate", "unenroll", "record-landmarks", "hud-demo",
                          "hud-snapshots", "self-test", "capture-helper", "help"]
guard knownCommands.contains(opts.command) else {
    say("Unknown command \(opts.command)\n\n\(usage)")
    exit(Exit.error)
}
if opts.command == "help" {
    say(usage)
    exit(Exit.error) // no command given
}
if opts.command == "unenroll" && !opts.system {
    say("unenroll needs --system (to remove your own enrollment: rm -rf ~/Library/Application\\ Support/faceauth)")
    exit(Exit.error)
}
if opts.system && !["enroll", "calibrate", "unenroll"].contains(opts.command) {
    say("--system works with enroll, calibrate and unenroll.")
    exit(Exit.error)
}
if opts.storeFD != nil && opts.command != "verify" {
    say("--store-fd works only with verify.")
    exit(Exit.error)
}

// Under sudo the PAM module passes the root store on a descriptor (SPEC rev 4,
// Q19). Read it first, before anything else, and close it.
var storeData: Data?
if let fd = opts.storeFD {
    do {
        storeData = try StoreBundle.read(fd: fd)
        close(fd)
    } catch {
        say("faceauth: \(error)")
        exit(Exit.error)
    }
}

// The HUD is shown for enroll and verify (Q5), the demo, and the capture helper
// (which shows root's enroll prompts). Root's --system process draws nothing.
let wantsHUD = ["enroll", "verify", "hud-demo", "capture-helper"].contains(opts.command) && !opts.noHUD && !opts.system
let gui = wantsHUD && GUISession.isAvailable
if gui {
    NSApplication.shared.setActivationPolicy(.accessory) // no Dock icon, never takes focus
}

@MainActor
func main() async -> Int32 {
    let ui = UI(hud: gui ? NotchHUD.make() : nil, verbose: opts.verbose)
    let store = EnrollmentStore(directory: EnrollmentStore.defaultDirectory)
    do {
        if opts.system {
            return try await runSystem(command: opts.command, opts: opts)
        }
        switch opts.command {
        case "enroll":
            return try await runLocalEnroll(ui: ui)
        case "verify":
            if let storeData {
                // Under sudo: the root store only; never the user store, never enroll.
                return try await runVerify(ui: ui, storeData: storeData)
            }
            if !store.hasEnrollment {
                // First run: enroll now; this run never counts as a verification.
                say("No face is enrolled yet. Starting enrollment (5 snaps).")
                _ = try await runLocalEnroll(ui: ui)
                say("Enrolled. Run `faceauth calibrate`, then `faceauth verify`.")
                return Exit.error
            }
            return try await runVerify(ui: ui)
        case "calibrate":
            if !store.hasEnrollment {
                say("No face is enrolled yet. Starting enrollment (5 snaps).")
                _ = try await runLocalEnroll(ui: ui)
            }
            return try await runLocalCalibrate(ui: ui, fixedThreshold: opts.threshold)
        case "capture-helper":
            return try await runCaptureHelper(ui: ui)
        case "record-landmarks":
            return try await runRecord(ui: ui, path: opts.positional.first, label: opts.label, seconds: opts.seconds)
        case "hud-demo":
            return await runHUDDemo(ui: ui)
        case "hud-snapshots":
            return try runHUDSnapshots(dir: opts.positional.first)
        case "self-test":
            return try runSelfTest()
        default:
            say(usage)
            return Exit.error
        }
    } catch {
        let message = "\(error)"
        if ui.hud?.isShown == true { await ui.finish(.failure("Error")) }
        say("faceauth: \(message)")
        return Exit.error
    }
}

Task { @MainActor in
    exit(await main())
}

if gui {
    NSApplication.shared.run()
} else {
    dispatchMain()
}

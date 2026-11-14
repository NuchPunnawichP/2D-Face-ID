import AppKit
import FaceAuthCapture
import FaceAuthCore
import Foundation

let opts: Options
do {
    opts = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    say("\(error)\n\n\(usage)")
    exit(Exit.error)
}

let knownCommands: Set = ["enroll", "verify", "calibrate", "record-landmarks", "hud-demo", "hud-snapshots", "self-test", "help"]
guard knownCommands.contains(opts.command) else {
    say("Unknown command \(opts.command)\n\n\(usage)")
    exit(Exit.error)
}
if opts.command == "help" {
    say(usage)
    exit(Exit.error) // no command given
}

// The HUD is shown for enroll and verify (Q5), and for the demo.
let wantsHUD = ["enroll", "verify", "hud-demo"].contains(opts.command) && !opts.noHUD
let gui = wantsHUD && GUISession.isAvailable
if gui {
    NSApplication.shared.setActivationPolicy(.accessory) // no Dock icon, never takes focus
}

@MainActor
func main() async -> Int32 {
    let ui = UI(hud: gui ? NotchHUD.make() : nil, verbose: opts.verbose)
    let store = EnrollmentStore(directory: EnrollmentStore.defaultDirectory)
    do {
        switch opts.command {
        case "enroll":
            return try await runEnroll(ui: ui)
        case "verify":
            if !store.hasEnrollment {
                // First run: enroll now; this run never counts as a verification.
                say("No face is enrolled yet. Starting enrollment (5 snaps).")
                _ = try await runEnroll(ui: ui)
                say("Enrolled. Run `faceauth calibrate`, then `faceauth verify`.")
                return Exit.error
            }
            return try await runVerify(ui: ui)
        case "calibrate":
            if !store.hasEnrollment {
                say("No face is enrolled yet. Starting enrollment (5 snaps).")
                _ = try await runEnroll(ui: ui)
            }
            return try await runCalibrate(ui: ui, fixedThreshold: opts.threshold)
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

import AppKit
import FaceAuthCapture
import FaceAuthCore
import SwiftUI

/// faceauth.app: a setup window. Every button opens Terminal with one step,
/// so sudo passwords are typed into Terminal, never into this app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--iconset"), i + 1 < args.count {
            // Write the app icon PNGs for iconutil (used by scripts/make_app_dmg.sh).
            exit(Icon.writeIconset(to: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // Render the window offscreen to a PNG (used to check the layout).
            let code = MainActor.assumeIsolated { Snapshot.write(to: args[i + 1]) }
            exit(code)
        }
        SetupApp.main()
    }
}

struct SetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("faceauth", id: "setup") {
            SetupView(resources: Bundle.main.resourcePath ?? "")
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Whether faceauth is installed for sudo (both checks need no privileges).
struct InstallStatus {
    var binaryInstalled: Bool
    var pamLine: Bool

    static func current() -> InstallStatus {
        let line = (try? String(contentsOfFile: "/etc/pam.d/sudo_local", encoding: .utf8))?
            .contains("pam_faceauth.so") ?? false
        return InstallStatus(binaryInstalled: FileManager.default.fileExists(atPath: "/usr/local/libexec/faceauth"),
                             pamLine: line)
    }

    var summary: String {
        switch (binaryInstalled, pamLine) {
        case (true, true): return "Installed for sudo"
        case (false, false): return "Not installed"
        default: return "Partly installed. Run Install again, or Remove everything."
        }
    }
}

struct GlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Glyph paths use y-up coordinates; flip for SwiftUI.
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY * 2 + rect.height)
        return Path(Glyph.face(in: rect).copy(using: &t) ?? Glyph.face(in: rect))
    }
}

struct SetupView: View {
    let resources: String
    @State private var status = InstallStatus.current()
    @State private var error: String?
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.black)
                    GlyphShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .padding(12)
                }
                .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("faceauth").font(.system(size: 26, weight: .bold))
                    Text("2D face unlock for sudo — a learning prototype")
                        .foregroundStyle(.secondary)
                    Label(status.summary, systemImage: status.binaryInstalled && status.pamLine
                          ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(status.binaryInstalled && status.pamLine ? .green : .secondary)
                        .font(.callout)
                }
            }

            Text("Weaker than your password, Touch ID or Face ID: a video of you can pass. "
                 + "The login window and lock screen are not touched. If the face check fails, sudo asks for your password.")
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))

            VStack(spacing: 10) {
                ForEach(Array([SetupStep.safetyShell, .install, .enroll, .calibrate, .test].enumerated()), id: \.offset) { i, step in
                    StepRow(number: i + 1, step: step) { run(step) }
                }
            }

            Divider()
            HStack {
                Button("Remove everything…") { run(.uninstall) }
                Spacer()
                Button("Open README") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: resources + "/README.md"))
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Text("Each button opens Terminal for that step; type your password there.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560)
        .onReceive(timer) { _ in status = InstallStatus.current() }
    }

    func run(_ step: SetupStep) {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("faceauth-setup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("\(step.rawValue).command")
            try SetupScript.commandFile(for: step, resources: resources)
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            error = nil
        } catch {
            self.error = "Could not open Terminal: \(error.localizedDescription)"
        }
    }
}

struct StepRow: View {
    let number: Int
    let step: SetupStep
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.headline)
                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Run", action: action)
        }
    }
}

enum Snapshot {
    @MainActor
    static func write(to path: String) -> Int32 {
        let view = SetupView(resources: "/Applications/faceauth.app/Contents/Resources")
            .background(Color(nsColor: .windowBackgroundColor))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return 1 }
        return 0
    }
}

/// The app icon: the face-scan glyph in white on a black rounded square.
enum Icon {
    static func png(size: Int) -> Data? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // macOS icon grid: the shape fills about 80% of the canvas.
        let inset = s * 0.1
        let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fillPath()
        let g = body.insetBy(dx: body.width * 0.18, dy: body.width * 0.18)
        ctx.addPath(Glyph.face(in: g))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(max(1, s * 0.035))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func writeIconset(to dir: String) -> Int32 {
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for base in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                    guard let d = png(size: base * scale) else { return 1 }
                    try d.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name)))
                }
            }
            return 0
        } catch { return 1 }
    }
}

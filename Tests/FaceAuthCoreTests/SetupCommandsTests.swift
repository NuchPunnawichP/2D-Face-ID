import Foundation
import Testing
@testable import FaceAuthCore

@Suite("Setup app commands")
struct SetupCommandsTests {
    @Test func quoting() {
        #expect(SetupScript.quote("/a b/c") == "'/a b/c'")
        #expect(SetupScript.quote("it's") == "'it'\\''s'")
    }

    @Test func installRunsTheBundledScript() {
        #expect(SetupStep.install.command(resources: "/Applications/faceauth.app/Contents/Resources")
                == "sh '/Applications/faceauth.app/Contents/Resources/install.sh'")
        #expect(SetupStep.uninstall.command(resources: "/x y") == "sh '/x y/uninstall.sh'")
    }

    @Test func sudoStepsUseTheInstalledBinary() {
        #expect(SetupStep.enroll.command(resources: "/r") == "sudo /usr/local/libexec/faceauth enroll --system")
        #expect(SetupStep.calibrate.command(resources: "/r") == "sudo /usr/local/libexec/faceauth calibrate --system")
    }

    @Test func noStepEverSeesAPassword() {
        // Passwords are typed into sudo in Terminal; no step pipes or echoes one.
        for step in SetupStep.allCases {
            let c = step.command(resources: "/r")
            #expect(!c.contains("-S"), "\(step) must not use sudo -S")
            #expect(!c.lowercased().contains("password="))
        }
    }

    @Test func commandFileIsAShellScript() {
        let f = SetupScript.commandFile(for: .test, resources: "/r")
        #expect(f.hasPrefix("#!/bin/sh\n"))
        #expect(f.contains("sudo -k; if sudo true"))
        #expect(f.contains("Finished (exit $status)"))
    }

    @Test func weirdResourcePathCannotInjectCommands() {
        let evil = "/tmp/x'; rm -rf ~; echo '"
        let c = SetupStep.install.command(resources: evil)
        // The whole path stays one quoted word.
        #expect(c == "sh " + SetupScript.quote(evil + "/install.sh"))
        #expect(c.hasPrefix("sh '/tmp/x'\\''; rm -rf ~; echo '\\''/install.sh'"))
    }
}

import Foundation
import Testing
@testable import DynoKit

@Suite struct CommandInstallTests {
    let launcher = "/Applications/Dyno.app/Contents/MacOS/dyno-cli"
    let home = "/Users/someone"
    let system = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    @Test func freshMacWithoutHomebrewNeedsThePassword() {
        let plan = CommandInstall.plan(launcher: launcher, existing: [:], path: system, writable: { _ in false }, home: home)
        #expect(plan.action == .needsAdmin)
        #expect(plan.installed == nil)
    }

    @Test func homebrewFolderNeedsNoPassword() {
        let plan = CommandInstall.plan(launcher: launcher, existing: [:], path: ["/opt/homebrew/bin"] + system,
                                       writable: { $0 == "/opt/homebrew/bin" }, home: home)
        #expect(plan.action == .write("/opt/homebrew/bin/dyno"))
    }

    @Test func writableFolderOffThePathIsNotUsed() {
        // ~/.local/bin exists but a new Terminal wouldn't find dyno there.
        let plan = CommandInstall.plan(launcher: launcher, existing: [:], path: system,
                                       writable: { $0 == "\(home)/.local/bin" }, home: home)
        #expect(plan.action == .needsAdmin)
    }

    @Test func currentCommandIsLeftAlone() {
        let plan = CommandInstall.plan(launcher: launcher, existing: ["\(home)/.local/bin": CommandInstall.script(launcher: launcher)],
                                       path: ["\(home)/.local/bin"] + system, writable: { _ in true }, home: home)
        #expect(plan.action == .none)
        #expect(plan.installed == "\(home)/.local/bin/dyno")
    }

    @Test func staleCommandIsPointedAtThisApp() {
        let old = CommandInstall.script(launcher: "/Users/someone/Downloads/Dyno.app/Contents/MacOS/dyno-cli")
        let writable = CommandInstall.plan(launcher: launcher, existing: ["/opt/homebrew/bin": old],
                                           path: ["/opt/homebrew/bin"] + system, writable: { _ in true }, home: home)
        #expect(writable.action == .write("/opt/homebrew/bin/dyno"))
        let system = CommandInstall.plan(launcher: launcher, existing: ["/usr/local/bin": old],
                                         path: system, writable: { _ in false }, home: home)
        #expect(system.action == .needsAdmin)
        #expect(system.installed == "/usr/local/bin/dyno")
    }

    @Test func someoneElsesDynoIsNeverReplaced() {
        let plan = CommandInstall.plan(launcher: launcher, existing: ["/opt/homebrew/bin": "#!/usr/bin/env python3\nprint('hi')\n"],
                                       path: ["/opt/homebrew/bin"] + system, writable: { _ in true }, home: home)
        #expect(plan.action == .conflict("/opt/homebrew/bin/dyno"))
        let binary = CommandInstall.plan(launcher: launcher, existing: ["/opt/homebrew/bin": String?.none],
                                         path: ["/opt/homebrew/bin"] + system, writable: { _ in true }, home: home)
        #expect(binary.action == .conflict("/opt/homebrew/bin/dyno"))
    }

    @Test func scriptQuotesTheLauncherPath() {
        let script = CommandInstall.script(launcher: "/Users/o'neil/Apps/Dyno.app/Contents/MacOS/dyno-cli")
        #expect(script == "#!/bin/sh\nexec '/Users/o'\\''neil/Apps/Dyno.app/Contents/MacOS/dyno-cli' \"$@\"\n")
        #expect(CommandInstall.classify(contents: script, launcher: launcher) == .stale)
    }

    @Test func temporaryAppLocationsAreSkipped() {
        #expect(CommandInstall.isInstalledLocation("/Applications/Dyno.app"))
        #expect(!CommandInstall.isInstalledLocation("/Volumes/Dyno Lab/Dyno.app"))
        #expect(!CommandInstall.isInstalledLocation("/private/var/folders/x/AppTranslocation/ABC/d/Dyno.app"))
    }

    @Test func writesAnExecutableScript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("command-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dyno").path
        try CommandInstall.write(file, launcher: launcher)
        #expect(FileManager.default.isExecutableFile(atPath: file))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == CommandInstall.script(launcher: launcher))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["dyno"])
    }

    @Test func loginPathReadsTheShell() {
        let path = CommandInstall.loginPath()
        #expect(path.contains("/usr/bin"))
    }
}

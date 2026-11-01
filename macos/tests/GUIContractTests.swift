import AppKit
import Darwin
import Foundation

private enum ContractFailure: Error, LocalizedError {
    case unexpected(String)
    var errorDescription: String? { if case .unexpected(let value) = self { return value }; return nil }
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw ContractFailure.unexpected(message) }
}

private func waitFor(_ message: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    try require(condition(), message)
}

@main
private struct GUIContractTests {
    static func main() throws {
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-gui-home-\(UUID().uuidString)")
        let originalHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", home.path, 1)
        let genuineHome = try LauncherUserHome.current()
        if let originalHome = originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        try require(genuineHome != home && genuineHome.path.hasPrefix("/"), "production HOME ignores caller environment")
        let resources = home.appendingPathComponent("Resources")
        let available = LauncherUpdateInfo(version: "0.4.1", notes: "更新说明", assetURL: URL(string: "https://api.schyler.top/image2/releases/v0.4.1/SchylerAI-Image2-mcp-macOS.dmg")!, sha256: String(repeating: "a", count: 64), size: 42, architectures: ["arm64", "amd64"], available: true)
        let installGate = DispatchSemaphore(value: 0)
        var receivedCredentials: LauncherCredentials?
        var installerWasOffMain = false
        var installedHome: URL?
        var checkCompletion: ((Result<LauncherUpdateInfo, Error>) -> Void)?
        var downloadCompletion: ((Result<URL, Error>) -> Void)?
        var cancelled = 0
        var openedURLs: [URL] = []
        let services = LauncherServices(
            homeURL: { home },
            install: { _, actualHome, credentials, status in
                installerWasOffMain = !Thread.isMainThread
                installedHome = actualHome
                receivedCredentials = credentials
                status("fake-key-should-never-be-displayed")
                _ = installGate.wait(timeout: .now() + 3)
                return LauncherInstallationResult(output: "Verification: OK")
            },
            check: { checkCompletion = $0 },
            download: { _, _, completion in downloadCompletion = completion },
            cancelUpdate: { cancelled += 1 },
            openDownload: { openedURLs.append($0); return true }
        )
        let controller = LauncherWindowController(resourcesURL: resources, version: "0.4.0", services: services)
        try require(controller.window?.title == "SchylerAI-Image2-mcp", "Chinese app window title")
        try require(controller.image2Field.stringValue.isEmpty && controller.geminiField.stringValue.isEmpty, "keys start blank")
        try require(controller.image2Field.accessibilityLabel()?.contains("可选") == true && controller.geminiField.accessibilityLabel()?.contains("可选") == true, "both provider labels explicitly allow leaving a key blank")
        try require(controller.installButton.title == "安装 / 更新密钥" && controller.updateButton.title == "检查更新" && controller.cancelButton.title == "取消下载", "normal action buttons use Chinese labels")
        try require(controller.modelReminder.stringValue.contains("默认使用 Image2") && controller.modelReminder.stringValue.contains("Gemini") && controller.modelReminder.stringValue.contains("香蕉") && controller.modelReminder.stringValue.contains("banana") && controller.modelReminder.stringValue.contains("3.1 Flash"), "routing reminder covers both providers")
        controller.installButton.performClick(nil)
        try require(controller.installButton.isEnabled && controller.statusLabel.stringValue.contains("至少") && receivedCredentials == nil, "two blank keys are rejected with Chinese guidance without starting installation")
        controller.image2Field.stringValue = " \t"
        controller.geminiField.stringValue = "　"
        controller.installButton.performClick(nil)
        try require(controller.installButton.isEnabled && receivedCredentials == nil, "two whitespace-only keys never reach installer")
        controller.image2Field.stringValue = "fake\nimage2"
        controller.geminiField.stringValue = "fake-gemini-value"
        controller.installButton.performClick(nil)
        try require(controller.installButton.isEnabled && !controller.image2Field.stringValue.isEmpty, "invalid multiline key never reaches installer")
        controller.image2Field.stringValue = "fake-image2-value"
        controller.geminiField.stringValue = "fake-gemini-value"
        controller.installButton.performClick(nil)
        try require(controller.image2Field.stringValue.isEmpty && controller.geminiField.stringValue.isEmpty, "key fields clear immediately on accepted installation")
        try require(!controller.installButton.isEnabled && !controller.updateButton.isEnabled && !controller.image2Field.isEnabled && !controller.geminiField.isEnabled, "installation disables credential and action controls")
        try require(!controller.windowShouldClose(controller.window!) && !controller.shouldAllowTermination(), "installation blocks close and quit")
        try require(!controller.cancelButton.isEnabled, "installer has no cancellation")
        installGate.signal()
        try waitFor("installation completion reaches GUI", { controller.installButton.isEnabled })
        try require(installerWasOffMain && installedHome == home && receivedCredentials?.image2Key == "fake-image2-value" && receivedCredentials?.geminiKey == "fake-gemini-value", "installer runs off main with both credentials and chosen home")
        try require(controller.statusLabel.stringValue.contains("重启 Codex") && controller.statusLabel.stringValue.contains("新对话"), "success explains restart and new conversation")
        try require(controller.detailsView.string.contains(home.appendingPathComponent(".codex/config.toml").path), "success identifies local configuration path")
        try require(!controller.detailsView.string.contains("fake-key") && !controller.statusLabel.stringValue.contains("fake-key"), "raw installer status is not rendered")
        for (image2, gemini, expected) in [("fake-image2-only", " \t", "fake-image2-only\n\n"), ("　", "fake-gemini-only", "\nfake-gemini-only\n")] {
            receivedCredentials = nil
            controller.image2Field.stringValue = image2
            controller.geminiField.stringValue = gemini
            controller.installButton.performClick(nil)
            try require(controller.image2Field.stringValue.isEmpty && controller.geminiField.stringValue.isEmpty && !controller.installButton.isEnabled, "single-provider installation clears and locks both fields")
            installGate.signal()
            try waitFor("single-provider installation completes", { controller.installButton.isEnabled })
            try require(receivedCredentials?.stdinData == Data(expected.utf8), "GUI sends only the chosen provider without filling the missing key")
            try require(controller.statusLabel.stringValue.contains("安装完成"), "single-provider success uses Chinese status")
        }
        controller.updateButton.performClick(nil)
        try require(checkCompletion != nil && !controller.installButton.isEnabled, "check is explicit and blocks concurrent install")
        checkCompletion?(.success(available))
        try waitFor("available version displayed", { controller.updateButton.isEnabled && controller.updateButton.title.contains("下载") })
        controller.updateButton.performClick(nil)
        try require(downloadCompletion != nil && controller.cancelButton.isEnabled, "available update downloads only on second click")
        let verified = home.appendingPathComponent("verified.dmg")
        downloadCompletion?(.success(verified))
        try waitFor("verified result opens", { openedURLs == [verified] })
        try require(controller.statusLabel.stringValue.contains("已验证"), "download reports verified package")
        controller.updateButton.performClick(nil)
        checkCompletion?(.success(available))
        try waitFor("second update check", { controller.updateButton.isEnabled && controller.updateButton.title.contains("下载") })
        controller.updateButton.performClick(nil)
        controller.cancelButton.performClick(nil)
        try require(cancelled == 1 && controller.statusLabel.stringValue.contains("取消"), "update download can cancel")
        downloadCompletion?(.success(home.appendingPathComponent("cancel-race.dmg")))
        try waitFor("cancel completion", { controller.installButton.isEnabled })
        try require(openedURLs == [verified], "cancellation racing a verified success never opens the package")
        controller.updateButton.performClick(nil)
        checkCompletion?(.failure(ContractFailure.unexpected("fake-image2-value")))
        try waitFor("failed check releases controls", { controller.installButton.isEnabled })
        try require(!controller.statusLabel.stringValue.contains("fake-image2-value"), "arbitrary updater error remains private")
        try require(controller.shouldAllowTermination(), "idle application may quit")
        try installationFailures(home: home, resources: resources)
        try unavailableResources(home: home)
        try unavailableHome(resources: resources)
        print("GUI contracts: PASS (blank secure fields, validation, background install, safe diagnostics, busy close/quit, update verification and cancellation)")
    }

    private static func installationFailures(home: URL, resources: URL) throws {
        let failures: [(Error, LauncherInstallDiagnostic, Int32?)] = [
            (ContractFailure.unexpected("fake-install-key-from-error"), .unknown, nil),
            (LauncherCoreError("fake-install-key-from-error", exitStatus: 19), .unknown, nil),
            (LauncherCoreError("fake-install-key-from-error", diagnostic: .resources), .resources, nil),
            (LauncherCoreError("fake-install-key-from-error", diagnostic: .verification, exitStatus: 27), .verification, 27)
        ]
        for (error, diagnostic, exitStatus) in failures {
            let services = LauncherServices(
                homeURL: { home },
                install: { _, _, _, status in
                    status("fake-install-key-from-progress")
                    throw error
                },
                check: { _ in }, download: { _, _, _ in }, cancelUpdate: {}, openDownload: { _ in false }
            )
            let controller = LauncherWindowController(resourcesURL: resources, version: "0.4.1", services: services)
            controller.image2Field.stringValue = "fake-install-key-from-error"
            controller.geminiField.stringValue = "fake-install-key-from-progress"
            controller.installButton.performClick(nil)
            try waitFor("failed installation releases controls", { controller.installButton.isEnabled })
            try require(controller.image2Field.stringValue.isEmpty && controller.geminiField.stringValue.isEmpty, "failed installation keeps both credential fields blank")
            try require(controller.image2Field.isEnabled && controller.geminiField.isEnabled && controller.updateButton.isEnabled && controller.shouldAllowTermination(), "failed installation returns credential controls and quit to idle")
            let visible = controller.statusLabel.stringValue + "\n" + controller.detailsView.string
            try require(!visible.contains("fake-install-key"), "arbitrary installer errors and progress remain private")
            try require(controller.statusLabel.stringValue == "安装未完成。请查看下方诊断和处理建议。", "failed installation requests diagnostics instead of treating every failure as a key problem")
            try require(controller.detailsView.string.contains(diagnostic.code), "installation failure displays only its trusted stable diagnostic code")
            try require(controller.detailsView.string.contains(diagnostic.summary) && controller.detailsView.string.contains(diagnostic.recovery), "installation failure displays its static diagnostic and recovery guidance")
            if let exitStatus = exitStatus {
                try require(controller.detailsView.string.contains("退出状态：\(exitStatus)"), "trusted process failures display numeric exit status")
            } else {
                try require(!controller.detailsView.string.contains("退出状态："), "unclassified errors cannot introduce process exit status")
            }
        }
    }

    private static func unavailableResources(home: URL) throws {
        var invokedInstaller = false
        let services = LauncherServices(
            homeURL: { home },
            install: { _, _, _, _ in
                invokedInstaller = true
                return LauncherInstallationResult(output: "Verification: OK")
            },
            check: { _ in }, download: { _, _, _ in }, cancelUpdate: {}, openDownload: { _ in false }
        )
        let controller = LauncherWindowController(resourcesURL: nil, version: "0.4.1", services: services)
        controller.image2Field.stringValue = "fake-missing-resource-key"
        controller.installButton.performClick(nil)
        try require(!invokedInstaller && controller.installButton.isEnabled, "missing resources never invoke the installer")
        try require(controller.image2Field.stringValue.isEmpty && controller.geminiField.stringValue.isEmpty, "missing resources leave accepted credentials blank")
        try require(controller.detailsView.string.contains("INSTALL_RESOURCES"), "missing resources display a stable diagnostic code")
        try require(!controller.detailsView.string.contains("fake-missing-resource-key"), "resource failure never displays credentials")
    }

    private static func unavailableHome(resources: URL) throws {
        var invokedInstaller = false
        let services = LauncherServices(
            homeURL: { throw ContractFailure.unexpected("fake-home-resolution-key") },
            install: { _, _, _, _ in
                invokedInstaller = true
                return LauncherInstallationResult(output: "Verification: OK")
            },
            check: { _ in }, download: { _, _, _ in }, cancelUpdate: {}, openDownload: { _ in false }
        )
        let controller = LauncherWindowController(resourcesURL: resources, version: "0.4.1", services: services)
        controller.image2Field.stringValue = "fake-home-resolution-key"
        controller.installButton.performClick(nil)
        try waitFor("home resolution failure releases controls", { controller.installButton.isEnabled })
        try require(!invokedInstaller, "unavailable home never invokes the installer")
        try require(controller.image2Field.stringValue.isEmpty && controller.geminiField.stringValue.isEmpty, "home resolution failure leaves accepted credentials blank")
        try require(controller.detailsView.string.contains(LauncherInstallDiagnostic.home.code) && controller.detailsView.string.contains(LauncherInstallDiagnostic.home.recovery), "home resolution failure has a safe actionable diagnostic")
        try require(!controller.detailsView.string.contains("fake-home-resolution-key") && !controller.statusLabel.stringValue.contains("fake-home-resolution-key"), "home resolution errors remain private")
    }
}

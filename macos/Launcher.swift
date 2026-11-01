import AppKit
import Darwin
import Foundation

// These boundaries keep credentials confined to the offline installation path.
struct LauncherServices {
    let homeURL: () throws -> URL
    let install: (URL, URL, LauncherCredentials, @escaping (String) -> Void) throws -> LauncherInstallationResult
    let check: (@escaping (Result<LauncherUpdateInfo, Error>) -> Void) -> Void
    let download: (LauncherUpdateInfo, URL, @escaping (Result<URL, Error>) -> Void) -> Void
    let cancelUpdate: () -> Void
    let openDownload: (URL) -> Bool

    static func live(version: String) -> LauncherServices {
        let updater = LauncherUpdater(currentVersion: version)
        return LauncherServices(
            homeURL: LauncherUserHome.current,
            install: { resources, home, credentials, status in
                try OfflineInstaller(resourcesURL: resources, homeURL: home).install(credentials: credentials, status: status)
            },
            check: updater.check,
            download: { info, directory, completion in
                updater.download(info: info, destinationDirectory: directory, completion: completion)
            },
            cancelUpdate: updater.cancel,
            openDownload: { NSWorkspace.shared.open($0) }
        )
    }
}

enum LauncherUserHome {
    static func current() throws -> URL {
        // HOME can be inherited from a shell or modified by an app launcher.
        // Resolve the logged-in account using the OS account database instead.
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        var storage = [CChar](repeating: 0, count: max(suggested > 0 ? Int(suggested) : 16_384, 16_384))
        return try storage.withUnsafeMutableBufferPointer { buffer in
            var account = passwd()
            var found: UnsafeMutablePointer<passwd>?
            let result = getpwuid_r(getuid(), &account, buffer.baseAddress, buffer.count, &found)
            guard result == 0, found != nil, let directory = account.pw_dir else {
                throw CocoaError(.fileReadNoPermission)
            }
            let path = String(cString: directory)
            guard path.hasPrefix("/"), path != "/" else { throw CocoaError(.fileReadInvalidFileName) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}

final class LauncherWindowController: NSWindowController, NSWindowDelegate {
    let image2Field = NSSecureTextField()
    let geminiField = NSSecureTextField()
    let installButton = NSButton(title: "安装 / 更新密钥", target: nil, action: nil)
    let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消下载", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "请至少填写一项 API Key，点击安装即可离线完成配置。")
    let modelReminder = NSTextField(wrappingLabelWithString: "默认使用 Image2。明确指定 Gemini、香蕉或 banana 时，使用 Gemini 3.1 Flash Image。")
    let detailsView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let resourcesURL: URL?
    private let services: LauncherServices
    private let installationQueue = DispatchQueue(label: "top.schyler.image2-launcher.install", qos: .userInitiated)
    private enum Operation { case idle, installing, checking, downloading }
    private var operation = Operation.idle
    private var availableUpdate: LauncherUpdateInfo?
    private var updateID: UUID?
    private var downloadDirectory: URL?
    private var cancellingDownload = false
    var installationInProgress: Bool { operation == .installing }

    init(resourcesURL: URL?, version: String, services: LauncherServices) {
        self.resourcesURL = resourcesURL
        self.services = services
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 655), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SchylerAI-Image2-mcp"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface(version: version)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(version: String) {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "配置 Image2 与 Gemini")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "SchylerAI-Image2-mcp  ·  版本 \(String(version.prefix(48)))  ·  macOS 12+")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)

        addCredentialField(image2Field, label: "Image2 API Key（可选）", placeholder: "填写 Image2 密钥，或留空不配置", to: stack)
        addCredentialField(geminiField, label: "Gemini API Key（可选）", placeholder: "填写 Gemini 密钥，或留空不配置", to: stack)
        modelReminder.font = .systemFont(ofSize: 13)
        modelReminder.textColor = .secondaryLabelColor
        stack.addArrangedSubview(modelReminder)
        let keyReminder = NSTextField(wrappingLabelWithString: "至少填写一项密钥；留空的供应商将不配置。每次安装或更换密钥时需重新输入。密钥仅用于本机安装，不会发送给更新服务。")
        keyReminder.font = .systemFont(ofSize: 12)
        keyReminder.textColor = .secondaryLabelColor
        stack.addArrangedSubview(keyReminder)

        let actions = NSStackView(views: [installButton, updateButton, cancelButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.target = self
        installButton.action = #selector(installClicked)
        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownloadClicked)
        cancelButton.isEnabled = false
        stack.addArrangedSubview(actions)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let progress = NSStackView(views: [spinner, statusLabel])
        progress.orientation = .horizontal
        progress.alignment = .centerY
        progress.spacing = 8
        stack.addArrangedSubview(progress)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        detailsView.isEditable = false
        detailsView.isSelectable = true
        detailsView.isRichText = false
        detailsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsView.textContainerInset = NSSize(width: 10, height: 9)
        detailsView.autoresizingMask = [.width]
        detailsView.isVerticallyResizable = true
        detailsView.isHorizontallyResizable = false
        detailsView.textContainer?.widthTracksTextView = true
        detailsView.string = "安装包含完整离线资源，系统会自动选择 Apple 芯片或 Intel 版本。\n检查更新和下载更新均需点击按钮；离线安装不依赖更新服务。"
        scroll.documentView = detailsView
        stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true

        for view in [image2Field, geminiField, modelReminder, keyReminder, separator, progress, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        image2Field.nextKeyView = geminiField
        geminiField.nextKeyView = installButton
        window?.initialFirstResponder = image2Field
    }

    private func addCredentialField(_ field: NSSecureTextField, label: String, placeholder: String, to stack: NSStackView) {
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(caption)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.heightAnchor.constraint(equalToConstant: 32).isActive = true
        field.setAccessibilityLabel(label)
        stack.addArrangedSubview(field)
    }

    @objc private func installClicked() {
        guard operation == .idle else { return }
        window?.makeFirstResponder(nil)
        let credentials = LauncherCredentials(image2Key: image2Field.stringValue, geminiKey: geminiField.stringValue)
        do { try credentials.validate() } catch {
            statusLabel.stringValue = "请至少填写一项密钥；已填密钥必须为单行、不含空字符，且每项不超过 1024 字节。"
            return
        }
        image2Field.stringValue = ""
        geminiField.stringValue = ""
        guard let resources = resourcesURL else {
            finishInstallation(.failure(LauncherCoreError("离线资源不可用。", diagnostic: .resources)))
            return
        }
        setOperation(.installing)
        statusLabel.stringValue = "正在安装，请等待完成或回滚。安装期间无法关闭或退出应用。"
        detailsView.string = "正在验证离线资源并更新本机配置。请保持应用开启；安装器会等待事务完成。"
        let services = self.services
        installationQueue.async { [weak self] in
            let result: Result<URL, Error>
            do {
                let home: URL
                do { home = try services.homeURL() }
                catch { throw LauncherCoreError("无法定位当前用户主目录。", diagnostic: .home) }
                _ = try services.install(resources, home, credentials) { _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.operation == .installing else { return }
                        self.statusLabel.stringValue = "正在验证并安装离线资源，请等待完成或回滚。"
                    }
                }
                result = .success(home)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in self?.finishInstallation(result) }
        }
    }

    private func finishInstallation(_ result: Result<URL, Error>) {
        setOperation(.idle)
        switch result {
        case .success(let home):
            statusLabel.stringValue = "安装完成。请重启 Codex，并开启新对话后使用。"
            detailsView.string = "本机安装已验证。\n安装目录：\(home.appendingPathComponent(".local/share/image2-mcp").path)\nCodex 配置：\(home.appendingPathComponent(".codex/config.toml").path)\n\n默认使用 Image2；明确指定 Gemini、香蕉或 banana 时使用 Gemini 3.1 Flash Image。\n如需更换密钥，请重新输入要使用的密钥（至少一项）并再次安装；留空的供应商将不配置。"
        case .failure(let error):
            // Only fixed text from a known diagnostic may reach the GUI. Error
            // descriptions and installer output can contain credentials.
            let failure = error as? LauncherCoreError
            let diagnostic = failure?.diagnostic ?? .unknown
            let exitStatus = failure?.diagnostic != nil ? failure?.exitStatus : nil
            let exitDetail = exitStatus.map { "\n退出状态：\($0)" } ?? ""
            statusLabel.stringValue = "安装未完成。请查看下方诊断和处理建议。"
            detailsView.string = "诊断代码：\(diagnostic.code)\(exitDetail)\n\(diagnostic.summary)\n\n处理建议：\(diagnostic.recovery)\n\n密钥已清空；处理后重试时，请重新输入要使用的密钥（至少一项）。\n为保护密钥，此窗口不显示原始安装错误或进程输出。"
        }
    }

    @objc private func updateClicked() {
        guard operation == .idle else { return }
        if let info = availableUpdate { beginDownload(info); return }
        let id = UUID()
        updateID = id
        setOperation(.checking)
        statusLabel.stringValue = "正在检查已签名的 macOS 更新…"
        services.check { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.updateID == id, self.operation == .checking else { return }
                self.updateID = nil
                self.setOperation(.idle)
                switch result {
                case .success(let info):
                    if info.available {
                        self.availableUpdate = info
                        self.updateButton.title = "下载更新 \(String(info.version.prefix(48)))"
                        self.statusLabel.stringValue = "发现已验证的更新。点击下载更新后，将校验并打开 DMG。"
                        self.detailsView.string = "版本：\(String(info.version.prefix(48)))\n\n\(Self.safeNotes(info.notes))"
                    } else {
                        self.statusLabel.stringValue = "当前已是最新版本。"
                    }
                case .failure:
                    self.statusLabel.stringValue = "暂时无法检查更新。离线安装仍可使用，请稍后重试。"
                }
            }
        }
    }

    private func beginDownload(_ info: LauncherUpdateInfo) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image2-launcher-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            statusLabel.stringValue = "无法创建更新暂存目录，请检查可用空间后重试。"
            return
        }
        let id = UUID()
        updateID = id
        downloadDirectory = directory
        cancellingDownload = false
        setOperation(.downloading)
        statusLabel.stringValue = "正在下载更新，完成后将核对大小与 SHA-256…"
        services.download(info, directory) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.updateID == id, self.operation == .downloading else { return }
                self.updateID = nil
                let wasCancelled = self.cancellingDownload
                self.cancellingDownload = false
                self.availableUpdate = nil
                self.updateButton.title = "检查更新"
                self.setOperation(.idle)
                switch result {
                case .success(let verifiedURL) where !wasCancelled:
                    // Only the updater's successful, verified result can reach NSWorkspace.
                    self.downloadDirectory = nil
                    if self.services.openDownload(verifiedURL) {
                        self.statusLabel.stringValue = "更新包已验证并打开。请将新应用拖入 Applications 完成替换。"
                        self.detailsView.string = "已验证的更新包：\(verifiedURL.path)\n关闭当前应用后，再替换 Applications 中的旧版本。"
                    } else {
                        self.statusLabel.stringValue = "更新包已验证；系统未能打开，请在 Finder 中打开下方路径。"
                        self.detailsView.string = verifiedURL.path
                    }
                default:
                    self.removeDownloadDirectory()
                    self.statusLabel.stringValue = wasCancelled ? "更新下载已取消。" : "更新下载或校验失败，未打开任何更新包。请重新检查更新后重试。"
                }
            }
        }
    }

    @objc private func cancelDownloadClicked() {
        guard operation == .downloading, !cancellingDownload else { return }
        cancellingDownload = true
        cancelButton.isEnabled = false
        statusLabel.stringValue = "正在取消更新下载…"
        services.cancelUpdate()
    }

    private func setOperation(_ value: Operation) {
        operation = value
        let idle = value == .idle
        image2Field.isEnabled = idle
        geminiField.isEnabled = idle
        installButton.isEnabled = idle
        updateButton.isEnabled = idle
        cancelButton.isEnabled = value == .downloading && !cancellingDownload
        window?.standardWindowButton(.closeButton)?.isEnabled = value != .installing
        if idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldAllowTermination()
    }

    func shouldAllowTermination() -> Bool {
        if operation == .installing {
            statusLabel.stringValue = "安装仍在进行，请等待完成或回滚后再退出。"
            return false
        }
        if operation == .checking || operation == .downloading {
            updateID = nil
            services.cancelUpdate()
            removeDownloadDirectory()
        }
        return true
    }

    private func removeDownloadDirectory() {
        if let directory = downloadDirectory { try? FileManager.default.removeItem(at: directory) }
        downloadDirectory = nil
    }

    private static func safeNotes(_ notes: String) -> String {
        let bounded = String(notes.prefix(4_000))
        return bounded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }.map(String.init).joined()
    }
}

#if !LAUNCHER_GUI_TESTING
@main
private enum LauncherMain {
    static func main() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        if CommandLine.arguments.dropFirst().contains("--version") {
            print(version)
            return
        }
        if CommandLine.arguments.dropFirst().contains("--verify-resources") {
            do {
                guard let resources = Bundle.main.resourceURL else {
                    throw LauncherCoreError("离线资源不可用。", diagnostic: .resources)
                }
                try OfflineInstaller.verifyResources(at: resources, expectedVersion: version)
                print("Offline resources: OK")
                return
            } catch {
                fputs("INSTALL_RESOURCES\n", stderr)
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = LauncherAppDelegate(version: version)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

private final class LauncherAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let version: String
    private var controller: LauncherWindowController?

    init(version: String) { self.version = version }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 SchylerAI-Image2-mcp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 SchylerAI-Image2-mcp", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        let applicationItem = NSMenuItem()
        applicationItem.submenu = appMenu
        menu.addItem(applicationItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let controller = LauncherWindowController(resourcesURL: Bundle.main.resourceURL, version: version, services: .live(version: version))
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shouldAllowTermination() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(quit(_:)) {
            return controller?.installationInProgress != true
        }
        return true
    }
}
#endif

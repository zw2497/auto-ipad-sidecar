import AppKit
import SwiftUI
import ServiceManagement
import Darwin
import Combine

@main
struct AutoSidecarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { SettingsView(model: AppDelegate.model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static let model = ServiceModel()
    private var window: NSWindow?
    private var lockFD: Int32 = -1
    private var statusItem: NSStatusItem?
    private var statusSubscription: AnyCancellable?
    private let statusMenu = NSMenu()

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        item.menu = statusMenu
        statusSubscription = Self.model.$running.sink { [weak self] running in
            let image = NSImage(systemSymbolName: running ? "ipad.landscape" : "exclamationmark.circle", accessibilityDescription: "AutoSidecar")
            image?.isTemplate = true
            self?.statusItem?.button?.image = image
            self?.statusItem?.button?.toolTip = "AutoSidecar — \(running ? "服务运行中" : "服务未运行")"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.model.refreshLogin()
        menu.removeAllItems()
        func info(_ text: String, color: NSColor) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color])
            menu.addItem(item)
        }
        info(Self.model.serviceText, color: Self.model.running ? .systemGreen : .systemOrange)
        info(Self.model.loginText, color: Self.model.needsLoginApproval ? .systemOrange : .secondaryLabelColor)
        func action(_ title: String, _ selector: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            item.isEnabled = !Self.model.busy
            menu.addItem(item)
        }
        if !Self.model.running && !Self.model.config.isEmpty { action("启动服务", #selector(startService)) }
        if !Self.model.loginEnabled {
            action(Self.model.needsLoginApproval ? "批准登录启动…" : "开启登录启动", #selector(enableLogin))
        }
        menu.addItem(.separator())
        action("设置…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        action("退出 AutoSidecar", #selector(quitApp), key: "q")
    }

    @objc private func startService() { Task { await Self.model.retry() } }
    @objc private func enableLogin() {
        if Self.model.needsLoginApproval { SMAppService.openSystemSettingsLoginItems() }
        else { Task { await Self.model.setLogin(true) } }
    }
    @objc private func openSettings() { showSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }


    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test") {
            Task { await runSelfTests() }; return
        }
        if !ServiceModel.preview {
            do {
                try FileManager.default.createDirectory(at: Self.model.base, withIntermediateDirectories: true)
                lockFD = open(Self.model.base.appendingPathComponent("gui.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }
            } catch { Self.model.message = error.localizedDescription; showSettings(); return }
        }
        if CommandLine.arguments.contains("--render-preview") {
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.renderPreview() }
            return
        }
        installMenuBar()
        Task {
            await Self.model.bootstrap()
            if Self.model.config.isEmpty || !Self.model.message.isEmpty || ServiceModel.preview { showSettings() }
        }
    }

    func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: Self.model))
            let w = NSWindow(contentViewController: controller)
            w.title = "AutoSidecar 设置"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 510, height: 650))
            w.center(); w.delegate = self
            w.isReleasedWhenClosed = false
            window = w
        }
        Self.model.refreshLogin()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if Self.model.busy || Self.model.trialDirectory != nil { NSSound.beep(); return false }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.model.busy { return .terminateCancel }
        Task { await Self.model.quit() }
        return .terminateLater
    }
    func applicationDidBecomeActive(_ notification: Notification) { Self.model.refreshLogin() }

    private func renderPreview() {
        guard let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
              CommandLine.arguments.count > index + 1, let view = window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        } catch { fputs("\(error)\n", stderr); exit(2) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ServiceModel
    @State private var draft: Preferences
    @State private var advanced = false
    @State private var pairing = false

    init(model: ServiceModel) {
        self.model = model
        _draft = State(initialValue: Preferences(model.config))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("启动") {
                    Toggle("登录 Mac 后自动启动", isOn: Binding(get: { model.loginEnabled }, set: { enabled in Task { await model.setLogin(enabled) } }))
                    if model.needsLoginApproval {
                        Button("在系统设置中批准登录启动…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Text("登录后生效，不支持登录前或 FileVault 解锁界面。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自动连接的 iPad") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.config["name"] as? String ?? "尚未绑定")
                            Text("插入这台 iPad 时，自动启动随航。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.config.isEmpty ? "选择 iPad…" : "更换…") { model.message = ""; pairing = true }
                    }
                }
                Section("仅使用 iPad 时") {
                    HStack {
                        Text("桌面分辨率")
                        Spacer()
                        TextField("宽", text: $draft.width).frame(width: 70)
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", text: $draft.height).frame(width: 70)
                    }
                    Toggle("HiDPI 高清显示", isOn: $draft.hiDPI)
                    Text("尺寸为渲染像素；HiDPI 下桌面逻辑尺寸减半。\n分辨率、HiDPI 和刷新率将在下次连接时生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.config.isEmpty)
                Section("有其他显示器时") {
                    Picker("iPad 显示方式", selection: $draft.layout) {
                        Text("扩展显示器").tag("extend")
                        Text("镜像主显示器").tag("mirror")
                        Text("保留系统布局").tag("preserve")
                    }
                }.disabled(model.config.isEmpty)
                DisclosureGroup("高级设置", isExpanded: $advanced) {
                    LabeledContent("虚拟屏幕刷新率（Hz）") { TextField("60", text: $draft.hz).frame(width: 70) }
                    Text("支持填写 24–120；高于 60 为实验性，不保证随航实际帧率。")
                        .font(.caption).foregroundStyle(.secondary)
                    DockFields(title: "仅 iPad 的 Dock", size: $draft.ipadSize, magnification: $draft.ipadMagnification)
                    DockFields(title: "有其他显示器的 Dock", size: $draft.otherSize, magnification: $draft.otherMagnification)
                    Text("留空表示不接管；大小和放大尺寸为 16–128，放大填 off 表示关闭。可能需要自动化权限。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("查看日志") {
                        let url = model.logsURL
                        NSWorkspace.shared.open(url)
                    }
                }.disabled(model.config.isEmpty)
            }
            .formStyle(.grouped)
            .disabled(model.busy)
            if !pairing && !model.message.isEmpty {
                Text(model.message)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
                Button("应用") { Task { await model.save(draft) } }
                    .keyboardShortcut(.defaultAction).disabled(model.config.isEmpty)
            }.padding(16).disabled(model.busy)
        }
        .frame(width: 510, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $pairing) {
            PairingView(model: model, close: { pairing = false })
        }
        .onChange(of: model.config["sidecarIdentifier"] as? String) { _ in draft = Preferences(model.config) }
    }
}

struct DockFields: View {
    let title: String
    @Binding var size: String
    @Binding var magnification: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            HStack {
                Text("大小")
                TextField("不接管", text: $size)
                Text("放大")
                TextField("不接管", text: $magnification)
            }
        }.padding(.vertical, 6)
    }
}

struct PairingView: View {
    @ObservedObject var model: ServiceModel
    let close: () -> Void
    @State private var serial = ""
    @State private var identifier = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("绑定 iPad").font(.title2.weight(.semibold))
            Text("通过 USB 接入并解锁 iPad，按系统提示完成信任。\n首次配置建议准备实体显示器或远程访问。")
                .foregroundStyle(.secondary)
            Picker("USB 设备", selection: $serial) {
                Text("请选择").tag("")
                ForEach(model.usb) { Text("\($0.name) · \($0.id.suffix(6))").tag($0.id) }
            }.disabled(model.tested)
            Picker("匹配的随航设备", selection: $identifier) {
                Text("请选择").tag("")
                ForEach(model.targets) { Text($0.name).tag($0.id) }
            }.disabled(model.tested)
            HStack {
                Button("刷新设备") { Task { await model.discover(); selectDefaults() } }.disabled(model.tested)
                Spacer()
                Button("测试连接") { Task { await model.testPairing(serial: serial, identifier: identifier) } }
                    .disabled(serial.isEmpty || identifier.isEmpty || model.tested)
            }
            if model.busy { ProgressView("正在处理，请稍候…").controlSize(.small) }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if model.tested { Text("请确认目标 iPad 已显示 Mac 桌面。保存时会短暂重建连接。") }
            HStack {
                Spacer()
                Button("取消") {
                    Task {
                        model.busy = true
                        do { try await model.discardTrial(); model.message = ""; close() }
                        catch { model.message = error.localizedDescription }
                        model.busy = false
                    }
                }
                Button("确认画面并保存绑定") {
                    Task { await model.confirmPairing(); if model.trialDirectory == nil { close() } }
                }.disabled(!model.tested).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440).disabled(model.busy)
            .interactiveDismissDisabled()
            .task { await model.discover(); selectDefaults() }
    }
    func selectDefaults() {
        if model.usb.count == 1 { serial = model.usb[0].id }
        if model.targets.count == 1 { identifier = model.targets[0].id }
    }
}

@MainActor
func runSelfTests() async {
    do {
        let input: [String: Any] = ["version": 1, "usbSerial": "fixture", "sidecarIdentifier": "fixture", "name": "测试 iPad",
                                  "display": ["width": 2628, "height": 1970, "hiDPI": true, "refreshRate": 60],
                                  "dock": ["ipadOnly": ["magnification": false, "size": 32]]]
        var prefs = Preferences(input)
        precondition(prefs.width == "2628" && prefs.ipadMagnification == "off")
        prefs.width = "2560"; prefs.height = "1680"; prefs.otherMagnification = "64"
        let output = try prefs.applying(to: input)
        precondition(output["usbSerial"] as? String == "fixture")
        let display = output["display"] as! [String: Any]
        precondition(display["width"] as? Int == 2560)
        let dock = output["dock"] as! [String: [String: Any]]
        precondition(dock["ipadOnly"]?["magnification"] as? Bool == false)
        precondition(dock["withOtherDisplays"]?["magnification"] as? Int == 64)
        prefs.ipadSize = "129"
        do { _ = try prefs.applying(to: input); fatalError("Invalid Dock value accepted") } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSidecar-gui-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppDelegate.model
        let file = root.appendingPathComponent("config.plist")
        try await model.writeValidated(output, to: file)
        let original = try Data(contentsOf: file)
        var invalid = output
        invalid["display"] = ["width": 641, "height": 481, "hiDPI": true, "refreshRate": 60]
        do { try await model.writeValidated(invalid, to: file); fatalError("Odd HiDPI dimensions accepted") } catch {}
        let preserved = try Data(contentsOf: file)
        precondition(preserved == original, "Failed validation overwrote config")
        // Lifecycle checks use a fake executable and isolated files, never a live iPad.
        let fake = root.appendingPathComponent("fake-core")
        let script = """
        #!/bin/zsh
        case "$1" in
          config) exit 0;;
          watch) exec /bin/sleep 100;;
          session-snapshot) print '{"active":true,"otherCount":0}';;
          disconnect) print disconnected > "${0:h}/disconnect-observed";;
          *) exit 1;;
        esac
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let service = ServiceModel(testBase: root.appendingPathComponent("service"), executable: fake, preview: false)
        try await service.writeValidated(output, to: service.configURL)
        try await service.start(service.configURL)
        precondition(service.running && service.watcher?.isRunning == true)
        let pid = service.watcher!.processIdentifier
        try await service.start(service.configURL)
        precondition(service.watcher!.processIdentifier == pid, "Duplicate watcher started")
        try await service.stop()
        precondition(!service.running && service.watcher == nil)
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("disconnect-observed").path))
        let failureScript = "#!/bin/zsh\n[[ $1 == watch ]] && exit 9\nexit 0\n"
        try failureScript.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        do { try await service.start(service.configURL); fatalError("Failed watcher reported as running") } catch {}
        precondition(!service.running)
        print("GUI self-tests passed: preferences, Dock tri-state, core validation, atomic preservation, start/stop, duplicate prevention, disconnect, startup failure")
        exit(0)
    } catch { fputs("GUI self-test failed: \(error)\n", stderr); exit(1) }
}

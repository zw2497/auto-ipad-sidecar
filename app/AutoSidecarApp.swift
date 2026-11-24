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
            self?.statusItem?.button?.toolTip = "AutoSidecar — \(running ? L("Service running") : L("Service stopped"))"
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
        if !Self.model.config.isEmpty {
            action(Self.model.running ? L("Stop Service") : L("Start Service"),
                   Self.model.running ? #selector(stopService) : #selector(startService))
            if Self.model.trialDirectory != nil { menu.items.last?.isEnabled = false }
        }
        if !Self.model.config.isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: L("Checking connection…"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.target = self
            menu.addItem(item)
            // Refresh on each opening: the service may run without a Sidecar
            // session, and a session can also be ended outside this app.
            Task {
                await Self.model.refreshConnection()
                switch Self.model.connectionActive {
                case true?: item.title = L("Disconnect"); item.action = #selector(disconnectIPad)
                case false?: item.title = L("Connect iPad"); item.action = #selector(connectIPad)
                case nil: item.title = L("Connection status unavailable"); item.action = nil
                }
                item.isEnabled = item.action != nil && !Self.model.busy && Self.model.trialDirectory == nil
            }
        }
        if !Self.model.loginEnabled {
            action(Self.model.needsLoginApproval ? L("Approve Login Startup…") : L("Enable Launch at Login"), #selector(enableLogin))
        }
        menu.addItem(.separator())
        action(L("Settings…"), #selector(openSettings), key: ",")
        menu.addItem(.separator())
        action(L("Quit AutoSidecar"), #selector(quitApp), key: "q")
    }

    @objc private func startService() {
        Task { await Self.model.retry(); showConnectionError(L("Could not start service")) }
    }
    @objc private func stopService() {
        Task { await Self.model.stopService(); showConnectionError(L("Could not stop service")) }
    }
    @objc private func connectIPad() {
        Task { await Self.model.connect(); showConnectionError(L("Could not connect iPad")) }
    }
    @objc private func disconnectIPad() {
        Task { await Self.model.disconnect(); showConnectionError(L("Could not disconnect iPad")) }
    }
    private func showConnectionError(_ title: String) {
        guard !Self.model.message.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = Self.model.message
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
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
            w.title = L("AutoSidecar Settings")
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
                Section(L("Startup")) {
                    Toggle(L("Launch at login"), isOn: Binding(get: { model.loginEnabled }, set: { enabled in Task { await model.setLogin(enabled) } }))
                    if model.needsLoginApproval {
                        Button(L("Approve in System Settings…")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Text(L("Starts after login. The login screen and FileVault unlock are not supported."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Paired iPad")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.config["name"] as? String ?? L("No iPad paired"))
                            Text(L("Starts Sidecar when this iPad is connected by USB."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.config.isEmpty ? L("Choose iPad…") : L("Change…")) { model.message = ""; pairing = true }
                    }
                }
                Section(L("When iPad is the only display")) {
                    HStack {
                        Text(L("Desktop resolution"))
                        Spacer()
                        TextField(L("Width"), text: $draft.width).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70).accessibilityLabel(L("Desktop width"))
                        Text("×").foregroundStyle(.secondary)
                        TextField(L("Height"), text: $draft.height).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70).accessibilityLabel(L("Desktop height"))
                    }
                    Toggle(L("HiDPI display"), isOn: $draft.hiDPI)
                    Text(L("Dimensions are backing pixels. HiDPI halves the logical desktop size.\nDisplay changes apply on the next connection."))
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.config.isEmpty)
                Section(L("With other displays")) {
                    Picker(L("Use iPad as"), selection: $draft.layout) {
                        Text(L("Extended display")).tag("extend")
                        Text(L("Mirror main display")).tag("mirror")
                        Text(L("Keep system layout")).tag("preserve")
                    }
                }.disabled(model.config.isEmpty)
                DisclosureGroup(L("Advanced"), isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L("Virtual display refresh rate"))
                                Spacer()
                                TextField("60", text: $draft.hz)
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                    .frame(width: 72).accessibilityLabel(L("Virtual display refresh rate"))
                                Text("Hz").foregroundStyle(.secondary)
                            }
                            Text(L("24–120 Hz. Above 60 is experimental and does not guarantee Sidecar frame rate."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        DockFields(title: L("Dock with iPad only"), size: $draft.ipadSize, magnification: $draft.ipadMagnification)
                        Divider()
                        DockFields(title: L("Dock with other displays"), size: $draft.otherSize, magnification: $draft.otherMagnification)
                        Text(L("Dock settings are unchanged by default. Custom settings may require Automation permission."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("Show Logs")) { NSWorkspace.shared.open(model.logsURL) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
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
                Button(L("Cancel")) { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
                Button(L("Apply")) { Task { await model.save(draft) } }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold))
            Toggle(L("Custom icon size"), isOn: Binding(
                get: { !size.isEmpty }, set: { size = $0 ? "48" : "" }
            )).toggleStyle(.switch)
            if !size.isEmpty {
                HStack {
                    Text(L("Icon size"))
                    Spacer()
                    TextField("16–128", text: $size).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .accessibilityLabel(LF("%@ icon size", title))
                }
            }
            HStack {
                Text(L("Magnify on hover"))
                Spacer()
                Picker(L("Magnify on hover"), selection: Binding(
                    get: { magnification.isEmpty ? "unchanged" : (magnification == "off" ? "off" : "on") },
                    set: { magnification = $0 == "unchanged" ? "" : ($0 == "off" ? "off" : "64") }
                )) {
                    Text(L("Keep system settings")).tag("unchanged")
                    Text(L("Off")).tag("off")
                    Text(L("On")).tag("on")
                }.labelsHidden().pickerStyle(.menu).frame(width: 145)
            }
            if !magnification.isEmpty && magnification != "off" {
                HStack {
                    Text(L("Magnified size"))
                    Spacer()
                    TextField("16–128", text: $magnification).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .accessibilityLabel(LF("%@ magnification size", title))
                }
            }
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: ServiceModel
    let close: () -> Void
    @State private var serial = ""
    @State private var identifier = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Pair iPad")).font(.title2.weight(.semibold))
            Text(L("Connect and unlock your iPad by USB and complete any trust prompts.\nUse a physical display or remote access for initial setup."))
                .foregroundStyle(.secondary)
            Picker(L("USB device"), selection: $serial) {
                Text(L("Choose a device")).tag("")
                ForEach(model.usb) { Text("\($0.name) · \($0.id.suffix(6))").tag($0.id) }
            }.disabled(model.tested)
            Picker(L("Matching Sidecar device"), selection: $identifier) {
                Text(L("Choose a device")).tag("")
                ForEach(model.targets) { Text($0.name).tag($0.id) }
            }.disabled(model.tested)
            HStack {
                Button(L("Refresh Devices")) { Task { await model.discover(); selectDefaults() } }.disabled(model.tested)
                Spacer()
                Button(L("Test Connection")) { Task { await model.testPairing(serial: serial, identifier: identifier) } }
                    .disabled(serial.isEmpty || identifier.isEmpty || model.tested)
            }
            if model.busy { ProgressView(L("Working…")).controlSize(.small) }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if model.tested { Text(L("Confirm the intended iPad shows the Mac desktop. Saving briefly reconnects Sidecar.")) }
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    Task {
                        model.busy = true
                        do { try await model.discardTrial(); model.message = ""; close() }
                        catch { model.message = error.localizedDescription }
                        model.busy = false
                    }
                }
                Button(L("Confirm Display and Save")) {
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
        if let expected = ProcessInfo.processInfo.environment["AUTOSIDECAR_EXPECT_LANGUAGE"] {
            precondition(L("Apply") == (expected == "zh-Hans" ? "应用" : "Apply"), "Bundle language selection failed")
            precondition(LF("Operation failed (%d). Check the logs.", Int32(9)).contains("9"))
        }
        let input: [String: Any] = ["version": 1, "usbSerial": "fixture", "sidecarIdentifier": "fixture", "name": L("Test iPad"),
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
        let delegate = AppDelegate()
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(menu.items.contains { $0.title == L("Connect iPad") && $0.isEnabled })
        precondition(!menu.items.contains { $0.title == L("Disconnect") })
        precondition(menu.items.contains { $0.title == L("Stop Service") && $0.isEnabled })
        // Service state does not determine Sidecar state.
        model.connectionActive = true; model.running = false
        delegate.menuNeedsUpdate(menu)
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(menu.items.contains { $0.title == L("Disconnect") && $0.isEnabled })
        precondition(!menu.items.contains { $0.title == L("Connect iPad") })
        precondition(menu.items.contains { $0.title == L("Start Service") && $0.isEnabled })
        model.busy = true
        delegate.menuNeedsUpdate(menu)
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(menu.items.contains { $0.title == L("Disconnect") && !$0.isEnabled })
        model.busy = false
        model.connectionActive = nil
        delegate.menuNeedsUpdate(menu)
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(menu.items.contains { $0.title == L("Connection status unavailable") && !$0.isEnabled })
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
          connect) print -r -- "$@" > "${0:h}/connect-observed";;
          usb) print forbidden > "${0:h}/usb-observed"; exit 1;;
          session-snapshot) print '{"active":true,"otherCount":0}';;
          disconnect) print disconnected > "${0:h}/disconnect-observed";;
          *) exit 1;;
        esac
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let service = ServiceModel(testBase: root.appendingPathComponent("service"), executable: fake, preview: false)
        service.config = output
        try await service.writeValidated(output, to: service.configURL)
        await service.refreshConnection()
        precondition(service.connectionActive == true && !service.running, "Live session mistaken for service state")
        try await service.start(service.configURL)
        precondition(service.running && service.watcher?.isRunning == true)
        let pid = service.watcher!.processIdentifier
        try await service.start(service.configURL)
        precondition(service.watcher!.processIdentifier == pid, "Duplicate watcher started")
        await service.connect()
        precondition(service.message.isEmpty && !service.busy)
        let invocation = try String(contentsOf: root.appendingPathComponent("connect-observed"), encoding: .utf8)
        precondition(invocation.trimmingCharacters(in: .whitespacesAndNewlines) == "connect --config \(service.configURL.path)", "GUI did not invoke CLI connect with the saved configuration")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("usb-observed").path), "Manual connect incorrectly checked USB")
        precondition(service.watcher!.processIdentifier == pid, "Manual connect replaced the watcher")
        await service.disconnect()
        precondition(service.message.isEmpty && !service.busy)
        precondition(service.running && service.watcher?.processIdentifier == pid && service.watcher?.isRunning == true,
                     "Disconnect stopped the auto-connect service")
        let disconnectMarker = root.appendingPathComponent("disconnect-observed")
        precondition(FileManager.default.fileExists(atPath: disconnectMarker.path))
        try FileManager.default.removeItem(at: disconnectMarker)
        await service.stopService()
        precondition(!service.running && service.watcher == nil && service.message.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: disconnectMarker.path), "Stopping service invoked disconnect")
        await service.connect()
        precondition(!service.running && service.message.isEmpty, "Manual connect started the auto-connect service")
        await service.retry()
        precondition(service.running && service.message.isEmpty, "Start Service did not start the watcher")
        try await service.stop()
        precondition(FileManager.default.fileExists(atPath: disconnectMarker.path), "Quit cleanup no longer disconnects")
        let absentScript = "#!/bin/zsh\nexit 1\n"
        try absentScript.write(to: fake, atomically: true, encoding: .utf8)
        await service.refreshConnection()
        precondition(service.connectionActive == nil, "Failed probe retained stale state")
        await service.connect()
        precondition(!service.message.isEmpty && !service.busy && !service.running, "CLI failure incorrectly started the service")
        await service.disconnect()
        precondition(!service.message.isEmpty && !service.busy, "Disconnect failure was hidden")
        let failureScript = "#!/bin/zsh\n[[ $1 == watch ]] && exit 9\nexit 0\n"
        try failureScript.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        do { try await service.start(service.configURL); fatalError("Failed watcher reported as running") } catch {}
        precondition(!service.running)
        print("GUI self-tests passed: preferences, validation, menu actions and busy state, CLI connect without USB, independent disconnect/stop/start, quit cleanup, command failure, error recovery, duplicate prevention, startup failure")
        exit(0)
    } catch { fputs("GUI self-test failed: \(error)\n", stderr); exit(1) }
}

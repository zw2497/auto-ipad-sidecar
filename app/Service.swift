import AppKit
import SwiftUI
import ServiceManagement
import Darwin

struct CommandResult {
    let code: Int32
    let output: String
}

// All potentially blocking CLI work runs away from the UI thread.
func command(_ executable: URL, _ arguments: [String], timeout: Double = 55) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(code: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)))
            } catch { continuation.resume(throwing: error) }
        }
    }
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DeviceChoice: Identifiable {
    let id: String
    let name: String
}

struct Preferences {
    var width = "1920"
    var height = "1080"
    var hiDPI = true
    var hz = "60"
    var layout = "extend"
    // Blank means do not manage; magnification also accepts "off".
    var ipadSize = ""
    var ipadMagnification = ""
    var otherSize = ""
    var otherMagnification = ""

    init(_ config: [String: Any] = [:]) {
        if let display = config["display"] as? [String: Any] {
            width = "\((display["width"] as? NSNumber)?.intValue ?? 1920)"
            height = "\((display["height"] as? NSNumber)?.intValue ?? 1080)"
            hz = "\((display["refreshRate"] as? NSNumber)?.doubleValue ?? 60)"
            hiDPI = (display["hiDPI"] as? NSNumber)?.boolValue ?? true
        }
        layout = config["withOtherDisplays"] as? String ?? "extend"
        let dock = config["dock"] as? [String: [String: Any]] ?? [:]
        func value(_ profile: String, _ key: String) -> String {
            guard let number = dock[profile]?[key] as? NSNumber else { return "" }
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "off" : "\(number.intValue)"
        }
        ipadSize = value("ipadOnly", "size"); ipadMagnification = value("ipadOnly", "magnification")
        otherSize = value("withOtherDisplays", "size"); otherMagnification = value("withOtherDisplays", "magnification")
    }

    func applying(to source: [String: Any]) throws -> [String: Any] {
        guard let w = Int(width), let h = Int(height), let rate = Double(hz), rate.isFinite else {
            throw AppError(message: "请输入有效的分辨率和刷新率。")
        }
        var config = source
        config["display"] = ["width": w, "height": h, "refreshRate": rate, "hiDPI": hiDPI]
        config["withOtherDisplays"] = layout
        func profile(_ size: String, _ magnification: String) throws -> [String: Any] {
            var result: [String: Any] = [:]
            if !size.isEmpty {
                guard let n = Int(size), (16...128).contains(n) else { throw AppError(message: "Dock 大小需为 16–128，留空表示不接管。") }
                result["size"] = n
            }
            if !magnification.isEmpty {
                if magnification.lowercased() == "off" { result["magnification"] = false }
                else {
                    guard let n = Int(magnification), (16...128).contains(n) else { throw AppError(message: "Dock 放大尺寸需为 16–128；off 表示关闭，留空表示不接管。") }
                    result["magnification"] = n
                }
            }
            return result
        }
        let ipad = try profile(ipadSize, ipadMagnification)
        let other = try profile(otherSize, otherMagnification)
        var dock: [String: Any] = [:]
        if !ipad.isEmpty { dock["ipadOnly"] = ipad }
        if !other.isEmpty { dock["withOtherDisplays"] = other }
        config["dock"] = dock.isEmpty ? nil : dock
        return config
    }
}

@MainActor
final class ServiceModel: ObservableObject {
    static let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--self-test")
    let previewMode: Bool
    let base: URL
    let logsURL: URL
    let core: URL
    var configURL: URL { base.appendingPathComponent("config.plist") }
    var legacyPlist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.auto-sidecar.plist") }
    @Published var serviceText = "自动连接服务未运行"
    @Published var running = false
    @Published var loginText = "正在检查登录启动…"
    @Published var loginEnabled = false
    @Published var needsLoginApproval = false
    @Published var busy = false
    @Published var message = ""
    @Published var config: [String: Any] = [:]
    @Published var usb: [DeviceChoice] = []
    @Published var targets: [DeviceChoice] = []
    @Published var tested = false
    var watcher: Process?
    var watcherConfig: URL?
    var trialDirectory: URL?
    var pendingPairing: [String: Any]?
    var stopping = false
    var quitting = false

    init(testBase: URL? = nil, executable: URL? = nil, preview: Bool? = nil) {
        let preview = preview ?? Self.preview
        previewMode = preview
        base = testBase ?? (preview ? FileManager.default.temporaryDirectory.appendingPathComponent("AutoSidecar-preview-\(UUID().uuidString)") :
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AutoSidecar"))
        logsURL = testBase != nil ? base.appendingPathComponent("Logs") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AutoSidecar")
        core = executable ?? Bundle.main.url(forResource: "auto-sidecar", withExtension: nil)!
        if previewMode {
            config = ["version": 1, "name": "我的 iPad", "usbSerial": "preview", "sidecarIdentifier": "preview",
                      "display": ["width": 2628, "height": 1970, "refreshRate": 60, "hiDPI": true], "withOtherDisplays": "extend"]
            running = true; serviceText = "自动连接服务运行中"
            loginEnabled = true; loginText = "登录后自动启动已开启"
        } else { load(); refreshLogin() }
    }

    func load() {
        do {
            guard FileManager.default.fileExists(atPath: configURL.path) else { return }
            config = try PropertyListSerialization.propertyList(from: Data(contentsOf: configURL), format: nil) as? [String: Any] ?? [:]
        } catch { message = "无法读取配置：\(error.localizedDescription)" }
    }

    func refreshLogin() {
        guard !previewMode else { return }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        needsLoginApproval = status == .requiresApproval
        switch status {
        case .enabled: loginText = "登录后自动启动已开启"
        case .requiresApproval: loginText = "登录启动等待系统批准"
        case .notRegistered: loginText = "登录后自动启动未开启"
        default: loginText = "登录启动不可用"
        }
    }

    func setLogin(_ enabled: Bool) async {
        guard !previewMode else { return }
        busy = true; defer { busy = false; refreshLogin() }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch { message = "无法修改登录启动：\(error.localizedDescription)\n请先将应用放入 Applications 文件夹。" }
    }

    func checked(_ args: [String]) async throws -> String {
        let result = try await command(core, args)
        guard result.code == 0 else { throw AppError(message: result.output.isEmpty ? "操作失败（\(result.code)），请查看日志。" : result.output) }
        return result.output
    }

    func bootstrap() async {
        guard !previewMode else { return }
        busy = true; defer { busy = false }
        do {
            // Transfer ownership from the old CLI LaunchAgent, never run two watchers.
            let job = "gui/\(getuid())/local.auto-sidecar"
            let loaded = try await command(URL(fileURLWithPath: "/bin/launchctl"), ["print", job])
            let legacy = FileManager.default.fileExists(atPath: legacyPlist.path)
            if loaded.code == 0 {
                _ = try await command(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", job])
                var gone = false
                for _ in 0..<220 {
                    let state = try await command(URL(fileURLWithPath: "/bin/launchctl"), ["print", job])
                    if state.code != 0 { gone = true; break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                if !gone { throw AppError(message: "旧后台服务尚未退出，请稍后重新打开应用。") }
            }
            if legacy {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let backup = base.appendingPathComponent("legacy-launchagent-\(UUID().uuidString).plist")
                try FileManager.default.moveItem(at: legacyPlist, to: backup)
                do { try SMAppService.mainApp.register() }
                catch { message = "已接管旧服务；请在设置中重新开启登录启动。\n\(error.localizedDescription)" }
            }
            refreshLogin()
            if !config.isEmpty { try await start(configURL) }
        } catch { serviceText = "自动连接服务未运行"; message = error.localizedDescription }
    }

    func start(_ url: URL) async throws {
        guard !previewMode else { return }
        if watcher?.isRunning == true { return }
        _ = try await checked(["config", "validate", "--config", url.path])
        let logs = logsURL
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("gui-service.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = core; process.arguments = ["watch", "--config", url.path]
        process.standardOutput = handle; process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["AUTOSIDECAR_GUI_PARENT_PID"] = "\(getpid())"
        process.environment = environment
        process.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.watcher === child else { return }
                self.running = false
                if !self.stopping { self.serviceText = "自动连接服务意外停止"; self.message = "后台服务已停止，请查看日志后重试。" }
            }
        }
        try process.run(); watcher = process; watcherConfig = url
        try await Task.sleep(nanoseconds: 500_000_000)
        guard process.isRunning else { throw AppError(message: "后台服务启动失败。可能已有 CLI 实例运行，请查看日志。") }
        running = true; serviceText = "自动连接服务运行中"
    }

    // Keep the virtual display alive until Sidecar disconnect has completed.
    func stop(disconnect: Bool = true) async throws {
        guard let process = watcher else { return }
        stopping = true; defer { stopping = false }
        if disconnect, process.isRunning, let url = watcherConfig {
            let state = try await command(core, ["session-snapshot", "--config", url.path])
            if let data = state.output.data(using: .utf8),
               let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any], snapshot["active"] as? Bool == true {
                _ = try await checked(["disconnect", "--config", url.path])
            }
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<220 {
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !process.isRunning else { throw AppError(message: "后台服务仍在清理，尚未退出。请稍后重试。") }
        if let url = watcherConfig {
            let record = url.deletingLastPathComponent().appendingPathComponent("dock-restoration.plist")
            if FileManager.default.fileExists(atPath: record.path) {
                _ = try await checked(["dock-restore", "--config", url.path])
            }
        }
        watcher = nil; watcherConfig = nil; running = false; serviceText = "自动连接服务未运行"
    }

    func writeValidated(_ value: [String: Any], to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = url.deletingLastPathComponent().appendingPathComponent(".candidate-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: staging) }
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw AppError(message: "无法写入临时配置。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        _ = try await checked(["config", "validate", "--config", staging.path])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func reloadOwned() async throws {
        guard let watcher, watcher.isRunning, let url = watcherConfig else { throw AppError(message: "设置已保存，但后台未运行。") }
        let id = UUID().uuidString
        let dir = url.deletingLastPathComponent()
        let data = try PropertyListSerialization.data(fromPropertyList: ["id": id], format: .xml, options: 0)
        let request = dir.appendingPathComponent("reload-request.plist")
        try data.write(to: request, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        guard kill(watcher.processIdentifier, SIGHUP) == 0 else { throw AppError(message: "设置已保存，但通知后台失败。") }
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let reply = NSDictionary(contentsOf: dir.appendingPathComponent("reload-result.plist")), reply["id"] as? String == id {
                guard reply["ok"] as? Bool == true else { throw AppError(message: reply["message"] as? String ?? "后台拒绝了设置。") }
                return
            }
        }
        throw AppError(message: "设置已保存，但后台尚未确认加载，请查看日志。")
    }

    func save(_ preferences: Preferences) async {
        guard !previewMode else { message = "预览模式：没有保存或更改系统设置。"; return }
        busy = true; defer { busy = false }
        do {
            let next = try preferences.applying(to: config)
            try await writeValidated(next, to: configURL)
            config = next
            if watcher?.isRunning == true { try await reloadOwned() }
            else { try await start(configURL) }
            message = "设置已保存。分辨率、HiDPI 和刷新率将在下次连接时生效。"
        } catch { message = error.localizedDescription }
    }

    func discover() async {
        guard !previewMode else {
            usb = [.init(id: "preview", name: "我的 iPad")]; targets = usb; return
        }
        busy = true; defer { busy = false }
        do {
            let output = try await checked(["devices-json"])
            guard let data = output.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError(message: "无法读取设备列表。") }
            usb = (result["usb"] as? [[String: String]] ?? []).compactMap { d in d["serial"].map { DeviceChoice(id: $0, name: d["name"] ?? "iPad") } }
            targets = (result["sidecar"] as? [[String: String]] ?? []).compactMap { d in d["identifier"].map { DeviceChoice(id: $0, name: d["name"] ?? "iPad") } }
            if usb.isEmpty || targets.isEmpty { message = "请接入并解锁 iPad，完成系统信任操作，然后刷新设备。" }
        } catch { message = error.localizedDescription }
    }

    func testPairing(serial: String, identifier: String) async {
        guard !previewMode else { tested = true; return }
        busy = true; defer { busy = false }
        do {
            var candidate = config
            candidate["version"] = 1; candidate["usbSerial"] = serial; candidate["sidecarIdentifier"] = identifier
            candidate["name"] = targets.first(where: { $0.id == identifier })?.name ?? "iPad"
            if candidate["display"] == nil { candidate["display"] = ["width": 1920, "height": 1080, "refreshRate": 60, "hiDPI": true] }
            let dir = base.appendingPathComponent("pairing-\(UUID().uuidString)")
            let url = dir.appendingPathComponent("config.plist")
            try await writeValidated(candidate, to: url)
            try await stop()
            trialDirectory = dir; pendingPairing = candidate
            try await start(url)
            for _ in 0..<35 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let result = try await command(core, ["session-snapshot", "--config", url.path])
                if let data = result.output.data(using: .utf8), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], state["active"] as? Bool == true {
                    tested = true; message = "请确认目标 iPad 已显示 Mac 桌面，再保存绑定。"; return
                }
            }
            throw AppError(message: "未能确认随航画面，请解锁 iPad 后重试。原来的绑定没有更改。")
        } catch {
            let failure = error.localizedDescription
            do { try await discardTrial() } catch { message = "\(failure)\n恢复原服务失败：\(error.localizedDescription)"; return }
            message = failure
        }
    }

    func confirmPairing() async {
        busy = true; defer { busy = false }
        do {
            guard let candidate = pendingPairing else { return }
            // Save only after the user confirms the actual device, keeping old config on cancellation.
            try await writeValidated(candidate, to: configURL)
            config = candidate
            try await stop()
            cleanTrial()
            try await start(configURL)
            message = "iPad 已绑定。以后插线即可自动连接。"
        } catch { message = error.localizedDescription }
    }

    func cleanTrial() {
        if let dir = trialDirectory { try? FileManager.default.removeItem(at: dir) }
        trialDirectory = nil; pendingPairing = nil; tested = false
    }

    func discardTrial() async throws {
        if trialDirectory != nil { try await stop(); cleanTrial() }
        if !config.isEmpty && watcher?.isRunning != true { try await start(configURL) }
    }

    func retry() async {
        busy = true; defer { busy = false }
        do { try await start(configURL) } catch { message = error.localizedDescription }
    }

    func quit() async {
        guard !quitting else { return }
        quitting = true; busy = true
        defer { quitting = false; busy = false }
        if !previewMode, let url = watcherConfig,
           let output = try? await checked(["session-snapshot", "--config", url.path]),
           let data = output.data(using: .utf8), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           state["active"] as? Bool == true, (state["otherCount"] as? Int) == 0 {
            let alert = NSAlert()
            alert.messageText = "退出后，iPad 将停止显示 Mac 桌面"
            alert.informativeText = "自动连接也会停止，直到重新打开 AutoSidecar。登录启动偏好会保留。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "退出 AutoSidecar")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertSecondButtonReturn { return }
        }
        do {
            try await stop()
            cleanTrial()
            NSApp.reply(toApplicationShouldTerminate: true)
            exit(0)
        } catch { message = "未能完整退出：\(error.localizedDescription)"; NSApp.reply(toApplicationShouldTerminate: false) }
    }
}

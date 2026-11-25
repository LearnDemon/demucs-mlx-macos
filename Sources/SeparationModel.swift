import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

// MARK: - 分离模式

enum SeparationMode: String, CaseIterable, Identifiable {
    case fourStems
    case vocals
    case instrumental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourStems: return "四轨分离"
        case .vocals: return "仅人声"
        case .instrumental: return "仅伴奏"
        }
    }

    var subtitle: String {
        switch self {
        case .fourStems: return "人声 · 鼓 · 贝斯 · 其他乐器"
        case .vocals: return "去掉伴奏，保留演唱"
        case .instrumental: return "去掉人声，保留伴奏"
        }
    }

    var symbol: String {
        switch self {
        case .fourStems: return "square.grid.2x2"
        case .vocals: return "mic"
        case .instrumental: return "music.note"
        }
    }

    var backendValue: String {
        switch self {
        case .fourStems: return "four"
        case .vocals: return "vocals"
        case .instrumental: return "instrumental"
        }
    }

    var folderTag: String {
        switch self {
        case .fourStems: return "四轨"
        case .vocals: return "人声"
        case .instrumental: return "伴奏"
        }
    }
}

// MARK: - Demucs 模型

enum DemucsModel: String, CaseIterable, Identifiable {
    case standard = "htdemucs"
    case fineTuned = "htdemucs_ft"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准版"
        case .fineTuned: return "精细版"
        }
    }

    var displayName: String {
        switch self {
        case .standard: return "标准版 htdemucs"
        case .fineTuned: return "精细版 htdemucs_ft"
        }
    }

    var subtitle: String {
        switch self {
        case .standard:
            return "速度快 · 约 \(sizeText)"
        case .fineTuned:
            return "质量更高 · 约 \(sizeText) · 慢约 4 倍"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "bolt.fill"
        case .fineTuned: return "sparkles"
        }
    }

    var sizeText: String {
        switch self {
        case .standard: return "160 MB"
        case .fineTuned: return "641 MB"
        }
    }

    var folderTag: String {
        switch self {
        case .standard: return "标准"
        case .fineTuned: return "精细"
        }
    }

    var weightsFileName: String { "\(rawValue).safetensors" }
    var configFileName: String { "\(rawValue)_config.json" }

    /// 与 demucs_mlx.hub.PUBLISHED 中的大小保持一致，用于判断缓存是否完整。
    var expectedWeightBytes: Int64 {
        switch self {
        case .standard: return 168_005_865
        case .fineTuned: return 672_024_519
        }
    }
}

// MARK: - 后端事件

private struct BackendEvent: Decodable {
    let event: String
    let text: String?
    let progress: Double?
    let files: [String]?
    let message: String?
    let outputDir: String?
    let model: String?
    let reason: String?
    let activeMemoryMB: Int?

    enum CodingKeys: String, CodingKey {
        case event, text, progress, files, message, model, reason
        case outputDir = "output_dir"
        case activeMemoryMB = "active_memory_mb"
    }
}

// MARK: - 状态模型

@MainActor
final class SeparationModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var mode: SeparationMode = .fourStems
    @Published private(set) var demucsModel: DemucsModel
    @Published var outputRoot: URL {
        didSet {
            UserDefaults.standard.set(outputRoot.path, forKey: Self.outputRootKey)
        }
    }
    @Published var isRunning = false
    @Published var progress: Double?
    @Published var statusText = "把音频文件拖到下面的区域"
    @Published var logText = ""
    @Published var resultFiles: [URL] = []
    @Published var resultDir: URL?
    @Published var errorText: String?
    @Published var startedAt: Date?
    @Published var modelReady = false
    @Published var toolPath: String?
    /// 常驻引擎当前装在内存里的模型；nil 表示没有模型占用内存。
    @Published var loadedModel: DemucsModel?

    private static let outputRootKey = "outputRoot"
    private static let modelKey = "demucsModel"
    /// 空闲多久后自动把模型从内存卸载。精细版占用较大，5 分钟比较平衡。
    private static let idleUnloadSeconds: TimeInterval = 5 * 60
    private static let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff", "aif", "wma", "mp4", "mov",
    ]

    // 常驻引擎只启动一次，之后通过 stdin 发送命令。
    private var worker: Process?
    private var workerInput: FileHandle?
    private var workerStdout: Pipe?
    private var workerStderr: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var logLines: [String] = []

    private var sawFinalEvent = false
    private var userCancelled = false
    private var idleUnloadTimer: Timer?
    private var forceKillTimer: Timer?

    init() {
        let defaultRoot = FileManager.default
            .urls(for: .musicDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("音乐分轨结果", isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: Self.outputRootKey), !saved.isEmpty {
            outputRoot = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            outputRoot = defaultRoot
        }
        let savedModel = UserDefaults.standard.string(forKey: Self.modelKey)
            .flatMap(DemucsModel.init(rawValue:))
        demucsModel = savedModel ?? .standard
        refreshEnvironment()
    }

    deinit {
        idleUnloadTimer?.invalidate()
        forceKillTimer?.invalidate()
    }

    // MARK: 环境检查

    func refreshEnvironment() {
        toolPath = Self.locateTool()?.path
        modelReady = isModelAvailable(demucsModel)
    }

    func isModelAvailable(_ model: DemucsModel) -> Bool {
        let cache = cacheDirectory()
        let weights = cache.appendingPathComponent(model.weightsFileName)
        let config = cache.appendingPathComponent(model.configFileName)
        guard FileManager.default.fileExists(atPath: config.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: weights.path),
              let number = attributes[.size] as? NSNumber else {
            return false
        }
        return number.int64Value == model.expectedWeightBytes
    }

    private func cacheDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["DEMUCS_MLX_CACHE_DIR"],
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(
                fileURLWithPath: (custom as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/demucs-mlx", isDirectory: true)
    }

    private static func locateTool() -> URL? {
        if let custom = UserDefaults.standard.string(forKey: "demucsToolPath"),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/anaconda3/bin/demucs-mlx",
            "/opt/homebrew/bin/demucs-mlx",
            "/usr/local/bin/demucs-mlx",
            "\(home)/miniconda3/bin/demucs-mlx",
            "\(home)/anaconda3/bin/demucs-mlx",
            "\(home)/miniforge3/bin/demucs-mlx",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // 兜底：通过登录 shell 的 PATH 查找。
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v demucs-mlx"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
            shell.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func pythonExecutable(for tool: URL) -> URL? {
        let directory = tool.resolvingSymlinksInPath().deletingLastPathComponent()
        for name in ["python3", "python"] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: 选择文件

    func setInput(_ url: URL) {
        guard !isRunning else {
            errorText = "请等待当前任务完成，或先点“取消”。"
            return
        }
        guard url.isFileURL else {
            errorText = "请拖入本地音频文件。"
            return
        }
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            errorText = "不支持的格式：.\(ext)。请使用 mp3、wav、m4a、flac 等音频文件。"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorText = "文件不存在：\(url.lastPathComponent)"
            return
        }
        inputURL = url
        resultFiles = []
        resultDir = nil
        errorText = nil
        progress = nil
        statusText = "已选择：\(url.lastPathComponent)"
    }

    func acceptDrop(_ provider: NSItemProvider) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { [weak self] data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            Task { @MainActor in
                self?.setInput(url)
            }
        }
        return true
    }

    // MARK: 选择模型

    func selectModel(_ newModel: DemucsModel) {
        guard !isRunning else {
            errorText = "分离进行中，暂时不能切换模型。"
            return
        }
        guard newModel != demucsModel else { return }

        demucsModel = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: Self.modelKey)
        refreshEnvironment()
        errorText = nil

        // 关键：切换模型时立刻卸载上一款，避免两个模型同时占内存。
        if let current = loadedModel, current != newModel {
            statusText = "正在卸载\(current.title)模型…"
            appendLog("切换模型：卸载 \(current.rawValue)")
            _ = sendCommand(["cmd": "unload", "reason": "switch"])
        } else {
            statusText = "已选择\(newModel.title)模型"
        }
    }

    // MARK: 开始 / 取消

    func start() {
        guard !isRunning else { return }
        guard let input = inputURL else {
            errorText = "请先选择或拖入一个音频文件。"
            return
        }
        guard let tool = Self.locateTool() else {
            errorText = "没有找到 demucs-mlx。请确认它安装在 conda 环境中。"
            return
        }
        guard Self.pythonExecutable(for: tool) != nil else {
            errorText = "没有找到 demucs-mlx 所在环境的 python3。"
            return
        }
        guard let helper = Bundle.main.url(forResource: "gui_backend", withExtension: "py") else {
            errorText = "应用内缺少后端脚本，请重新构建应用。"
            return
        }

        let outputDirectory: URL
        do {
            try FileManager.default.createDirectory(
                at: outputRoot,
                withIntermediateDirectories: true
            )
            outputDirectory = try makeUniqueOutputDirectory(for: input)
        } catch {
            errorText = "无法创建输出目录：\(error.localizedDescription)"
            return
        }

        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        logLines.removeAll()
        logText = ""
        sawFinalEvent = false
        userCancelled = false
        errorText = nil
        resultFiles = []
        resultDir = outputDirectory
        progress = 0
        startedAt = Date()
        statusText = "正在启动…"
        appendLog("模型：\(demucsModel.displayName)")
        appendLog("$ \(helper.path) --worker")

        if !isModelAvailable(demucsModel) {
            appendLog("本地没有 \(demucsModel.displayName) 的完整缓存，首次加载会自动下载约 \(demucsModel.sizeText)。")
        }

        let command: [String: Any] = [
            "cmd": "separate",
            "input": input.path,
            "output_dir": outputDirectory.path,
            "mode": mode.backendValue,
            "model": demucsModel.rawValue,
        ]

        // isRunning 必须在发送命令前置位，避免极快的错误事件把界面卡在“未运行”。
        isRunning = true
        guard sendCommand(command) else {
            isRunning = false
            startedAt = nil
            statusText = "启动失败"
            progress = nil
            return
        }
    }

    func cancel() {
        guard isRunning else { return }
        userCancelled = true
        statusText = "正在取消…"
        appendLog("用户取消，正在结束分离进程并释放内存…")
        terminateWorker(after: 3)
    }

    // MARK: 常驻引擎

    @discardableResult
    private func sendCommand(_ command: [String: Any]) -> Bool {
        guard ensureWorker(), let input = workerInput else { return false }
        guard let payload = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: payload, encoding: .utf8) else {
            errorText = "无法序列化引擎命令。"
            return false
        }
        do {
            try input.write(contentsOf: Data((text + "\n").utf8))
            return true
        } catch {
            errorText = "无法与分离引擎通信：\(error.localizedDescription)"
            if let worker, worker.isRunning {
                worker.terminate()
            }
            return false
        }
    }

    private func ensureWorker() -> Bool {
        if let worker, worker.isRunning {
            return true
        }
        resetWorkerReferences()

        guard let tool = Self.locateTool() else {
            errorText = "没有找到 demucs-mlx。请确认它安装在 conda 环境中。"
            return false
        }
        guard let python = Self.pythonExecutable(for: tool) else {
            errorText = "没有找到 demucs-mlx 所在环境的 python3。"
            return false
        }
        guard let helper = Bundle.main.url(forResource: "gui_backend", withExtension: "py") else {
            errorText = "应用内缺少后端脚本，请重新构建应用。"
            return false
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let task = Process()
        task.executableURL = python
        task.arguments = [helper.path, "--worker"]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        let extraPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            tool.deletingLastPathComponent().path,
        ]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        // 国内网络直连 Hugging Face 经常失败；用户自己设过就不覆盖。
        if let endpoint = environment["HF_ENDPOINT"], !endpoint.isEmpty {
            // 保持用户设置。
        } else {
            environment["HF_ENDPOINT"] = "https://hf-mirror.com"
        }
        task.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consumeStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consumeStderr(data)
            }
        }
        task.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                self?.handleWorkerExit(code: code)
            }
        }

        do {
            try task.run()
        } catch {
            errorText = "无法启动分离引擎：\(error.localizedDescription)"
            return false
        }

        worker = task
        workerInput = stdinPipe.fileHandleForWriting
        workerStdout = stdoutPipe
        workerStderr = stderrPipe
        appendLog("分离引擎已启动（PID \(task.processIdentifier)）")
        return true
    }

    private func resetWorkerReferences() {
        workerStdout?.fileHandleForReading.readabilityHandler = nil
        workerStderr?.fileHandleForReading.readabilityHandler = nil
        try? workerInput?.close()
        worker = nil
        workerInput = nil
        workerStdout = nil
        workerStderr = nil
        loadedModel = nil
    }

    private func handleWorkerExit(code: Int32) {
        forceKillTimer?.invalidate()
        forceKillTimer = nil
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil

        let stdoutPipe = workerStdout
        let stderrPipe = workerStderr
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        // 进程退出后把管道里剩下的输出读完，避免丢掉最后的错误信息。
        if let stdoutPipe {
            let rest = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { consumeStdout(rest) }
        }
        if let stderrPipe {
            let rest = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { consumeStderr(rest) }
        }

        resetWorkerReferences()

        guard isRunning else { return }
        isRunning = false
        startedAt = nil

        if userCancelled {
            userCancelled = false
            progress = nil
            statusText = "已取消"
        } else if !sawFinalEvent {
            errorText = "分离引擎意外退出（退出码 \(code)）。请重试。"
            statusText = "分离失败"
            progress = nil
        }
    }

    private func terminateWorker(after seconds: TimeInterval) {
        guard let worker, worker.isRunning else { return }
        let pid = worker.processIdentifier
        worker.terminate()

        forceKillTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            // SIGTERM 在推理过程中可能来不及处理，超时后强制结束。
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        forceKillTimer = timer
    }

    func shutdown() {
        idleUnloadTimer?.invalidate()
        forceKillTimer?.invalidate()
        if let worker, worker.isRunning {
            try? workerInput?.write(contentsOf: Data("{\"cmd\":\"shutdown\"}\n".utf8))
            worker.terminate()
        }
        resetWorkerReferences()
    }

    // MARK: 空闲卸载

    private func scheduleIdleUnload() {
        idleUnloadTimer?.invalidate()
        guard let worker, worker.isRunning, loadedModel != nil else { return }

        let timer = Timer(timeInterval: Self.idleUnloadSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performIdleUnload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleUnloadTimer = timer
    }

    private func performIdleUnload() {
        idleUnloadTimer = nil
        guard !isRunning, let worker, worker.isRunning, loadedModel != nil else { return }
        statusText = "空闲中，正在释放模型内存…"
        appendLog("空闲超过 \(Int(Self.idleUnloadSeconds / 60)) 分钟，卸载模型释放内存")
        _ = sendCommand(["cmd": "unload", "reason": "idle"])
    }

    private func makeUniqueOutputDirectory(for input: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let track = input.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = "\(track)_\(mode.folderTag)_\(demucsModel.folderTag)_\(formatter.string(from: Date()))"

        var candidate = outputRoot.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputRoot.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    // MARK: 进程输出

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            handleStdoutLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer[stderrBuffer.startIndex..<newline]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                appendLog(line)
            }
        }
    }

    private func handleStdoutLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(BackendEvent.self, from: data) else {
            appendLog(line)
            return
        }

        switch event.event {
        case "stage":
            if let text = event.text { statusText = text }
            if let value = event.progress { progress = max(progress ?? 0, value) }
        case "progress":
            if let value = event.progress {
                progress = max(progress ?? 0, min(1, max(0, value)))
                if isRunning { statusText = "正在分离音频…" }
            }
        case "indeterminate":
            progress = nil
            if let text = event.text { statusText = text }
        case "model_loaded":
            if let name = event.model, let model = DemucsModel(rawValue: name) {
                loadedModel = model
                appendLog("已加载\(model.title)模型\(memorySuffix(event))")
            }
        case "model_unloaded":
            let name = event.model.flatMap(DemucsModel.init(rawValue:))
            let title = name?.title ?? "模型"
            loadedModel = nil
            appendLog("已卸载\(title)（\(reasonText(event.reason))）\(memorySuffix(event))")
            if !isRunning {
                statusText = "已释放模型内存"
            }
        case "status":
            if let name = event.model {
                loadedModel = DemucsModel(rawValue: name)
            } else {
                loadedModel = nil
            }
        case "done":
            sawFinalEvent = true
            progress = 1
            statusText = "分离完成"
            if let files = event.files {
                resultFiles = files.map { URL(fileURLWithPath: $0) }
            }
            if let dir = event.outputDir {
                resultDir = URL(fileURLWithPath: dir, isDirectory: true)
            }
            appendLog("完成：\(resultFiles.count) 个文件\(memorySuffix(event))")
            finishRun()
        case "error":
            sawFinalEvent = true
            progress = nil
            errorText = event.message ?? "未知错误"
            statusText = "分离失败"
            appendLog("错误：\(errorText ?? "未知错误")")
            finishRun()
        case "pong":
            break
        default:
            appendLog(line)
        }
    }

    private func memorySuffix(_ event: BackendEvent) -> String {
        guard let mb = event.activeMemoryMB else { return "" }
        return "，MLX 占用约 \(mb) MB"
    }

    private func reasonText(_ reason: String?) -> String {
        switch reason {
        case "switch": return "切换模型"
        case "idle": return "空闲释放"
        case "shutdown": return "程序退出"
        case "signal": return "进程结束"
        case "exit": return "任务结束"
        default: return "手动释放"
        }
    }

    private func finishRun() {
        guard isRunning else { return }
        isRunning = false
        startedAt = nil
        forceKillTimer?.invalidate()
        forceKillTimer = nil
        // 模型仍留在常驻引擎里，空闲一段时间后再卸载。
        scheduleIdleUnload()
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 600 {
            logLines.removeFirst(logLines.count - 600)
        }
        logText = logLines.joined(separator: "\n")
    }

    // MARK: 打开结果

    func revealResults() {
        if !resultFiles.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(resultFiles)
        } else if let resultDir {
            NSWorkspace.shared.open(resultDir)
        }
    }

    func openResultDirectory() {
        if let resultDir {
            NSWorkspace.shared.open(resultDir)
        } else {
            NSWorkspace.shared.open(outputRoot)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

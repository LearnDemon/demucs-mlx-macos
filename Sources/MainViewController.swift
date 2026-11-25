import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 主界面

final class MainViewController: NSViewController {
    private let model = SeparationModel()
    private var cancellable: AnyCancellable?
    private var tickTimer: Timer?
    private var renderedResults: [URL] = []
    private var logExpanded = false
    private var progressWasIndeterminate = false
    private var didAutoScrollResults = false

    private let scrollView = NSScrollView()
    private let contentView = FlippedView()
    private let contentStack = NSStackView()

    private let dropZone = DropZoneView()
    private var modeCards: [(card: ChoiceCardView, mode: SeparationMode)] = []
    private var modelCards: [(card: ChoiceCardView, model: DemucsModel)] = []
    private let outputPathLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton()
    private let cancelButton = NSButton()
    private let progressCard = CardView()
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let errorCard = CardView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let resultsCard = CardView()
    private let resultsListStack = NSStackView()
    private let logCard = CardView()
    private let logTextView = NSTextView()
    private let logToggleButton = NSButton()
    private let statusDot = NSView()
    private let modelStatusLabel = NSTextField(labelWithString: "")
    private let engineStatusLabel = NSTextField(labelWithString: "")
    private let toolStatusLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = BackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()

        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshUI()
            }
        }

        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        refreshUI()
    }

    deinit {
        tickTimer?.invalidate()
    }

    func shutdown() {
        model.shutdown()
    }

    // MARK: - 搭界面

    private func buildInterface() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
        ])

        addSection(makeHeader())
        addSection(makeDropZone())
        addSection(makeModelSection())
        addSection(makeModeSection())
        addSection(makeOutputSection())
        addSection(makeActionSection())
        addSection(makeProgressCard())
        addSection(makeErrorCard())
        addSection(makeResultsCard())
        addSection(makeLogSection())
        addSection(makeFooter())

        progressCard.isHidden = true
        errorCard.isHidden = true
        resultsCard.isHidden = true
        logCard.isHidden = true
        cancelButton.isHidden = true
    }

    private func addSection(_ section: NSView) {
        section.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func makeHeader() -> NSView {
        let badge = IconBadgeView()

        let title = makeLabel("音乐分轨", font: roundedFont(size: 25, weight: .bold))
        let subtitle = makeLabel(
            "Demucs MLX · 本地处理，音频不会上传",
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor
        )
        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let refreshButton = NSButton(
            image: symbolImage("arrow.clockwise"),
            target: self,
            action: #selector(refreshEnvironment)
        )
        refreshButton.bezelStyle = .rounded
        refreshButton.toolTip = "重新检测模型和 demucs-mlx"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [badge, textStack, spacer, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        return header
    }

    private func makeDropZone() -> NSView {
        dropZone.onClick = { [weak self] in
            self?.chooseAudio()
        }
        dropZone.onDrop = { [weak self] url in
            self?.model.setInput(url)
        }
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.heightAnchor.constraint(equalToConstant: 112).isActive = true
        return dropZone
    }

    private func makeModelSection() -> NSView {
        let label = sectionLabel("分离模型")
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 12
        cards.distribution = .fillEqually
        cards.translatesAutoresizingMaskIntoConstraints = false

        for demucs in DemucsModel.allCases {
            let card = ChoiceCardView(
                title: demucs.title,
                subtitle: demucs.subtitle,
                symbol: demucs.symbol
            )
            card.onSelect = { [weak self] in
                self?.model.selectModel(demucs)
            }
            card.heightAnchor.constraint(equalToConstant: 92).isActive = true
            cards.addArrangedSubview(card)
            modelCards.append((card, demucs))
        }

        let section = NSStackView(views: [label, cards])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        cards.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeModeSection() -> NSView {
        let label = sectionLabel("分离方式")
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 12
        cards.distribution = .fillEqually
        cards.translatesAutoresizingMaskIntoConstraints = false

        for mode in SeparationMode.allCases {
            let card = ChoiceCardView(
                title: mode.title,
                subtitle: mode.subtitle,
                symbol: mode.symbol
            )
            card.onSelect = { [weak self] in
                self?.model.mode = mode
            }
            card.heightAnchor.constraint(equalToConstant: 106).isActive = true
            cards.addArrangedSubview(card)
            modeCards.append((card, mode))
        }

        let section = NSStackView(views: [label, cards])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        cards.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeOutputSection() -> NSView {
        let folderIcon = NSImageView(image: symbolImage("folder"))
        folderIcon.contentTintColor = .secondaryLabelColor
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        outputPathLabel.font = .systemFont(ofSize: 13)
        outputPathLabel.lineBreakMode = .byTruncatingMiddle
        outputPathLabel.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let changeButton = linkButton("更改…", action: #selector(chooseOutputFolder))
        let openButton = linkButton("打开", action: #selector(openOutputRoot))

        let row = NSStackView(views: [
            folderIcon, outputPathLabel, spacer, changeButton, openButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        return paddedCard(row, fillColor: NSColor.controlBackgroundColor.withAlphaComponent(0.55))
    }

    private func makeActionSection() -> NSView {
        startButton.title = "开始分离"
        startButton.target = self
        startButton.action = #selector(startSeparation)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.image = symbolImage("play.fill")
        startButton.imagePosition = .imageLeading
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        startButton.heightAnchor.constraint(equalToConstant: 42).isActive = true

        cancelButton.title = "取消"
        cancelButton.target = self
        cancelButton.action = #selector(cancelSeparation)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let row = NSStackView(views: [startButton, cancelButton])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 8
        startButton.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        cancelButton.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    private func makeProgressCard() -> NSView {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let infoRow = NSStackView(views: [statusLabel, spacer, percentLabel, elapsedLabel])
        infoRow.orientation = .horizontal
        infoRow.alignment = .centerY
        infoRow.spacing = 10

        let stack = NSStackView(views: [progressBar, infoRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        infoRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        progressCard.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.07)
        padContent(stack, inside: progressCard)
        return progressCard
    }

    private func makeErrorCard() -> NSView {
        let icon = NSImageView(image: symbolImage("exclamationmark.triangle.fill"))
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let title = makeLabel("出了点问题", font: .systemFont(ofSize: 13, weight: .semibold))
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isSelectable = true
        errorLabel.maximumNumberOfLines = 4

        let textStack = NSStackView(views: [title, errorLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let closeButton = linkButton("关闭", action: #selector(closeError))
        let row = NSStackView(views: [icon, textStack, spacer, closeButton])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10

        errorCard.fillColor = NSColor.systemOrange.withAlphaComponent(0.08)
        padContent(row, inside: errorCard)
        return errorCard
    }

    private func makeResultsCard() -> NSView {
        let title = makeLabel("分离结果", font: .systemFont(ofSize: 13, weight: .semibold))
        title.textColor = .systemGreen
        let icon = NSImageView(image: symbolImage("checkmark.circle.fill"))
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let titleRow = NSStackView(views: [icon, title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let revealButton = linkButton("在访达中显示", action: #selector(revealResults))
        let header = NSStackView(views: [titleRow, spacer, revealButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        resultsListStack.orientation = .vertical
        resultsListStack.alignment = .leading
        resultsListStack.spacing = 6
        resultsListStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, resultsListStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        resultsListStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        resultsCard.fillColor = NSColor.systemGreen.withAlphaComponent(0.06)
        resultsCard.borderColor = NSColor.systemGreen.withAlphaComponent(0.20)
        padContent(stack, inside: resultsCard)
        return resultsCard
    }

    private func makeLogSection() -> NSView {
        logToggleButton.title = "运行日志"
        logToggleButton.target = self
        logToggleButton.action = #selector(toggleLog)
        logToggleButton.isBordered = false
        logToggleButton.image = symbolImage("chevron.right")
        logToggleButton.imagePosition = .imageLeading
        logToggleButton.contentTintColor = .secondaryLabelColor
        logToggleButton.font = .systemFont(ofSize: 12)
        logToggleButton.translatesAutoresizingMaskIntoConstraints = false

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = .secondaryLabelColor
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let logScroll = NSScrollView()
        logScroll.documentView = logTextView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.borderType = .noBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(equalToConstant: 128).isActive = true

        let card = CardView()
        card.cornerRadius = 8
        card.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.55)
        card.addSubview(logScroll)
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2),
            logScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2),
            logScroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            logScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
        ])

        logCard.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: logCard.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: logCard.trailingAnchor),
            card.topAnchor.constraint(equalTo: logCard.topAnchor),
            card.bottomAnchor.constraint(equalTo: logCard.bottomAnchor),
        ])

        let stack = NSStackView(views: [logToggleButton, logCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        logCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        logToggleButton.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeFooter() -> NSView {
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        modelStatusLabel.font = .systemFont(ofSize: 11)
        modelStatusLabel.textColor = .secondaryLabelColor
        modelStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        engineStatusLabel.font = .systemFont(ofSize: 11)
        engineStatusLabel.textColor = .secondaryLabelColor
        engineStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        toolStatusLabel.font = .systemFont(ofSize: 11)
        toolStatusLabel.textColor = .secondaryLabelColor
        toolStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [
            statusDot, modelStatusLabel, engineStatusLabel, spacer, toolStatusLabel,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: - 刷新界面

    private func refreshUI() {
        guard isViewLoaded else { return }

        dropZone.setFile(model.inputURL)
        dropZone.isEnabled = !model.isRunning

        for (card, mode) in modeCards {
            card.isSelected = (mode == model.mode)
            card.isEnabled = !model.isRunning
        }
        for (card, demucs) in modelCards {
            card.isSelected = (demucs == model.demucsModel)
            card.isEnabled = !model.isRunning
        }

        outputPathLabel.stringValue = model.outputRoot.path
        outputPathLabel.toolTip = model.outputRoot.path

        startButton.title = model.isRunning ? "正在分离…" : "开始分离"
        startButton.isEnabled = model.inputURL != nil && !model.isRunning && model.toolPath != nil
        cancelButton.isHidden = !model.isRunning

        let showsProgress = model.isRunning || model.progress != nil
        progressCard.isHidden = !showsProgress
        if showsProgress {
            statusLabel.stringValue = model.statusText
            if let progress = model.progress {
                if progressWasIndeterminate {
                    progressBar.stopAnimation(nil)
                    progressWasIndeterminate = false
                }
                progressBar.isIndeterminate = false
                progressBar.doubleValue = min(1, max(0, progress))
                percentLabel.stringValue = "\(Int((progress * 100).rounded()))%"
                percentLabel.isHidden = false
            } else {
                if !progressWasIndeterminate {
                    progressBar.isIndeterminate = true
                    progressBar.startAnimation(nil)
                    progressWasIndeterminate = true
                }
                percentLabel.isHidden = true
            }
        } else {
            if progressWasIndeterminate {
                progressBar.stopAnimation(nil)
                progressWasIndeterminate = false
            }
        }

        if let error = model.errorText {
            errorCard.isHidden = false
            errorLabel.stringValue = error
        } else {
            errorCard.isHidden = true
        }

        refreshResults()

        if model.resultFiles.isEmpty {
            didAutoScrollResults = false
        } else if !didAutoScrollResults {
            didAutoScrollResults = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resultsCard.scrollToVisible(self.resultsCard.bounds)
            }
        }

        if logTextView.string != model.logText {
            logTextView.string = model.logText
            logTextView.scrollToEndOfDocument(nil)
        }

        statusDot.layer?.backgroundColor = (
            model.modelReady ? NSColor.systemGreen : NSColor.systemOrange
        ).cgColor
        let selected = model.demucsModel
        modelStatusLabel.stringValue = model.modelReady
            ? "\(selected.displayName) 已就绪"
            : "\(selected.displayName) 未下载（约 \(selected.sizeText)），首次运行会自动下载"
        engineStatusLabel.stringValue = model.loadedModel.map { "内存中：\($0.title)" } ?? ""
        toolStatusLabel.stringValue = model.toolPath == nil ? "未找到 demucs-mlx" : "demucs-mlx 已就绪"
        toolStatusLabel.textColor = model.toolPath == nil ? .systemRed : .secondaryLabelColor

        updateElapsed()
    }

    private func refreshResults() {
        guard renderedResults != model.resultFiles else { return }
        renderedResults = model.resultFiles

        for subview in resultsListStack.arrangedSubviews {
            resultsListStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        resultsCard.isHidden = model.resultFiles.isEmpty
        for (index, url) in model.resultFiles.enumerated() {
            resultsListStack.addArrangedSubview(makeResultRow(url, index: index))
        }
    }

    private func makeResultRow(_ url: URL, index: Int) -> NSView {
        let icon = NSImageView(image: symbolImage("waveform.circle.fill"))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let name = makeLabel(displayName(for: url), font: .systemFont(ofSize: 13))
        let filename = makeLabel(
            url.lastPathComponent,
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let play = linkButton("播放", action: #selector(playResult(_:)))
        play.tag = index
        let show = linkButton("显示", action: #selector(showResult(_:)))
        show.tag = index

        let row = NSStackView(views: [icon, name, filename, spacer, play, show])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func updateElapsed() {
        if model.isRunning, let started = model.startedAt {
            let total = max(0, Int(Date().timeIntervalSince(started)))
            elapsedLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
            elapsedLabel.isHidden = false
        } else {
            elapsedLabel.stringValue = ""
            elapsedLabel.isHidden = true
        }
    }

    // MARK: - 动作

    @objc private func refreshEnvironment() {
        model.refreshEnvironment()
    }

    @objc private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择"
        panel.message = "选择要分离的音频文件"
        if panel.runModal() == .OK, let url = panel.url {
            model.setInput(url)
        }
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        panel.message = "选择输出位置"
        panel.directoryURL = model.outputRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.outputRoot = url
        }
    }

    @objc private func openOutputRoot() {
        NSWorkspace.shared.open(model.outputRoot)
    }

    @objc private func startSeparation() {
        model.start()
    }

    @objc private func cancelSeparation() {
        model.cancel()
    }

    @objc private func closeError() {
        model.errorText = nil
    }

    @objc private func revealResults() {
        model.revealResults()
    }

    @objc private func playResult(_ sender: NSButton) {
        guard model.resultFiles.indices.contains(sender.tag) else { return }
        model.open(model.resultFiles[sender.tag])
    }

    @objc private func showResult(_ sender: NSButton) {
        guard model.resultFiles.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([model.resultFiles[sender.tag]])
    }

    @objc private func toggleLog() {
        logExpanded.toggle()
        logCard.isHidden = !logExpanded
        logToggleButton.image = symbolImage(logExpanded ? "chevron.down" : "chevron.right")
    }

    @objc private func tick() {
        updateElapsed()
    }

    // MARK: - 小工具

    private func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        makeLabel(
            text,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .secondaryLabelColor
        )
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func paddedCard(
        _ content: NSView,
        fillColor: NSColor,
        borderColor: NSColor? = nil
    ) -> CardView {
        let card = CardView()
        card.fillColor = fillColor
        card.borderColor = borderColor
        padContent(content, inside: card)
        return card
    }

    private func padContent(_ content: NSView, inside card: CardView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    private func displayName(for url: URL) -> String {
        let labels = [
            "vocals": "人声",
            "drums": "鼓",
            "bass": "贝斯",
            "other": "其他乐器",
            "instrumental": "伴奏",
        ]
        let stem = url.deletingPathExtension().lastPathComponent
        return labels[stem] ?? stem
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }
}

// MARK: - 基础视图

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class BackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let start = NSColor.windowBackgroundColor
        // 注意：NSGradient 对带 alpha 的颜色会叠加得不自然，这里先混合成不透明色。
        let end = NSColor.controlAccentColor.blended(
            withFraction: 0.94,
            of: NSColor.windowBackgroundColor
        ) ?? NSColor.windowBackgroundColor
        NSGradient(starting: start, ending: end)?.draw(in: bounds, angle: -90)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private class CardView: NSView {
    var cornerRadius: CGFloat = 12
    var fillColor: NSColor = .clear
    var borderColor: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        if fillColor != .clear {
            fillColor.setFill()
            path.fill()
        }
        if let borderColor {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class IconBadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 48).isActive = true
        heightAnchor.constraint(equalToConstant: 48).isActive = true

        let imageView = NSImageView(image: symbolImage("waveform"))
        imageView.contentTintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13)
        NSGradient(colors: [NSColor.controlAccentColor, NSColor.systemPurple])?
            .draw(in: path, angle: -45)
    }
}

// MARK: - 拖放区

private final class DropZoneView: NSView {
    var onClick: (() -> Void)?
    var onDrop: ((URL) -> Void)?
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.55
            if !isEnabled { isTargeted = false }
        }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "把音频拖到这里")
    private let subtitleLabel = NSTextField(
        labelWithString: "或点击选择文件 · mp3 / wav / m4a / flac / aac / ogg"
    )
    private let checkmark = NSImageView(image: symbolImage("checkmark.circle.fill"))
    private var isTargeted = false {
        didSet {
            guard isTargeted != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildSubviews() {
        iconView.image = symbolImage("arrow.down.doc")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        checkmark.contentTintColor = .systemGreen
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.widthAnchor.constraint(equalToConstant: 20).isActive = true
        checkmark.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        addSubview(checkmark)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -12),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setFile(_ url: URL?) {
        if let url {
            iconView.image = symbolImage("music.note")
            iconView.contentTintColor = .controlAccentColor
            titleLabel.stringValue = url.lastPathComponent
            subtitleLabel.stringValue = "\(fileSizeText(url)) · 点击可更换文件"
            checkmark.isHidden = false
        } else {
            iconView.image = symbolImage("arrow.down.doc")
            iconView.contentTintColor = .secondaryLabelColor
            titleLabel.stringValue = "把音频拖到这里"
            subtitleLabel.stringValue = "或点击选择文件 · mp3 / wav / m4a / flac / aac / ogg"
            checkmark.isHidden = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        let fill = isTargeted
            ? NSColor.controlAccentColor.withAlphaComponent(0.10)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        fill.setFill()
        path.fill()

        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        (isTargeted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled else { return [] }
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        isTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard isEnabled else { return false }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first else {
            return false
        }
        onDrop?(url)
        return true
    }

    private func fileSizeText(_ url: URL) -> String {
        var bytes: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let number = attributes[.size] as? NSNumber {
            bytes = number.int64Value
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 选项卡片

private final class ChoiceCardView: NSView {
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            checkmark.isHidden = !isSelected
            iconView.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            needsDisplay = true
        }
    }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.5
            needsDisplay = true
        }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let checkmark = NSImageView(image: symbolImage("checkmark.circle.fill"))
    private let title: String
    private let subtitle: String
    private let symbol: String

    init(title: String, subtitle: String, symbol: String) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        super.init(frame: .zero)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildSubviews() {
        iconView.image = symbolImage(symbol)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        checkmark.contentTintColor = .controlAccentColor
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.widthAnchor.constraint(equalToConstant: 16).isActive = true
        checkmark.heightAnchor.constraint(equalToConstant: 16).isActive = true

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(checkmark)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkmark.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        let fill = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.labelColor.withAlphaComponent(0.035)
        fill.setFill()
        path.fill()

        (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isSelected ? 2 : 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 全局小工具

private func symbolImage(_ name: String) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 16, height: 16))
}

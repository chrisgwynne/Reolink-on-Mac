import SwiftUI
import AppKit

/// SwiftUI wrapper that hosts an ``RTSPPlayerEngine`` (VLCKit when linked) and
/// bridges its lifecycle callbacks to a ``CameraViewModel``.
///
/// For mock cameras (no real stream URL) it renders an animated synthesized
/// frame so the UI is fully usable without hardware.
struct RTSPPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(
            stream: viewModel.stream,
            isMock: viewModel.camera.isMock,
            isPaused: viewModel.isPaused
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Dismantling happens on the main thread; hop into the coordinator's
        // MainActor isolation explicitly to satisfy concurrency checking.
        MainActor.assumeIsolated { coordinator.teardown() }
    }

    @MainActor
    final class Coordinator {
        private let viewModel: CameraViewModel
        private var engine: RTSPPlayerEngine?
        /// Identity of the stream currently loaded into the engine. Keyed on the
        /// stream's UUID (not URL) so a Refresh with an identical URL still forces
        /// a replay.
        private var currentStreamID: UUID?
        /// Last pause value applied to the engine, so we only toggle on change.
        private var appliedPaused = false
        private weak var container: NSView?
        private var mockView: MockFrameView?

        init(viewModel: CameraViewModel) {
            self.viewModel = viewModel
        }

        func attach(to container: NSView) {
            self.container = container
        }

        func sync(stream: CameraStream?, isMock: Bool, isPaused: Bool) {
            guard let container else { return }

            if isMock {
                installMockViewIfNeeded(in: container)
                return
            }

            guard let stream else {
                // The view model cleared the stream (Stop): halt playback but
                // keep the engine so a later Start/Refresh can reuse it.
                if currentStreamID != nil {
                    engine?.stop()
                    currentStreamID = nil
                    appliedPaused = false
                }
                return
            }
            if stream.id != currentStreamID {
                currentStreamID = stream.id
                appliedPaused = false
                installEngineIfNeeded(in: container)
                engine?.play(url: stream.url)
            } else if isPaused != appliedPaused {
                // Same source, pause state toggled (recorded-clip pause/resume).
                appliedPaused = isPaused
                engine?.setPaused(isPaused)
            }
        }

        private func installEngineIfNeeded(in container: NSView) {
            guard engine == nil else { return }
            let engine = VLCPlayerWrapper()
            engine.onPlaying = { [weak self] in
                Task { @MainActor in self?.viewModel.playerDidStart() }
            }
            engine.onBuffering = { [weak self] in
                Task { @MainActor in self?.viewModel.playerIsBuffering() }
            }
            engine.onEnded = { [weak self] in
                Task { @MainActor in self?.viewModel.playerDidEnd() }
            }
            engine.onFailure = { [weak self] reason in
                Task { @MainActor in self?.viewModel.playerDidFail(reason) }
            }
            let view = engine.rendererView
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            self.engine = engine
        }

        private func installMockViewIfNeeded(in container: NSView) {
            guard mockView == nil else { return }
            let view = MockFrameView(label: viewModel.camera.name)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            mockView = view
            viewModel.playerDidStart()
        }

        func teardown() {
            engine?.teardown()
            engine = nil
            mockView?.stop()
            mockView = nil
            currentStreamID = nil
        }
    }
}

/// A lightweight animated placeholder used for mock cameras: a moving gradient
/// plus a live clock, so it visibly "plays".
final class MockFrameView: NSView {
    private let label: String
    private var timer: Timer?
    private let timeLayer = CATextLayer()

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        configureLayers()
        start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureLayers() {
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor

        let nameLayer = CATextLayer()
        nameLayer.string = label
        nameLayer.fontSize = 22
        nameLayer.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        nameLayer.alignmentMode = .center
        nameLayer.frame = CGRect(x: 0, y: 60, width: 400, height: 30)
        nameLayer.contentsScale = 2
        layer?.addSublayer(nameLayer)

        timeLayer.fontSize = 18
        timeLayer.foregroundColor = NSColor.systemGreen.cgColor
        timeLayer.alignmentMode = .center
        timeLayer.contentsScale = 2
        layer?.addSublayer(timeLayer)
    }

    override func layout() {
        super.layout()
        timeLayer.frame = CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
        if let sublayers = layer?.sublayers, sublayers.count > 0 {
            sublayers[0].frame = CGRect(x: 0, y: bounds.midY + 16, width: bounds.width, height: 30)
        }
    }

    func start() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.timeLayer.string = "● LIVE  " + formatter.string(from: Date())
        }
        timer?.fire()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

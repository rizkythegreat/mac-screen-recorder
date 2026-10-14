import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import SwiftUI

enum CaptureTarget: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

struct CaptureSource: Identifiable {
    let id: CaptureTarget
    let title: String
    let detail: String
    let filter: SCContentFilter
    let frame: CGRect // Global Quartz coordinates, top-left origin.
    var isWindow: Bool { if case .window = id { return true }; return false }
}

@MainActor
func captureSources(_ content: SCShareableContent) -> [CaptureSource] {
    let ownApplications = content.applications.filter { $0.processID == getpid() }
    let displays = content.displays.map { display in
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        return CaptureSource(id: .display(display.displayID), title: screen?.localizedName ?? "Display \(display.displayID)",
                             detail: "\(display.width) × \(display.height)",
                             filter: SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: []),
                             frame: display.frame)
    }
    let windows = content.windows.filter {
        $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 &&
        $0.owningApplication != nil && $0.owningApplication?.processID != getpid()
    }.sorted {
        ($0.owningApplication?.applicationName ?? "", $0.title ?? "") <
        ($1.owningApplication?.applicationName ?? "", $1.title ?? "")
    }.map { window in
        CaptureSource(id: .window(window.windowID), title: window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "Window"),
                      detail: window.owningApplication?.applicationName ?? "Window",
                      filter: SCContentFilter(desktopIndependentWindow: window), frame: window.frame)
    }
    return displays + windows
}

/// Both the preview and the recorder use the same crop, scale and shadow rules.
func captureConfiguration(for source: CaptureSource, preview: Bool) -> SCStreamConfiguration {
    let cfg = SCStreamConfiguration()
    let size = source.filter.contentRect.size
    let scale: CGFloat = preview ? min(1, 960 / max(size.width, 1)) : CGFloat(source.filter.pointPixelScale)
    cfg.width = max(2, Int(size.width * scale) / 2 * 2)
    cfg.height = max(2, Int(size.height * scale) / 2 * 2)
    cfg.showsCursor = false
    cfg.ignoreShadowsSingleWindow = true
    cfg.scalesToFit = true
    cfg.preservesAspectRatio = true
    cfg.shouldBeOpaque = true
    return cfg
}

/// The caller starts capture only after all three waits finish successfully.
@MainActor
func runCaptureCountdown(tick: (Int) -> Void,
                         wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) async throws {
    for value in (1...3).reversed() {
        try Task.checkCancellation()
        tick(value)
        try await wait()
    }
    try Task.checkCancellation()
}

@MainActor
final class CaptureSetupModel: ObservableObject {
    @Published var sources: [CaptureSource] = []
    @Published var selected: CaptureTarget?
    @Published var loading = false
    @Published var error: String?
    @Published var preview: NSImage?
    @Published var previewTarget: CaptureTarget?
    @Published var previewError: String?
    @Published var revision = 0
    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraID = ""
    @Published var microphones: [AVCaptureDevice] = []
    @Published var microphoneID = ""
    var source: CaptureSource? { sources.first { $0.id == selected } }

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false; revision += 1 }
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        if !cameras.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID ?? ""
        }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if !microphones.contains(where: { $0.uniqueID == microphoneID }) {
            microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID ?? ""
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled else { return }
            sources = captureSources(content)
            if !sources.contains(where: { $0.id == selected }) { selected = sources.first?.id }
            if sources.isEmpty { error = "No screens or windows are available. Open a window and refresh." }
        } catch {
            guard !Task.isCancelled else { return }
            sources = []; selected = nil; preview = nil
            self.error = "Couldn't load capture sources. Allow Studio in System Settings → Privacy & Security → Screen Recording, then try again. \(error.localizedDescription)"
        }
    }

    func refreshPreview() async {
        preview = nil
        previewTarget = nil
        previewError = nil
        guard let source else { return }
        while !Task.isCancelled {
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: source.filter,
                                                                       configuration: captureConfiguration(for: source, preview: true))
                guard !Task.isCancelled, selected == source.id else { return }
                preview = NSImage(cgImage: image, size: .zero)
                previewTarget = source.id
                previewError = nil
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                previewError = "Preview unavailable. The window may have closed. Refresh to choose another source."
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
}

/// Sample callbacks and mutable metering state are confined to the microphone queue.
private final class MicrophoneMeterSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let update: (Float) -> Void
    private var lastUpdate = 0.0
    init(update: @escaping (Float) -> Void) { self.update = update }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdate >= 1 / 20.0 else { return }
        lastUpdate = now
        update(connection.audioChannels.map(\.averagePowerLevel).max() ?? -60)
    }
}

@MainActor
final class MicrophoneCheck: ObservableObject {
    @Published private(set) var level = 0.0
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    private let queue = DispatchQueue(label: "studio.microphone-check")
    private var session: AVCaptureSession?
    private var sink: MicrophoneMeterSink?
    private var generation = UUID()

    func start(deviceID: String) async {
        stop()
        let token = generation
        error = nil
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard !Task.isCancelled, generation == token else { return }
        guard allowed else { error = "Microphone access is off. Enable it in System Settings, or record without a microphone."; return }
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected, device.hasMediaType(.audio) else {
            error = "This microphone is unavailable. Connect an input and refresh, or turn the microphone off."
            return
        }
        let session = AVCaptureSession()
        let sink = MicrophoneMeterSink { [weak self] db in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.level = min(max((Double(db) + 60) / 60, 0), 1)
            }
        }
        self.session = session; self.sink = sink
        let failure: String? = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        continuation.resume(returning: "This microphone could not be opened.")
                        return
                    }
                    session.addInput(input)
                    output.setSampleBufferDelegate(sink, queue: self.queue)
                    session.addOutput(output)
                    session.commitConfiguration()
                    session.startRunning()
                    continuation.resume(returning: session.isRunning ? nil : "The microphone did not start. Check its connection.")
                } catch { continuation.resume(returning: error.localizedDescription) }
            }
        }
        guard !Task.isCancelled, generation == token else { return }
        error = failure
        ready = failure == nil
    }

    func stop() {
        generation = UUID()
        ready = false; level = 0
        if let session { queue.async { session.stopRunning() } }
        session = nil; sink = nil
    }

    func stopAndWait() async {
        stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}

struct CaptureSetupView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CaptureSetupModel()
    @StateObject private var microphone = MicrophoneCheck()
    @StateObject private var webcam = WebcamCheck()
    @State private var windows = false
    @State private var countdown: Int?
    @State private var starting = false
    @State private var startTask: Task<Void, Never>?
    @State private var startToken = UUID()
    private var busy: Bool { countdown != nil || starting }
    private var microphoneIssue: String? {
        microphone.error ?? (!model.loading && model.microphones.isEmpty ? "No microphone found. Connect an input and refresh, or record without a microphone." : nil)
    }
    private var visibleSources: [CaptureSource] { model.sources.filter { $0.isWindow == windows } }
    private var previewKey: String { "\(String(describing: model.selected))-\(model.revision)-\(busy)" }
    private var microphoneKey: String { "\(model.microphoneID)-\(model.revision)-\(recorder.includeMic && !busy && !recorder.isRecording)" }

    private var cameraKey: String { "\(model.cameraID)-\(model.revision)-\(recorder.includeWebcam && !busy && !recorder.isRecording)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New recording").font(.system(size: 23, weight: .semibold))
                        Text("Choose what to capture. Take a moment to get ready.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(starting)
                }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Capture", selection: $windows) {
                            Text("Screens").tag(false)
                            Text("Windows").tag(true)
                        }.pickerStyle(.segmented)
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(visibleSources) { source in
                                    Button { model.selected = source.id } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: source.isWindow ? "macwindow" : "display").frame(width: 24)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(source.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                                Text(source.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                            if source.id == model.selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioTheme.accent) }
                                        }
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(source.id == model.selected ? StudioTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                                if visibleSources.isEmpty && !model.loading {
                                    Text(windows ? "No windows found. Open one and refresh." : "No displays found.")
                                        .font(.callout).foregroundStyle(.secondary).padding()
                                }
                            }
                        }.frame(height: 190)
                        Button { Task { await model.refresh() } } label: {
                            Label(model.loading ? "Refreshing…" : "Refresh sources", systemImage: "arrow.clockwise")
                        }.disabled(model.loading)
                    }.frame(width: 225).disabled(busy)
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.85))
                            if let preview = model.preview {
                                Image(nsImage: preview).resizable().scaledToFit().padding(8)
                            } else if model.loading || (model.selected != nil && model.previewError == nil) {
                                ProgressView().controlSize(.large)
                            } else {
                                ContentUnavailableView("No preview", systemImage: "display", description: Text(model.previewError ?? "Choose a source to preview it."))
                            }
                            if let countdown {
                                Color.black.opacity(0.55)
                                VStack(spacing: 6) {
                                    Text("\(countdown)").font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
                                    Text("Get ready").font(.headline)
                                }.foregroundStyle(.white)
                            } else if starting {
                                Color.black.opacity(0.55)
                                ProgressView("Starting recording…").tint(.white).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 445, height: 230).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(model.source?.title ?? "Capture preview").font(.callout.weight(.medium)).lineLimit(1)
                        Text("Studio stays out of your recording.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Screen Recording settings") { openPrivacy("Privacy_ScreenCapture") }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Toggle("Microphone", isOn: $recorder.includeMic).toggleStyle(.switch)
                        Spacer()
                        if recorder.includeMic {
                            Picker("Input", selection: $model.microphoneID) {
                                if model.microphones.isEmpty { Text("No microphone available").tag("") }
                                ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            }.frame(maxWidth: 350)
                        } else { Text("System audio only").font(.callout).foregroundStyle(.secondary) }
                    }.disabled(busy)
                    if recorder.includeMic {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform").foregroundStyle(.secondary)
                            GeometryReader { geo in
                                Capsule().fill(.quaternary)
                                Capsule().fill(microphone.level > 0.9 ? Color.orange : Color.green)
                                    .frame(width: max(0, geo.size.width * microphone.level))
                                    .animation(.easeOut(duration: 0.10), value: microphone.level)
                            }.frame(width: 180, height: 7)
                                .accessibilityLabel("Microphone input level").accessibilityValue("\(Int(microphone.level * 100)) percent")
                            Text(busy ? "Microphone ready for recording" : microphoneIssue != nil ? "Microphone unavailable" : microphone.ready ? "Speak to check your input" : "Checking microphone…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = microphoneIssue {
                            Text(error).font(.caption).foregroundStyle(.red)
                            HStack {
                                Button("Microphone settings") { openPrivacy("Privacy_Microphone") }
                                Button("Record without microphone") { recorder.includeMic = false }
                            }.disabled(busy)
                        }
                    }
                }
                Divider()
                webcamSetup
                if let error = recorder.error { Text(error).font(.caption).foregroundStyle(.red) }

            }
            .padding(28).frame(width: 748)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer.padding(22).background(.bar)
        }
        .frame(width: 748, height: 650)
        .background(StudioTheme.surface)
        .tint(StudioTheme.accent)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(busy)
        .task { recorder.error = nil; await model.refresh() }
        .task(id: previewKey) { if !busy { await model.refreshPreview() } }
        .task(id: microphoneKey) {
            if recorder.includeMic && !busy && !recorder.isRecording && !model.microphoneID.isEmpty { await microphone.start(deviceID: model.microphoneID) }
            else { microphone.stop() }
        }
        .task(id: cameraKey) {
            if recorder.includeWebcam && !busy && !recorder.isRecording && !model.cameraID.isEmpty {
                await webcam.start(model.cameraID)
            } else { await webcam.stop() }
        }
        .onChange(of: windows) { _, _ in model.selected = visibleSources.first?.id }
        .onChange(of: model.revision) { _, _ in
            if model.source?.isWindow != windows { model.selected = visibleSources.first?.id }
        }
        .onDisappear { startToken = UUID(); startTask?.cancel(); microphone.stop(); Task { await webcam.stop() } }
    }

    private var webcamSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Webcam", isOn: $recorder.includeWebcam).toggleStyle(.switch)
                Spacer()
                if recorder.includeWebcam {
                    Picker("Camera", selection: $model.cameraID) {
                        if model.cameras.isEmpty { Text("No camera available").tag("") }
                        ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }.frame(maxWidth: 350)
                }
            }.disabled(busy)
            if recorder.includeWebcam {
                HStack(spacing: 14) {
                    Group {
                        if let image = webcam.image {
                            Image(nsImage: image).resizable().scaledToFill().scaleEffect(x: -1, y: 1)
                        } else {
                            Rectangle().fill(.black.opacity(0.35)).overlay(Image(systemName: "video").foregroundStyle(.secondary))
                        }
                    }.frame(width: 128, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your camera stays editable").font(.callout.weight(.medium))
                        Text("Adjust its shape, size, position, and mirror in the editor.").font(.caption).foregroundStyle(.secondary)
                        if let error = webcam.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("Camera settings") { openPrivacy("Privacy_Camera") }
                        } else if model.cameras.isEmpty {
                            Text("No camera found. Connect a camera and refresh, or turn Webcam off.").font(.caption).foregroundStyle(.secondary)
                        } else if webcam.image == nil && !busy {
                            Text("Checking camera…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("3-second countdown", systemImage: "timer").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(action: start) {
                Label("Start recording", systemImage: "record.circle").padding(.horizontal, 8).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        !busy && !model.loading && model.source != nil && model.preview != nil &&
        model.previewTarget == model.selected && (!recorder.includeMic || microphone.ready) &&
        (!recorder.includeWebcam || (webcam.image != nil && webcam.error == nil))
    }

    private func start() {
        guard canStart, let source = model.source else { return }
        let microphoneID = recorder.includeMic ? model.microphoneID : nil
        let cameraID = recorder.includeWebcam ? model.cameraID : nil
        let token = UUID()
        startToken = token
        countdown = 3
        startTask = Task {
            await microphone.stopAndWait()
            await webcam.stop()
            do {
                try await runCaptureCountdown { value in countdown = value }
                guard startToken == token else { return }
                starting = true; countdown = nil
                await recorder.start(target: source.id, microphoneID: microphoneID, cameraID: cameraID)
                starting = false
                if recorder.isRecording { dismiss() }
            } catch {
                guard startToken == token else { return }
                countdown = nil; starting = false
            }
        }
    }

    private func cancel() {
        startToken = UUID()
        startTask?.cancel()
        if countdown != nil { countdown = nil } else { dismiss() }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

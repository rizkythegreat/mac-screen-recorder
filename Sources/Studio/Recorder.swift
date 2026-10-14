import AppKit
import AVFoundation
import ScreenCaptureKit

struct StudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Library {
    static let root = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Studio", isDirectory: true)

    static func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func newFolder() throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = root.appendingPathComponent("Recording \(f.string(from: Date()))", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent(url.lastPathComponent + " " + UUID().uuidString.prefix(6), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        return url
    }
}

func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(value).write(to: url, options: .atomic)
}

/// Same clock ScreenCaptureKit stamps frames with, so input and video line up.
func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

/// Low-rate mono microphones (for example Bluetooth headsets) cannot encode at stereo bitrates.
func audioBitRate(sampleRate: Double, channels: Int) -> Int {
    let perChannel = sampleRate >= 32_000 ? 64_000 : sampleRate >= 16_000 ? 32_000 : 16_000
    return perChannel * min(max(channels, 1), 2)
}

/// Pauses on the host clock. Maps capture time to recording time with the paused spans cut out,
/// so every track (and the cursor log) stays in sync without restarting the writers.
final class PauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var gaps: [(start: Double, end: Double)] = []  // end = .infinity while paused

    var isPaused: Bool { lock.withLock { gaps.last?.end == .infinity } }
    func pause(at t: Double) { lock.withLock { if gaps.last?.end != .infinity { gaps.append((t, .infinity)) } } }
    func resume(at t: Double) { lock.withLock { if gaps.last?.end == .infinity { gaps[gaps.count - 1].end = max(t, gaps[gaps.count - 1].start) } } }

    /// Recording time for capture time `t`; `paused` is true inside a pause (time clamps to the pause start).
    func map(_ t: Double) -> (t: Double, paused: Bool) {
        lock.withLock {
            var cut = 0.0
            for g in gaps {
                if t >= g.end { cut += g.end - g.start } else if t >= g.start { return (g.start - cut, true) } else { break }
            }
            return (t - cut, false)
        }
    }
}

private func shifted(_ sb: CMSampleBuffer, by delta: CMTime) -> CMSampleBuffer? {
    guard var timing = try? sb.sampleTimingInfos() else { return nil }
    for i in timing.indices {
        timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - delta
        if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - delta }
    }
    return try? CMSampleBuffer(copying: sb, withNewTiming: timing)
}

/// One file per stream, created on its first buffer so the encoder settings follow the source format.
final class TrackWriter {
    let url: URL
    let isVideo: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var start: CMTime?
    private(set) var failure: String?
    var clock: PauseClock?

    init(url: URL, isVideo: Bool) { self.url = url; self.isVideo = isVideo }

    func append(_ original: CMSampleBuffer) {
        guard failure == nil else { return }
        var sb = original
        if let clock {
            let pts = original.presentationTimeStamp
            let mapped = clock.map(pts.seconds)
            if mapped.paused { return }  // ponytail: capture keeps running while paused; stop the stream if battery matters
            let delta = pts - CMTime(seconds: mapped.t, preferredTimescale: pts.timescale)
            if delta > .zero { guard let moved = shifted(original, by: delta) else { return }; sb = moved }
        }
        if writer == nil { setUp(sb) }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if !input.append(sb) { failure = writer.error?.localizedDescription ?? "Could not append media." }
    }

    private func setUp(_ sb: CMSampleBuffer) {
        guard let fmt = sb.formatDescription else { return }
        let settings: [String: Any]
        if isVideo {
            let d = CMVideoFormatDescriptionGetDimensions(fmt)
            settings = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: d.width, AVVideoHeightKey: d.height]
        } else {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate,
                        AVNumberOfChannelsKey: min(Int(asbd.mChannelsPerFrame), 2),
                        AVEncoderBitRateKey: audioBitRate(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))]
        }
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: isVideo ? .mov : .m4a)
            // Fragmented movie: a crashed or killed recording still plays up to the last 2s.
            if isVideo { w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600) }
            let i = AVAssetWriterInput(mediaType: isVideo ? .video : .audio, outputSettings: settings, sourceFormatHint: fmt)
            i.expectsMediaDataInRealTime = true
            w.add(i)
            guard w.startWriting() else {
                failure = w.error?.localizedDescription ?? "Cannot start media writer."
                NSLog("Studio: cannot write \(url.lastPathComponent): \(failure!)")
                return
            }
            w.startSession(atSourceTime: sb.presentationTimeStamp)
            (writer, input, start) = (w, i, sb.presentationTimeStamp)
        } catch {
            failure = error.localizedDescription
            NSLog("Studio: writer setup failed: \(error)")
        }
    }

    /// Ends at `end` (not the last frame), so a still screen before stopping is kept.
    func finish(at rawEnd: CMTime, done: @escaping () -> Void) {
        guard let writer, let input, let start, writer.status == .writing else { done(); return }
        let end = clock.map { CMTime(seconds: $0.map(rawEnd.seconds).t, preferredTimescale: 600) } ?? rawEnd
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(end, start))
        writer.finishWriting {
            if writer.status == .failed { self.failure = writer.error?.localizedDescription ?? "Cannot finish media writer." }
            done()
        }
    }
}

/// Receives ScreenCaptureKit buffers; touched only on `queue`.
final class CaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "studio.capture")
    let video, system, mic: TrackWriter

    init(folder: URL, clock: PauseClock) {
        video = TrackWriter(url: folder.appendingPathComponent("screen.mov"), isVideo: true)
        system = TrackWriter(url: folder.appendingPathComponent("system.m4a"), isVideo: false)
        mic = TrackWriter(url: folder.appendingPathComponent("mic.m4a"), isVideo: false)
        for w in [video, system, mic] { w.clock = clock }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit also sends idle/blank status buffers; only complete frames carry pixels.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            video.append(sb)
        case .audio: system.append(sb)
        case .microphone: mic.append(sb)
        @unknown default: break
        }
    }

    func finish(at end: CMTime) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                let g = DispatchGroup()
                for w in [self.video, self.system, self.mic] { g.enter(); w.finish(at: end) { g.leave() } }
                g.notify(queue: .main) { c.resume() }
            }
        }
    }
}

/// ScreenCaptureKit fits resized windows at the top-left of its fixed output buffer.
func capturePointer(_ point: CGPoint, frame: CGRect, canvas: CGSize) -> (x: Double, y: Double, visible: Bool) {
    guard frame.width > 0, frame.height > 0, canvas.width > 0, canvas.height > 0 else { return (0.5, 0.5, false) }
    let scale = min(canvas.width / frame.width, canvas.height / frame.height)
    let x = (point.x - frame.minX) * scale / canvas.width
    let y = (point.y - frame.minY) * scale / canvas.height
    return (x, y, frame.contains(point))
}

/// Cursor position/shape at 60 Hz plus mouse-down events. Main thread only.
final class InputTracker {
    private let frameProvider: () -> CGRect?
    private let canvasSize: CGSize
    private let cursorDir: URL
    private(set) var moves: [MoveSample] = []
    private(set) var clicks: [Click] = []
    private(set) var cursors: [String: CursorInfo] = [:]
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastCursor = ""

    init(canvasSize: CGSize, frameProvider: @escaping () -> CGRect?, cursorDir: URL) {
        self.canvasSize = canvasSize
        self.frameProvider = frameProvider
        self.cursorDir = cursorDir
    }

    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Mouse-button monitors need no extra permission (key events would need Accessibility).
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.click() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.click(); return e }) { monitors.append(m) }
    }

    func stop() {
        timer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func position() -> (x: Double, y: Double, visible: Bool) {
        guard let frame = frameProvider(), let point = CGEvent(source: nil)?.location else {
            return (moves.last?.x ?? 0.5, moves.last?.y ?? 0.5, false)
        }
        return capturePointer(point, frame: frame, canvas: canvasSize)
    }

    private func sample() {
        let p = position()
        let c = cursorID()
        if let l = moves.last, l.x == p.x, l.y == p.y, l.cursor == c, l.visible == p.visible { return }
        moves.append(MoveSample(t: hostNow().seconds, x: p.x, y: p.y, cursor: c, visible: p.visible))
    }

    private func click() {
        let p = position()
        guard p.visible else { return }
        clicks.append(Click(t: hostNow().seconds, x: p.x, y: p.y))
    }

    // ponytail: hashes the cursor's TIFF 60x/s; cache by image identity if it ever shows in a profile.
    private func cursorID() -> String {
        guard let c = NSCursor.currentSystem, let tiff = c.image.tiffRepresentation else { return lastCursor }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a over all bytes (Data.hashValue only samples a prefix)
        for b in tiff { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        let id = String(h, radix: 36)
        if cursors[id] == nil {
            let best = NSBitmapImageRep.imageReps(with: tiff).compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
            if let png = best?.representation(using: .png, properties: [:]),
               (try? png.write(to: cursorDir.appendingPathComponent("\(id).png"))) != nil {
                cursors[id] = CursorInfo(hotX: c.hotSpot.x, hotY: c.hotSpot.y, width: c.image.size.width, height: c.image.size.height)
            }
        }
        lastCursor = id
        return id
    }
}

private final class CaptureLifecycle: NSObject, SCStreamDelegate {
    let interrupted: (Error) -> Void
    init(interrupted: @escaping (Error) -> Void) { self.interrupted = interrupted }
    func stream(_ stream: SCStream, didStopWithError error: Error) { interrupted(error) }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var error: String?
    @Published var includeMic = true
    @Published var includeWebcam = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var sourceName = ""
    @Published private(set) var isPaused = false
    var isBusy: Bool { isStarting || isStopping }

    private var clock = PauseClock()
    private var startedAt = 0.0
    private var lastStart: (target: CaptureTarget, microphoneID: String?, cameraID: String?)?

    /// Seconds recorded so far, pauses excluded.
    func elapsed(at now: Double = hostNow().seconds) -> Double { max(0, clock.map(now).t - startedAt) }

    func pause() {
        guard isRecording, !isPaused else { return }
        clock.pause(at: hostNow().seconds)
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        clock.resume(at: hostNow().seconds)
        isPaused = false
    }

    /// Discards the current take and deletes its folder.
    func cancel() async {
        guard let folder, await teardown() != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Discards the current take and starts again with the same source and devices.
    func restart() async {
        guard let again = lastStart else { return }
        await cancel()
        await start(target: again.target, microphoneID: again.microphoneID, cameraID: again.cameraID)
    }

    private var webcam: WebcamCapture?
    private var stream: SCStream?
    private var lifecycle: CaptureLifecycle?
    private var sink: CaptureSink?
    private var tracker: InputTracker?
    private var folder: URL?
    private var displaySize = CGSize.zero

    /// Re-resolve the selected source after countdown; never silently switch to another source.
    func start(target: CaptureTarget, microphoneID: String?, cameraID: String? = nil) async {
        guard !isRecording, !isBusy else { return }
        isStarting = true
        defer { isStarting = false }
        error = nil
        var pendingStream: SCStream?
        var pendingSink: CaptureSink?
        var pendingWebcam: WebcamCapture?
        do {
            if let microphoneID {
                guard await AVCaptureDevice.requestAccess(for: .audio),
                      let device = AVCaptureDevice(uniqueID: microphoneID), device.isConnected else {
                    throw StudioError("The selected microphone is unavailable. Check its connection and permission, or turn it off.")
                }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let source = captureSources(content).first(where: { $0.id == target }) else {
                throw StudioError("The selected screen or window is no longer available. Refresh and choose a source again.")
            }
            let cfg = captureConfiguration(for: source, preview: false)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 8
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.captureMicrophone = microphoneID != nil
            cfg.microphoneCaptureDeviceID = microphoneID

            let folder = try Library.newFolder()
            let clock = PauseClock()
            if let cameraID {
                let camera = WebcamCapture(url: folder.appendingPathComponent("webcam.mov"), clock: clock, failure: { [weak self] message in
                    Task { @MainActor in self?.error = "Webcam stopped: \(message) Screen recording continues." }
                })
                pendingWebcam = camera
                try await camera.start(deviceID: cameraID)
                try Task.checkCancellation()
            }
            let sink = CaptureSink(folder: folder, clock: clock)
            let lifecycle = CaptureLifecycle { [weak self] failure in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.error = "Recording stopped: \(failure.localizedDescription)"
                    _ = await self.stop()
                }
            }
            let stream = SCStream(filter: source.filter, configuration: cfg, delegate: lifecycle)
            pendingStream = stream; pendingSink = sink
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            if microphoneID != nil { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
            let size = source.filter.contentRect.size
            let tracker = InputTracker(canvasSize: size, frameProvider: {
                switch target {
                case .display(let id):
                    return CGDisplayIsActive(id) != 0 ? CGDisplayBounds(id) : nil
                case .window(let id):
                    guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                          let info = windows.first,
                          let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
                    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
                }
            }, cursorDir: folder.appendingPathComponent("cursors"))

            try await stream.startCapture()
            try Task.checkCancellation()
            tracker.start()
            (self.stream, self.sink, self.tracker, self.folder) = (stream, sink, tracker, folder)
            self.webcam = pendingWebcam
            self.lifecycle = lifecycle
            displaySize = size
            sourceName = source.title
            self.clock = clock
            startedAt = hostNow().seconds
            lastStart = (target, microphoneID, cameraID)
            isPaused = false
            isRecording = true
        } catch {
            if let pendingStream { try? await pendingStream.stopCapture() }
            if let pendingSink { await pendingSink.finish(at: hostNow()) }
            if let pendingWebcam { _ = await pendingWebcam.stop() }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    /// Stops capture and closes every file; shared by stop and cancel.
    private func teardown() async -> (end: CMTime, sink: CaptureSink, tracker: InputTracker, camera: (start: Double?, failure: String?)?)? {
        guard !isStopping, let stream, let sink, let tracker, folder != nil else { return nil }
        isStopping = true
        defer { isStopping = false }
        isRecording = false
        isPaused = false
        tracker.stop()
        let end = hostNow()
        try? await stream.stopCapture()
        let cameraResult = await webcam?.stop(at: end)
        webcam = nil
        await sink.finish(at: end)
        (self.stream, self.sink, self.tracker, self.folder) = (nil, nil, nil, nil)
        lifecycle = nil
        return (end, sink, tracker, cameraResult)
    }

    /// Stops, writes recording.json + project.json (with automatic zooms), returns the folder.
    func stop() async -> URL? {
        guard !isStopping, let folder, let (rawEnd, sink, tracker, cameraResult) = await teardown() else { return nil }
        isStopping = true
        defer { isStopping = false }
        // Recording time: pauses removed (and a stop while paused ends at the pause).
        let clock = self.clock
        func recTime(_ t: Double) -> Double? { let m = clock.map(t); return m.paused ? nil : m.t }
        let end = CMTime(seconds: clock.map(rawEnd.seconds).t, preferredTimescale: 600)

        do {
            if let failure = sink.video.failure { throw StudioError("Video could not be saved: \(failure)") }
            guard let v0 = sink.video.start?.seconds else { throw StudioError("No video frames were captured.") }
            let rec = Recording(
                duration: end.seconds - v0,
                displayWidth: displaySize.width, displayHeight: displaySize.height,
                systemAudioOffset: sink.system.failure == nil ? sink.system.start.map { $0.seconds - v0 } : nil,
                webcamOffset: cameraResult?.failure == nil ? cameraResult?.start.map { $0 - v0 } : nil,
                micOffset: sink.mic.failure == nil ? sink.mic.start.map { $0.seconds - v0 } : nil,
                moves: tracker.moves.compactMap { m in recTime(m.t).map { var m = m; m.t = max($0 - v0, 0); return m } },
                clicks: tracker.clicks.compactMap { c in recTime(c.t).map { var c = c; c.t = $0 - v0; return c } }.filter { $0.t >= 0 },
                cursors: tracker.cursors)
            try writeJSON(rec, folder.appendingPathComponent("recording.json"))
            try writeJSON(Project(recording: rec), folder.appendingPathComponent("project.json"))
            if let failure = sink.mic.failure ?? sink.system.failure {
                throw StudioError("The video was saved to your library, but an audio track failed: \(failure)")
            }
            if let cameraResult, cameraResult.failure != nil || cameraResult.start == nil {
                self.error = "The screen recording was saved, but the webcam could not be saved: \(cameraResult.failure ?? "No camera frames received.")"
            }
            return folder
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

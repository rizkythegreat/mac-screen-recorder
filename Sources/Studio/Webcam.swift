import AppKit
@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

struct WebcamSettings: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable { case circle, rounded, square }
    var enabled = true
    var shape = Shape.circle
    var size = 0.25 // fraction of the canvas short edge
    var x = 0.96   // fraction of available travel, left to right
    var y = 0.96   // top to bottom
    var mirrored = true

    func rect(in canvas: CGSize) -> CGRect {
        let side = min(canvas.width, canvas.height) * min(max(size, 0.12), 0.5)
        let margin = min(canvas.width, canvas.height) * 0.025
        return CGRect(x: margin + max(0, canvas.width - side - 2 * margin) * min(max(x, 0), 1),
                      y: margin + max(0, canvas.height - side - 2 * margin) * (1 - min(max(y, 0), 1)),
                      width: side, height: side)
    }
}

func overlayWebcam(_ camera: CIImage, on image: CIImage, settings: WebcamSettings, size: CGSize) -> CIImage {
    guard settings.enabled else { return image }
    let rect = settings.rect(in: size)
    var frame = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
    if settings.mirrored {
        frame = frame.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: frame.extent.width, ty: 0))
    }
    let scale = max(rect.width / frame.extent.width, rect.height / frame.extent.height)
    frame = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    frame = frame.transformed(by: CGAffineTransform(translationX: rect.midX - frame.extent.midX, y: rect.midY - frame.extent.midY))
    let mask = CIFilter.roundedRectangleGenerator()
    mask.extent = rect
    mask.radius = Float(settings.shape == .circle ? rect.width / 2 : settings.shape == .rounded ? rect.width * 0.16 : 0)
    mask.color = .white
    let silhouette = mask.outputImage!.cropped(to: rect)
    let cutout = frame.cropped(to: rect).applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: silhouette])
    let shadow = silhouette.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
        .applyingGaussianBlur(sigma: rect.width * 0.035)
        .transformed(by: CGAffineTransform(translationX: 0, y: -rect.width * 0.025))
    return cutout.composited(over: shadow.composited(over: image)).cropped(to: CGRect(origin: .zero, size: size))
}

/// Session, writer and sample callbacks are confined to one serial queue.
final class WebcamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.webcam")
    private let session = AVCaptureSession()
    private let writer: TrackWriter?
    private let preview: ((CGImage) -> Void)?
    private let context = CIContext()
    private var lastPreview = 0.0
    private var accepting = false
    private var observers: [NSObjectProtocol] = []
    private var captureFailure: String?
    private let failure: ((String) -> Void)?
    init(url: URL? = nil, clock: PauseClock? = nil, preview: ((CGImage) -> Void)? = nil, failure: ((String) -> Void)? = nil) {
        writer = url.map { TrackWriter(url: $0, isVideo: true) }
        writer?.clock = clock
        self.preview = preview
        self.failure = failure
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The camera was interrupted. Check its connection."
                guard let self else { return }
                self.queue.async {
                    guard self.accepting else { return }
                    self.captureFailure = message
                    self.accepting = false
                    self.failure?(message)
                }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(deviceID: String) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw StudioError("Camera access is off. Enable Studio in System Settings → Privacy & Security → Camera, or turn Webcam off.")
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected, device.hasMediaType(.video) else {
                        throw StudioError("The selected camera is unavailable. Connect it and refresh, or turn Webcam off.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.session.beginConfiguration()
                    if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        throw StudioError("The camera could not be opened.")
                    }
                    self.session.addInput(input); self.session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                    self.session.commitConfiguration()
                    self.accepting = true
                    self.session.startRunning()
                    guard self.session.isRunning else { throw StudioError("The camera did not start. It may be in use by another app.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, sb.isValid, let buffer = sb.imageBuffer else { return }
        if let writer, let clock = session.synchronizationClock {
            var timing = CMSampleTimingInfo(duration: sb.duration,
                presentationTimeStamp: CMSyncConvertTime(sb.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid)
            var synced: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &synced) == noErr, let synced {
                writer.append(synced)
            }
        }
        if let preview, ProcessInfo.processInfo.systemUptime - lastPreview > 0.1 {
            lastPreview = ProcessInfo.processInfo.systemUptime
            let image = CIImage(cvPixelBuffer: buffer)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: 320 / image.extent.width, y: 320 / image.extent.width))
            if let cg = context.createCGImage(scaled, from: scaled.extent) { preview(cg) }
        }
    }

    func stop(at end: CMTime = hostNow()) async -> (start: Double?, failure: String?) {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.session.stopRunning()
                guard let writer = self.writer else { continuation.resume(returning: (nil, nil)); return }
                writer.finish(at: end) {
                    continuation.resume(returning: (writer.start?.seconds, writer.failure ?? self.captureFailure))
                }
            }
        }
    }
}

@MainActor final class WebcamCheck: ObservableObject {
    @Published var image: NSImage?
    @Published var error: String?
    private var capture: WebcamCapture?
    private var token = UUID()
    private var stopping: Task<Void, Never>?
    func start(_ id: String) async {
        await stop()
        guard !Task.isCancelled else { return }
        let generation = token
        error = nil
        let capture = WebcamCapture(preview: { [weak self] cg in
            Task { @MainActor in
                guard let self, self.token == generation else { return }
                self.image = NSImage(cgImage: cg, size: .zero)
            }
        }, failure: { [weak self] message in
            Task { @MainActor in
                guard let self, self.token == generation else { return }
                self.error = message; self.image = nil
            }
        })
        self.capture = capture
        do {
            try await capture.start(deviceID: id)
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            if token == generation && image == nil { error = "The camera is not sending video. Reconnect it or turn Webcam off." }
        } catch {
            if token == generation && !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func stop() async {
        token = UUID(); image = nil
        if let old = capture {
            capture = nil
            let previous = stopping
            stopping = Task { await previous?.value; _ = await old.stop() }
        }
        await stopping?.value
    }
}

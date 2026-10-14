import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Everything a frame needs. Immutable, so the compositor can read it from any thread.
final class RenderState: @unchecked Sendable {
    let recording: Recording
    let project: Project
    let timeline: Timeline
    let cursors: [String: CIImage]
    let background: CIImage?
    let customCursor: CIImage?

    init(folder: URL, recording: Recording, project: Project) {
        self.recording = recording
        self.project = project
        timeline = simulate(recording, zooms: project.zooms)
        background = project.style.backgroundImage.flatMap { loadBackground(folder.appendingPathComponent($0)) }
        var c: [String: CIImage] = [:]
        for id in recording.cursors.keys {
            c[id] = CIImage(contentsOf: folder.appendingPathComponent("cursors/\(id).png"))
        }
        cursors = c
        customCursor = project.style.cursorLook.flatMap { cursorImage($0) }.map { CIImage(cgImage: $0) }
    }
}

/// Image layout for drawn cursors: tip at (cursorPad, cursorPad) from the top-left, arrow 22 pt tall.
let cursorPad = 0.12, cursorPoints = 22.0

/// Draws a cursor look at `height` px (arrow body), tip inset by `cursorPad * height`.
func cursorImage(_ look: CursorLook, height: Double = 128) -> CGImage? {
    let pad = cursorPad * height, w = Int(0.8 * height + 2 * pad), h = Int(height + 2 * pad)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: pad, y: Double(h) - pad)
    ctx.scaleBy(x: height, y: -height)  // unit space, y down, tip at origin
    let points: [(Double, Double)]
    switch look.shape {
    case .rounded:
        points = [(0, 0), (0.04, 0.84), (0.28, 0.62), (0.64, 0.6)]
    case .slim:
        points = [(0, 0), (0.12, 0.87), (0.29, 0.64), (0.48, 0.98), (0.58, 0.92), (0.39, 0.59), (0.68, 0.57)]
    case .pixel:
        points = [(0, 0), (0, 0.88), (0.08, 0.88), (0.08, 0.8), (0.16, 0.8), (0.16, 0.72),
                  (0.24, 0.72), (0.24, 0.8), (0.32, 0.8), (0.32, 0.96), (0.48, 0.96),
                  (0.48, 0.88), (0.4, 0.88), (0.4, 0.72), (0.32, 0.72), (0.32, 0.64),
                  (0.64, 0.64), (0.64, 0.56), (0.56, 0.56), (0.56, 0.48), (0.48, 0.48),
                  (0.48, 0.4), (0.4, 0.4), (0.4, 0.32), (0.32, 0.32), (0.32, 0.24),
                  (0.24, 0.24), (0.24, 0.16), (0.16, 0.16), (0.16, 0.08), (0.08, 0.08), (0.08, 0)]
    default:
        points = [(0, 0), (0, 0.86), (0.21, 0.67), (0.35, 0.99), (0.5, 0.93), (0.37, 0.62), (0.63, 0.62)]
    }
    let path = CGMutablePath()
    path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
    path.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -0.03), blur: 0.06 * height,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.setLineJoin(look.shape == .pixel ? .miter : .round)
    ctx.setLineWidth(look.shape == .rounded ? 0.14 : 0.07)  // rounded: thick round joins soften the corners
    ctx.setStrokeColor(cgColor(look.outline)); ctx.addPath(path); ctx.strokePath()
    ctx.setShadow(offset: .zero, blur: 0)
    if look.shape == .rounded {  // same-color stroke rounds the fill's corners too
        ctx.setLineWidth(0.07); ctx.setStrokeColor(cgColor(look.fill)); ctx.addPath(path); ctx.strokePath()
    }
    if look.shape == .outline {
        // Two contrasting strokes keep the hollow pointer readable on light and dark content.
        ctx.setLineWidth(0.035); ctx.setStrokeColor(cgColor(look.fill))
        ctx.addPath(path); ctx.strokePath()
    } else if look.shape == .gradient {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let base = cgColor(look.fill)
        let highlight = NSColor(cgColor: base)!.blended(withFraction: 0.65, of: .white)!.cgColor
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [highlight, base] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0.45, y: 0.95),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    } else {
        ctx.setFillColor(cgColor(look.fill)); ctx.addPath(path); ctx.fillPath()
    }
    return ctx.makeImage()
}

/// Custom look (fixed size, tip at the pad) or the recorded image with its hotspot.
private func cursorSprite(_ id: String, _ state: RenderState) -> (CIImage, CursorInfo)? {
    if let custom = state.customCursor {
        let e = custom.extent, pts = cursorPoints / (e.height / (1 + 2 * cursorPad))  // points per pixel
        let pad = cursorPad * cursorPoints
        return (custom, CursorInfo(hotX: pad, hotY: pad, width: e.width * pts, height: e.height * pts))
    }
    guard let img = state.cursors[id], let info = state.recording.cursors[id], info.width > 0 else { return nil }
    return (img, info)
}

private func cgColor(_ hex: String) -> CGColor {
    let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return CGColor(srgbRed: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
}

/// Decodes once and caps at 4K: wallpapers are often 6K HEIC, far too slow to decode every frame.
private func loadBackground(_ url: URL) -> CIImage? {
    guard let image = CIImage(contentsOf: url), image.extent.width > 0, image.extent.height > 0 else { return nil }
    let scale = min(1, max(3840 / image.extent.width, 2160 / image.extent.height))  // still covers a 4K canvas
    let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cg = CIContext().createCGImage(small, from: small.extent.integral) else { return nil }
    return CIImage(cgImage: cg)
}

final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let state: RenderState
    let webcamTrackID: CMPersistentTrackID?
    let webcamTransform: CGAffineTransform

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, state: RenderState, webcamTrackID: CMPersistentTrackID? = nil, webcamTransform: CGAffineTransform = .identity) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.state = state
        self.webcamTrackID = webcamTrackID
        self.webcamTransform = webcamTransform
        requiredSourceTrackIDs = ([trackID] + (webcamTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Custom compositor used by both preview (AVPlayer) and export, so they always match.
final class Compositor: NSObject, AVVideoCompositing {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let attributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.attributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.attributes }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? FrameInstruction,
              let src = request.sourceFrame(byTrackID: ins.trackID),
              let out = request.renderContext.newPixelBuffer()
        else { request.finish(with: StudioError("Missing source frame.")); return }
        let size = request.renderContext.size
        var image = composeFrame(CIImage(cvPixelBuffer: src), outputTime: request.compositionTime.seconds, size: size, state: ins.state)
        if let id = ins.webcamTrackID, let buffer = request.sourceFrame(byTrackID: id) {
            image = overlayWebcam(CIImage(cvPixelBuffer: buffer).transformed(by: ins.webcamTransform), on: image,
                                  settings: ins.state.project.webcam ?? WebcamSettings(), size: size)
        }
        Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: out)
    }
}

func ciColor(hex: String) -> CIColor {
    let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
    return CIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255)
}

/// Background, padded and rounded screen with zoom, re-drawn cursor and click ripple.
func composeFrame(_ src: CIImage, outputTime: Double, size: CGSize, state: RenderState) -> CIImage {
    let r = state.recording, st = state.project.style
    let t = sourceTime(atOutput: outputTime, state.project.segments)
    let cam = state.timeline.camera(at: t)
    let canvas = CGRect(origin: .zero, size: size)
    let k = min(size.width, size.height) / 1080 // Consistent styling across canvas formats.

    let sw = src.extent.width, sh = src.extent.height
    let layout = contentGeometry(source: src.extent.size, canvas: size, padding: st.padding,
                                 placement: state.project.resolvedCanvas.placement)
    let content = layout.visible
    let imageRect = layout.image

    // Visible source window (normalized, top-left origin) and its mapping into the canvas (bottom-left origin).
    let s = cam.scale, vx = cam.x - 0.5 / s, vy = cam.y - 0.5 / s
    func toCanvas(_ u: Double, _ v: Double) -> CGPoint {
        CGPoint(x: imageRect.minX + (u - vx) * s * imageRect.width, y: imageRect.maxY - (v - vy) * s * imageRect.height)
    }
    let origin = toCanvas(0, 1)
    var screen = src.transformed(by: CGAffineTransform(scaleX: s * imageRect.width / sw, y: s * imageRect.height / sh)
        .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)))

    // Effects run in playback time, so speeding up a clip does not turn a click into a flash.
    let effect = st.resolvedClickEffect
    var press = 0.0
    var segmentStart = 0.0
    for segment in state.project.segments {
        let end = segmentStart + (segment.end - segment.start) / segment.speed
        if outputTime < end {
            if effect != .off {
                for c in r.clicks where c.t >= segment.start && c.t < segment.end {
                    let age = outputTime - (segmentStart + (c.t - segment.start) / segment.speed)
                    let pulse = clickPulse(age: age)
                    guard pulse.opacity > 0 else { continue }
                    if effect == .glow || effect == .press { press = max(press, pulse.press) }
                    if effect == .press { continue }
                    // Anchor the glow to the displayed tip at the moment of the click.
                    let pos = st.smoothCursor ? state.timeline.cursor(at: c.t) : (x: c.x, y: c.y)
                    let center = toCanvas(pos.x, pos.y)
                    let radius = pulse.radius * k * s
                    let g = CIFilter.radialGradient()
                    g.center = center
                    let feather = max(0.75, k * s * 0.7)
                    g.radius0 = Float(effect == .ring ? radius - feather : radius * 0.35)
                    g.radius1 = Float(radius)
                    g.color0 = CIColor(red: 0.82, green: 0.78, blue: 1,
                                       alpha: pulse.opacity * (effect == .ring ? 2 : 1))
                    g.color1 = CIColor.clear
                    if var ripple = g.outputImage {
                        if effect == .ring {
                            let inner = CIFilter.radialGradient()
                            inner.center = center
                            inner.radius0 = Float(max(0, radius - 2.5 * k * s - feather))
                            inner.radius1 = Float(max(feather, radius - 2.5 * k * s))
                            inner.color0 = .white
                            inner.color1 = .clear
                            if let hole = inner.outputImage {
                                ripple = ripple.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: hole])
                            }
                        }
                        ripple = ripple.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                        screen = ripple.composited(over: screen)
                    }
                }
            }
            break
        }
        segmentStart = end
    }

    if let m = rawCursor(at: t, r.moves), m.visible != false, let (img, info) = cursorSprite(m.cursor, state) {
        let pos = st.smoothCursor ? state.timeline.cursor(at: t) : (x: m.x, y: m.y)
        let w = info.width / r.displayWidth * imageRect.width * s * st.cursorScale * (1 - 0.08 * press)
        let h = w * info.height / info.width
        let tip = toCanvas(pos.x, pos.y)
        let hx = info.hotX / info.width * w, hy = info.hotY / info.height * h
        var cursor = img.transformed(by: CGAffineTransform(scaleX: w / img.extent.width, y: h / img.extent.height)
            .concatenating(CGAffineTransform(translationX: tip.x - hx, y: tip.y - (h - hy))))
        // Motion blur: average copies along the path the tip covered during the shutter
        // (amount × one 60 fps frame of playback, so speed changes and cuts are respected).
        let amount = st.cursorBlur ?? 0
        let prevT = sourceTime(atOutput: max(0, outputTime - amount / 60), state.project.segments)
        if amount > 0, t - prevT > 0, t - prevT < 0.2 {
            let prev = st.smoothCursor ? state.timeline.cursor(at: prevT) : rawCursor(at: prevT, r.moves).map { (x: $0.x, y: $0.y) } ?? pos
            let from = toCanvas(prev.x, prev.y)
            let dx = tip.x - from.x, dy = tip.y - from.y
            let n = min(32, Int(hypot(dx, dy) / max(1, w * 0.04)))  // ponytail: ≤32 taps, faint steps on extreme flicks
            if n > 1 {
                // Trail of earlier positions at 85% total opacity, sharp cursor on top so it stays readable.
                let k = 0.85 / CGFloat(n)
                var trail = CIImage.empty()
                for i in 0..<n {
                    let f = CGFloat(i) / CGFloat(n) - 1  // -1…0: from the earlier position toward now
                    trail = cursor.transformed(by: CGAffineTransform(translationX: f * dx, y: f * dy))
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
                        ])
                        .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: trail])
                }
                cursor = cursor.composited(over: trail)
            }
        }
        screen = cursor.composited(over: screen)
    }

    // Rounded corners, soft shadow, gradient background.
    let mask = CIFilter.roundedRectangleGenerator()
    mask.extent = content
    mask.radius = Float(st.cornerRadius * k)
    mask.color = .white
    let rounded = screen.cropped(to: content).applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(),
        kCIInputMaskImageKey: mask.outputImage ?? CIImage.empty(),
    ])
    let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: content)
        .applyingGaussianBlur(sigma: 24 * k)
        .transformed(by: CGAffineTransform(translationX: 0, y: -12 * k))
    return rounded.composited(over: shadow.composited(over: background(st, state.background, canvas, k))).cropped(to: canvas)
}

/// Image (aspect-fill, optional blur) or the two-color gradient.
private func background(_ st: Style, _ image: CIImage?, _ canvas: CGRect, _ k: Double) -> CIImage {
    if let image, image.extent.width > 0 {
        let e = image.extent
        let fill = max(canvas.width / e.width, canvas.height / e.height)
        var bg = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: fill, y: fill))
            .concatenating(CGAffineTransform(translationX: (canvas.width - e.width * fill) / 2, y: (canvas.height - e.height * fill) / 2)))
        if let blur = st.backgroundBlur, blur > 0 {
            bg = bg.clampedToExtent().applyingGaussianBlur(sigma: blur * k)  // clamp keeps edges from going transparent
        }
        return bg.cropped(to: canvas)
    }
    let g = CIFilter.linearGradient()
    g.point0 = CGPoint(x: 0, y: canvas.height)
    g.point1 = CGPoint(x: canvas.width, y: 0)
    g.color0 = ciColor(hex: st.backgroundTop)
    g.color1 = ciColor(hex: st.backgroundBottom)
    return (g.outputImage ?? CIImage(color: .black)).cropped(to: canvas)
}

struct Edit {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
}

private func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60_000) }

/// Builds the cut/sped-up composition (video + system audio + mic) with the custom compositor attached.
func buildEdit(folder: URL, recording r: Recording, project p: Project, renderSize: CGSize) async throws -> Edit {
    let comp = AVMutableComposition()
    let screenAsset = AVURLAsset(url: folder.appendingPathComponent("screen.mov"))
    guard let vSrc = try await screenAsset.loadTracks(withMediaType: .video).first,
          let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw StudioError("The recording has no video.") }
    let videoDuration = try await screenAsset.load(.duration).seconds

    // Keep each AVURLAsset alive: an AVAssetTrack does not retain its asset, and inserting
    // from a track whose asset was freed fails with -12780.
    var audios: [(asset: AVURLAsset, dst: AVMutableCompositionTrack, src: AVAssetTrack, offset: Double, duration: Double)] = []
    for (name, offset) in [("system.m4a", r.systemAudioOffset), ("mic.m4a", r.micOffset)] {
        guard let offset else { continue }
        let asset = AVURLAsset(url: folder.appendingPathComponent(name))
        guard let src = try await asset.loadTracks(withMediaType: .audio).first,
              let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { continue }
        audios.append((asset, dst, src, offset, try await asset.load(.duration).seconds))
    }

    var webcam: (asset: AVURLAsset, src: AVAssetTrack, dst: AVMutableCompositionTrack, offset: Double, duration: Double)?
    var webcamTransform = CGAffineTransform.identity
    if let offset = r.webcamOffset, (p.webcam ?? WebcamSettings()).enabled {
        let asset = AVURLAsset(url: folder.appendingPathComponent("webcam.mov"))
        guard let src = try await asset.loadTracks(withMediaType: .video).first,
              let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError("The webcam track is missing. Turn off Show webcam to edit without it.")
        }
        webcamTransform = try await src.load(.preferredTransform)
        webcam = (asset, src, dst, offset, try await asset.load(.duration).seconds)
    }

    var at = CMTime.zero
    for seg in p.segments {
        let start = min(seg.start, videoDuration), end = min(seg.end, videoDuration)
        guard end > start else { continue }
        try vTrack.insertTimeRange(CMTimeRange(start: time(start), end: time(end)), of: vSrc, at: at)
        for a in audios {  // audio file time = video time - offset
            let a0 = max(start - a.offset, 0), a1 = min(end - a.offset, a.duration)
            guard a1 > a0 else { continue }
            try a.dst.insertTimeRange(CMTimeRange(start: time(a0), end: time(a1)), of: a.src, at: at + time(a0 + a.offset - start))
        }
        if let camera = webcam {
            let c0 = max(start - camera.offset, 0), c1 = min(end - camera.offset, camera.duration)
            if c1 > c0 {
                try camera.dst.insertTimeRange(CMTimeRange(start: time(c0), end: time(c1)), of: camera.src,
                                               at: at + time(c0 + camera.offset - start))
            }
        }
        if seg.speed != 1 {
            let insertedDuration = time(end) - time(start)
            comp.scaleTimeRange(CMTimeRange(start: at, duration: insertedDuration),
                                toDuration: CMTimeMultiplyByFloat64(insertedDuration, multiplier: 1 / seg.speed))
        }
        at = comp.duration
    }

    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = Compositor.self
    vc.frameDuration = CMTime(value: 1, timescale: 60)
    vc.renderSize = renderSize
    vc.instructions = [FrameInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), trackID: vTrack.trackID,
                                        state: RenderState(folder: folder, recording: r, project: p),
                                        webcamTrackID: webcam?.dst.trackID, webcamTransform: webcamTransform)]
    return Edit(composition: comp, videoComposition: vc)
}

enum ExportCodec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }

/// MP4 in the project canvas format at the selected short edge (720/1080/2160), 60 fps.
/// `progress` gets 0…1 a few times a second. Cancelling the task stops the export and deletes the partial file.
func exportVideo(folder: URL, recording: Recording, project: Project, height: Double, codec: ExportCodec, to url: URL,
                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
    let size = project.resolvedCanvas.format.size(shortEdge: height)
    let edit = try await buildEdit(folder: folder, recording: recording, project: project, renderSize: size)
    let preset = codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    guard let session = AVAssetExportSession(asset: edit.composition, presetName: preset) else {
        throw StudioError("This Mac cannot export \(codec.rawValue).")
    }
    session.videoComposition = edit.videoComposition
    session.audioTimePitchAlgorithm = .spectral
    // Retimed AAC can come out a few frames long; the video defines the length.
    if let video = edit.composition.tracks(withMediaType: .video).first { session.timeRange = video.timeRange }
    try? FileManager.default.removeItem(at: url)
    let monitor = progress.map { report in
        Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { report(p.fractionCompleted) }
            }
        }
    }
    defer { monitor?.cancel() }
    do {
        try await session.export(to: url, as: .mp4)
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

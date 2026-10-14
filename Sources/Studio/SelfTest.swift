import AppKit
import AVFoundation
import CoreImage

private func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: \(what)"); exit(1) }
}

private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

/// `Studio --selftest`: the pure logic (zoom rule, springs, grouping, time mapping).
func runSelfTest() {
    let z = autoZooms(clicks: [1, 3, 8.5, 9.5], duration: 10)
    check(z.count == 2, "clicks 1s and 3s merge, 8.5s separate, 9.5s ignored (last second)")
    check(near(z[0].0, 0.7) && near(z[0].1, 5.5), "first zoom is 0.7–5.5")
    check(near(z[1].0, 8.2) && near(z[1].1, 9.2), "second zoom clamps to duration-0.8")

    var x = 0.0, v = 0.0, peak = 0.0
    for _ in 0..<240 { springStep(&x, &v, to: 1, dt: 1.0 / 240); peak = max(peak, x) }
    check(near(x, 1, 0.01) && peak <= 1, "spring settles on target without overshoot")

    // Cursor smoothing has no lag: a steady glide passes through unchanged, a held position
    // (where clicks happen) is exact, and a sudden step is softened without overshoot.
    let glide = (0..<100).map { (x: Double($0) / 100, y: 0.5) }
    let sg = smoothPath(glide, sigma: 4.8)
    check((20..<80).allSatisfy { near(sg[$0].x, glide[$0].x, 1e-9) }, "smoothing adds no lag to a steady glide")
    let step = (0..<100).map { (x: $0 < 50 ? 0.2 : 0.8, y: 0.5) }
    let ss = smoothPath(step, sigma: 4.8)
    check(near(ss[30].x, 0.2, 1e-6) && near(ss[70].x, 0.8, 1e-6), "held positions stay exact")
    check(ss.allSatisfy { $0.x >= 0.2 - 1e-12 && $0.x <= 0.8 + 1e-12 } && ss[49].x > 0.2 && ss[50].x < 0.8, "step is softened without overshoot")

    let g = moveGroups([MoveSample(t: 0, x: 0.1, y: 0.1, cursor: ""), MoveSample(t: 1, x: 0.2, y: 0.2, cursor: ""),
                        MoveSample(t: 2, x: 0.9, y: 0.9, cursor: "")])
    check(g.count == 2 && near(g[0].x, 0.15) && near(g[1].start, 2), "move groups split on span, dwell-weighted center")

    let segs = [Segment(start: 0, end: 4), Segment(start: 6, end: 10, speed: 2)]
    check(near(outputDuration(segs), 6), "output duration counts speed")
    check(near(sourceTime(atOutput: 5, segs), 8), "output 5s maps to source 8s")
    check(near(outputTime(atSource: 5, segs), 4), "time inside a cut snaps to the next clip")

    var deletionProject = Project(recording: Recording(duration: 10, displayWidth: 100, displayHeight: 100, moves: [], clicks: [], cursors: [:]))
    deletionProject.segments = [Segment(start: 0, end: 2), Segment(start: 2, end: 6, speed: 2), Segment(start: 6, end: 10)]
    let removedID = deletionProject.segments[1].id
    let deletion = deletingSegment(in: deletionProject, id: removedID, playhead: 5)!
    check(deletion.project.segments.count == 2 && near(outputDuration(deletion.project.segments), 6), "delete split clip closes the gap and respects speed")
    check(near(deletion.playhead, 3), "deleting earlier clip preserves playhead source position")
    check(near(deletingSegment(in: deletionProject, id: removedID, playhead: 3)!.playhead, 2), "playhead inside deleted clip moves to cut")
    check(near(deletingSegment(in: deletionProject, id: removedID, playhead: 1)!.playhead, 1), "deleting later clip keeps playhead")
    var deleteHistory = ProjectHistory()
    deleteHistory.reset(deletionProject)
    deleteHistory.record(deletion.project)
    check(deleteHistory.undo() == deletionProject && deleteHistory.redo() == deletion.project, "split deletion supports undo and redo")
    deletionProject.segments = [deletionProject.segments[0]]
    check(deletingSegment(in: deletionProject, id: deletionProject.segments[0].id, playhead: 0) == nil, "last clip cannot be deleted")
    let pc = PauseClock()
    pc.pause(at: 10); pc.resume(at: 13); pc.pause(at: 20)
    check(pc.map(5) == (5, false) && pc.map(11) == (10, true) && pc.map(15) == (12, false) && pc.map(25) == (17, true) && pc.isPaused,
          "pauses are cut out of recording time; time inside a pause clamps to its start")
    pc.resume(at: 22)
    check(pc.map(23) == (18, false) && !pc.isPaused, "second resume shifts by both pauses")
    let zz = [Zoom(start: 1, end: 4, scale: 2.5)]
    let zcut = splittingZoom(zz, id: zz[0].id, at: 2.5)
    check(zcut?.zooms.count == 2 && zcut?.zooms[0].end == 2.5 && zcut?.zooms[1].start == 2.5 && zcut?.zooms[1].scale == 2.5
          && zcut?.zooms[1].id == zcut?.right && splittingZoom(zz, id: zz[0].id, at: 1.01) == nil, "zoom splits at playhead, keeping its settings")
    check(CursorLook.all.allSatisfy { look in
        guard let img = cursorImage(look) else { return false }
        let rep = NSBitmapImageRep(cgImage: img), pad = Int(cursorPad * 128)
        return (rep.colorAt(x: pad, y: pad + 6)?.alphaComponent ?? 0) > 0.9   // tip drawn at the hotspot
            && (rep.colorAt(x: 2, y: img.height - 2)?.alphaComponent ?? 1) < 0.1   // corner stays clear
    }, "drawn cursors put their tip on the hotspot")

    for look in CursorLook.all {
        let data = try! JSONEncoder().encode(look)
        check(try! JSONDecoder().decode(CursorLook.self, from: data) == look, "cursor style round trip: \(look.shape.title)")
    }
    let legacyLook = try! JSONDecoder().decode(CursorLook.self,
        from: Data(##"{"shape":"rounded","fill":"#2F7BFF","outline":"#FFFFFF"}"##.utf8))
    check(legacyLook.shape == .rounded && legacyLook.fill == "#2F7BFF", "existing cursor looks remain compatible")
    let hollow = cursorImage(CursorLook(shape: .outline, fill: "#9B5CFF", outline: "#FFFFFF"))!
    check((NSBitmapImageRep(cgImage: hollow).colorAt(x: 35, y: 60)?.alphaComponent ?? 1) < 0.1,
          "outline cursor has a transparent interior")

    var cameraStyle = WebcamSettings()
    for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080)] {
        for position in [0.0, 1.0] {
            cameraStyle.x = position; cameraStyle.y = position
            check(CGRect(origin: .zero, size: canvas).contains(cameraStyle.rect(in: canvas)), "webcam remains within each canvas at both corners")
        }
    }
    let testCanvas = CGSize(width: 400, height: 300)
    var overlaySettings = WebcamSettings()
    overlaySettings.size = 0.5; overlaySettings.x = 0.5; overlaySettings.y = 0.5
    overlaySettings.shape = .square; overlaySettings.mirrored = false
    let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: testCanvas))
    let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 100))
    let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 50, y: 0, width: 50, height: 100))
    let cameraFrame = left.composited(over: right)
    let context = CIContext()
    func sampleCamera(_ settings: WebcamSettings, x: Int, y: Int) -> NSColor {
        let image = overlayWebcam(cameraFrame, on: background, settings: settings, size: testCanvas)
        return NSBitmapImageRep(cgImage: context.createCGImage(image, from: image.extent)!).colorAt(x: x, y: y)!
    }
    check(sampleCamera(overlaySettings, x: 150, y: 150).redComponent > 0.9, "webcam preserves source orientation")
    overlaySettings.mirrored = true
    check(sampleCamera(overlaySettings, x: 150, y: 150).blueComponent > 0.9, "webcam mirror reverses horizontal position")
    overlaySettings.shape = .circle
    check(sampleCamera(overlaySettings, x: 126, y: 76).redComponent < 0.1, "circle webcam masks its corners")
    overlaySettings.enabled = false
    check(sampleCamera(overlaySettings, x: 150, y: 150).blueComponent < 0.1, "disabled webcam leaves the canvas unchanged")
    let cameraData = try! JSONEncoder().encode(cameraStyle)
    check(try! JSONDecoder().decode(WebcamSettings.self, from: cameraData) == cameraStyle, "webcam settings round trip")
    let legacyRecording = try! JSONDecoder().decode(Recording.self,
        from: Data(#"{"duration":1,"displayWidth":100,"displayHeight":100,"moves":[],"clicks":[],"cursors":{}}"#.utf8))
    check(legacyRecording.webcamOffset == nil && Project(recording: legacyRecording).webcam == nil,
          "older recordings do not acquire a webcam")

    let rec = Recording(duration: 3, displayWidth: 1440, displayHeight: 900, systemAudioOffset: nil, micOffset: nil,
                        moves: [MoveSample(t: 0, x: 0.9, y: 0.9, cursor: "")], clicks: [], cursors: [:])
    let tl = simulate(rec, zooms: [Zoom(start: 0.2, end: 2.8)])
    let cam = tl.camera[tl.index(2)]
    check(cam.scale > 1.95 && near(cam.x, 0.75, 0.001) && cam.x + 0.5 / cam.scale <= 1 + 1e-9, "camera zooms in and stays inside the frame")
    let fixed = Zoom(start: 0, end: 3, focus: ZoomFocus(x: 0.3, y: 0.4))
    let focused = simulate(rec, zooms: [Zoom(start: 0, end: 3), fixed]).camera(at: 2)
    check(near(focused.x, 0.3, 0.001) && near(focused.y, 0.4, 0.001), "latest zoom uses fixed focus over cursor-following zoom")
    let legacyZoom = try! JSONDecoder().decode(Zoom.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000000\",\"start\":0,\"end\":3,\"scale\":2,\"enabled\":true}".utf8))
    check(legacyZoom.focus == nil, "old zooms keep cursor-following behavior")
    check(try! JSONDecoder().decode(Zoom.self, from: JSONEncoder().encode(fixed)) == fixed, "manual focus persists")
    for format in CanvasFormat.allCases {
        for fit in ContentFit.allCases {
            var p = Project(recording: rec)
            var canvas = CanvasSettings()
            canvas.format = format
            canvas.placement = ContentPlacement(fit: fit, horizontal: 0.2, vertical: 0.8)
            p.canvas = canvas
            let size = format.size(shortEdge: 400)
            let layout = contentGeometry(source: CGSize(width: 1440, height: 900), canvas: size,
                                         padding: p.style.padding, placement: canvas.placement)
            let point = CGPoint(x: layout.visible.midX, y: size.height - layout.visible.midY)
            let focus = focusAtPreviewPoint(point, size: size, recording: rec, project: p)!
            check(near(layout.image.minX + focus.x * layout.image.width, point.x) &&
                  near(size.height - layout.image.maxY + focus.y * layout.image.height, point.y), "focus mapping matches canvas crop")
            check(focusAtPreviewPoint(.zero, size: size, recording: rec, project: p) == nil, "background clicks do not set focus")
        }
    }
    let durationZoom = Zoom(start: 1, end: 8)
    check(near(resizedZoom(durationZoom, edge: .end, outputDelta: 0.5, segments: segs, duration: 10).end, 9), "zoom handle respects clip speed")
    check(near(resizedZoom(durationZoom, edge: .start, outputDelta: 100, segments: segs, duration: 10).start, 7.8), "zoom handles cannot cross")
    check(near(resizedZoom(durationZoom, edge: .end, outputDelta: 100, segments: segs, duration: 10).end, 10), "zoom end stays inside recording")
    let fractional = Timeline(camera: [Camera(), Camera(x: 0.6, y: 0.6, scale: 2)],
                              cursor: [(0.2, 0.3), (0.8, 0.7)])
    check(near(fractional.cursor(at: 1 / 120.0).x, 0.5), "half-speed cursor interpolates between frames")
    check(near(fractional.camera(at: 1 / 120.0).scale, 1.5), "camera interpolates fractional timestamps")
    check(near(fractional.cursor(at: -1).x, 0.2) && near(fractional.cursor(at: 10).x, 0.8), "timeline clamps at its boundaries")
    let dwell = [MoveSample(t: 0, x: 0.2, y: 0.3, cursor: ""), MoveSample(t: 2, x: 0.8, y: 0.7, cursor: "")]
    check(near(cursorPosition(at: 1, dwell)!.x, 0.2), "sparse samples preserve stationary cursor holds")
    check(near(cursorPosition(at: 2 - 1 / 120.0, dwell)!.x, 0.5), "cursor interpolates the capture interval")
    check(clickPulse(age: 0).opacity == 0 && clickPulse(age: 0.55).opacity == 0,
          "click effect starts and ends invisible")
    check(clickPulse(age: 0.001).opacity < 0.001 && clickPulse(age: 0.549).opacity < 0.001,
          "click effect eases at both boundaries")
    check((0...550).allSatisfy {
        let p = clickPulse(age: Double($0) / 1000)
        return p.opacity >= 0 && p.opacity <= 0.30 && p.press >= 0 && p.press <= 1
    }, "click pulse remains bounded throughout its duration")
    var legacyStyle = Style()
    check(legacyStyle.resolvedClickEffect == .glow, "legacy enabled click effect uses glow")
    legacyStyle.clickEffect = false
    check(legacyStyle.resolvedClickEffect == .off, "legacy disabled click effect stays disabled")
    for effect in ClickEffectStyle.allCases {
        legacyStyle.clickEffectStyle = effect
        let data = try! JSONEncoder().encode(legacyStyle)
        let restored = try! JSONDecoder().decode(Style.self, from: data)
        check(restored.resolvedClickEffect == effect, "click effect choice survives saving and reopening")
    }
    check(audioBitRate(sampleRate: 16_000, channels: 1) == 32_000, "headset microphone uses a supported mono bitrate")
    check(audioBitRate(sampleRate: 48_000, channels: 2) == 128_000, "system audio keeps stereo bitrate")
    testEditing(rec)
    testCanvasAndPresets(rec)
    let captureFrame = CGRect(x: -1200, y: 100, width: 1000, height: 600)
    let center = capturePointer(CGPoint(x: -700, y: 400), frame: captureFrame, canvas: captureFrame.size)
    check(near(center.x, 0.5) && near(center.y, 0.5) && center.visible, "cursor maps on displays with negative global coordinates")
    let resized = capturePointer(CGPoint(x: 100, y: 100), frame: CGRect(x: 100, y: 100, width: 400, height: 400),
                                 canvas: CGSize(width: 1000, height: 600))
    check(near(resized.x, 0) && near(resized.y, 0), "resized window cursor uses the capture buffer top-left origin")
    let resizedCenter = capturePointer(CGPoint(x: 300, y: 300), frame: CGRect(x: 100, y: 100, width: 400, height: 400),
                                       canvas: CGSize(width: 1000, height: 600))
    check(near(resizedCenter.x, 0.3) && near(resizedCenter.y, 0.5), "resized window cursor respects the captured content scale")
    check(!capturePointer(.zero, frame: captureFrame, canvas: captureFrame.size).visible, "cursor outside the selected source is hidden")
    let oldMove = try! JSONDecoder().decode(MoveSample.self, from: Data(#"{"t":0,"x":0.5,"y":0.5,"cursor":"arrow"}"#.utf8))
    check(oldMove.visible == nil, "older cursor recordings remain compatible")
    print("selftest ok")
}

private func testCanvasAndPresets(_ recording: Recording) {
    check(CanvasFormat.landscape.size(shortEdge: 1080) == CGSize(width: 1920, height: 1080), "landscape Full HD dimensions")
    check(CanvasFormat.portrait.size(shortEdge: 1080) == CGSize(width: 1080, height: 1920), "portrait Full HD dimensions")
    check(CanvasFormat.square.size(shortEdge: 2160) == CGSize(width: 2160, height: 2160), "square 4K dimensions")
    check(CanvasFormat.allCases.allSatisfy {
        let s = $0.size(shortEdge: 721)
        return Int(s.width) % 2 == 0 && Int(s.height) % 2 == 0
    }, "all output sizes are encoder-safe even dimensions")
    var canvas = CanvasSettings()
    canvas.format = .portrait
    canvas.placement.vertical = 0.2
    canvas.placement.fit = .fill
    canvas.format = .square
    canvas.placement.horizontal = 0.8
    canvas.format = .portrait
    check(near(canvas.placement.vertical, 0.2) && canvas.placement.fit == .fill, "each format remembers its own framing")
    let top = contentGeometry(source: CGSize(width: 1600, height: 1000), canvas: CGSize(width: 1080, height: 1920),
                              padding: 0.1, placement: ContentPlacement(fit: .fit, horizontal: 0.5, vertical: 0))
    check(near(top.image.maxY, top.viewport.maxY) && top.image == top.visible, "fit shows the entire recording and top alignment uses top-left UI coordinates")
    let bottom = contentGeometry(source: CGSize(width: 1600, height: 1000), canvas: CGSize(width: 1080, height: 1920),
                                 padding: 0.1, placement: ContentPlacement(fit: .fit, horizontal: 0.5, vertical: 1))
    check(near(bottom.image.minY, bottom.viewport.minY), "bottom alignment places content at the lower padding")
    let crop = contentGeometry(source: CGSize(width: 1600, height: 1000), canvas: CGSize(width: 1080, height: 1920),
                               padding: 0.1, placement: ContentPlacement(fit: .fill, horizontal: 1, vertical: 0.5))
    check(crop.visible == crop.viewport && near(crop.image.maxX, crop.viewport.maxX), "fill covers the viewport and right alignment selects the right crop")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-preset-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let fm = FileManager.default
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let library = PresetLibrary(root: root.appendingPathComponent("presets"))
        let imageBytes = Data("asset-copy-test".utf8)
        try imageBytes.write(to: source.appendingPathComponent("wallpaper.png"))
        var style = Style()
        style.backgroundImage = "wallpaper.png"
        style.clickEffectStyle = .ring
        style.padding = 0.12
        let preset = try library.save(name: "  My style  ", style: style, projectFolder: source)
        let loadedPresets = try library.load()
        check(preset.name == "My style" && loadedPresets.count == 1, "custom presets persist and trim their names")
        do {
            _ = try library.save(name: "my STYLE", style: style, projectFolder: source)
            check(false, "duplicate preset name should be rejected")
        } catch {}
        try fm.removeItem(at: source)
        let applied = try library.appliedStyle(preset, projectFolder: target)
        check(try Data(contentsOf: target.appendingPathComponent(applied.backgroundImage!)) == imageBytes,
              "preset image remains available after the original recording is removed")
        check(applied.clickEffectStyle == .ring && near(applied.padding, 0.12), "saved cursor and padding settings are restored")
        try library.delete(preset)
        check((try library.load()).isEmpty && fm.fileExists(atPath: target.appendingPathComponent(applied.backgroundImage!).path),
              "deleting a preset keeps applied project assets intact")
        let legacy = Project(recording: recording)
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        check(decoded.canvas == nil && decoded.resolvedCanvas == CanvasSettings(), "older projects default to centered landscape")
        var project = decoded
        project.canvas = canvas
        let changed = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        check(changed.resolvedCanvas == canvas, "format and independent positions survive reopening")
        var history = ProjectHistory()
        history.reset(project)
        project.style = applied
        history.record(project)
        let undone = history.undo()!
        check(undone.style == decoded.style && undone.resolvedCanvas == canvas, "preset application is undoable without changing the canvas")
        check(history.redo()?.style == applied, "preset application can be redone")
        do {
            _ = try library.save(name: "Missing asset", style: style, projectFolder: source)
            check(false, "missing preset image should fail")
        } catch {}
        check((try library.load()).isEmpty, "failed preset save leaves no partial preset")
    } catch { check(false, "preset persistence: \(error)") }
}

private func testEditing(_ recording: Recording) {
    var original = Project(recording: recording)
    original.segments = [Segment(start: 0, end: 4), Segment(start: 6, end: 10, speed: 2)]
    let first = original.segments[0].id, second = original.segments[1].id
    let shortened = trimmedSegment(in: original, id: second, edge: .start, outputDelta: 0.5, duration: 10)!
    check(near(shortened.start, 7), "trim delta respects 2x clip speed")
    check(near(trimmedSegment(in: original, id: second, edge: .start, outputDelta: -100, duration: 10)!.start, 4),
          "extending a clip stops at its preceding neighbor")
    check(near(trimmedSegment(in: original, id: first, edge: .end, outputDelta: 100, duration: 10)!.end, 6),
          "extending a clip stops at its following neighbor")
    check(near(trimmedSegment(in: original, id: first, edge: .start, outputDelta: -100, duration: 10)!.start, 0),
          "trim cannot precede the recording")
    check(near(trimmedSegment(in: original, id: second, edge: .end, outputDelta: 100, duration: 10)!.end, 10),
          "trim cannot exceed the recording")
    let tiny = trimmedSegment(in: original, id: first, edge: .end, outputDelta: -100, duration: 10)!
    check(tiny.end > tiny.start && near(tiny.end - tiny.start, 0.05), "trim preserves minimum clip duration")
    check(trimmedSegment(in: original, id: first, edge: .end, outputDelta: .nan, duration: 10) == nil,
          "invalid trim deltas are rejected")

    var history = ProjectHistory()
    history.reset(original)
    check(!history.canUndo && !history.canRedo, "opening a project starts with empty history")
    var edited = original
    edited.segments[1] = shortened
    history.record(edited)
    check(history.undo() == original && history.redo() == edited, "trim undo and redo restore exact project snapshots")
    _ = history.undo()
    history.record(original)
    check(history.canRedo, "no-op observations preserve redo history")
    var restyled = original
    restyled.style.clickEffectStyle = .ring
    history.record(restyled)
    check(!history.canRedo, "a new edit after undo clears redo")
    history.begin(restyled)
    for i in 1...30 {
        restyled.style.padding = Double(i) / 200
        history.record(restyled)
    }
    history.end(restyled)
    check(history.past.count == 2, "one slider drag creates one history entry")
    let restored = history.undo()!
    check(near(restored.style.padding, original.style.padding) && restored.style.clickEffectStyle == .ring,
          "slider undo restores its starting value without reverting the preceding edit")
    history.begin(restored)
    history.end(restored)
    check(history.canRedo, "an unchanged slider gesture preserves redo")
    history.reset(original)
    for i in 0..<110 {
        edited.style.cornerRadius = Double(i)
        history.record(edited)
    }
    check(history.past.count == 100, "history memory is bounded")
}

/// `Studio --render-test <dir>`: builds a synthetic 3 s recording, exports it through the real
/// composition + compositor, and writes sample frames as PNGs. Needs no screen-recording permission.
func runRenderTest(_ dir: URL) {
    _ = NSApplication.shared  // AppKit resources (cursor images) need an app object
    var finished = false
    Task {
        do {
            try await renderTest(dir)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
        finished = true
    }
    // Keep the main run loop alive: AppKit and AVFoundation hop to it.
    while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
}

/// `Studio --record-test`: real 1.5 s + (1.5 s paused) + 1.5 s capture of the main display; needs Screen Recording.
/// Checks the pause is cut from every file, then deletes the take. Also checks cancel removes its folder.
func runRecordTest() {
    _ = NSApplication.shared
    var finished = false
    Task { @MainActor in
        let r = Recorder()
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        await r.start(target: .display(CGMainDisplayID()), microphoneID: nil)
        guard r.isRecording else { print("FAIL: could not start: \(r.error ?? "?")"); exit(1) }
        await wait(1.5); r.pause(); await wait(1.5); r.resume(); await wait(1.5)
        guard let folder = await r.stop() else { print("FAIL: stop: \(r.error ?? "?")"); exit(1) }
        let rec = try! readJSON(Recording.self, folder.appendingPathComponent("recording.json"))
        let video = try! await AVURLAsset(url: folder.appendingPathComponent("screen.mov")).load(.duration).seconds
        let system = (try? await AVURLAsset(url: folder.appendingPathComponent("system.m4a")).load(.duration).seconds) ?? 0
        print(String(format: "recorded %.2f s, screen.mov %.2f s, system.m4a %.2f s", rec.duration, video, system))
        check(abs(rec.duration - 3) < 0.3 && abs(video - rec.duration) < 0.15, "pause is cut from the video")
        check(system == 0 || system < rec.duration + 0.3, "pause is cut from system audio")
        check(rec.moves.allSatisfy { $0.t <= rec.duration + 0.05 }, "cursor samples fit the shortened timeline")
        try? FileManager.default.removeItem(at: folder)

        let folders = { (try? FileManager.default.contentsOfDirectory(atPath: Library.root.path).count) ?? 0 }
        let before = folders()
        await r.start(target: .display(CGMainDisplayID()), microphoneID: nil)
        await wait(0.5)
        await r.cancel()
        check(!r.isRecording && folders() == before, "cancel stops and deletes the take")
        print("record test ok")
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
}

/// `Studio --export <recording folder> <out.mp4>`: exports a saved project at 1080p without the UI.
func runExport(_ folder: URL, to out: URL) {
    _ = NSApplication.shared
    var finished = false
    Task {
        do {
            let r = try readJSON(Recording.self, folder.appendingPathComponent("recording.json"))
            let p = try readJSON(Project.self, folder.appendingPathComponent("project.json"))
            try await exportVideo(folder: folder, recording: r, project: p, height: 1080, codec: .h264, to: out)
            print("exported \(out.path)")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
}

private func renderTest(_ dir: URL) async throws {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir.appendingPathComponent("cursors"), withIntermediateDirectories: true)

    var countdownTicks: [Int] = []
    try await runCaptureCountdown(tick: { countdownTicks.append($0) }, wait: { await Task.yield() })
    check(countdownTicks == [3, 2, 1], "countdown emits three ordered steps before capture")
    var canceledTicks: [Int] = []
    do {
        try await runCaptureCountdown(tick: { canceledTicks.append($0) }, wait: { throw CancellationError() })
        check(false, "canceled countdown must not continue to capture")
    } catch is CancellationError {
        check(canceledTicks == [3], "cancel stops the countdown before capture")
    }

    // 1. Synthetic screen: 1440x900 @30fps, a colored block per second and a "button" at (0.7, 0.3).
    let (w, h, fps, seconds) = (1440, 900, 30, 3)
    let writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("screen.mov"), fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for f in 0..<(fps * seconds) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let pb else { throw StudioError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        for gx in stride(from: 0, to: w, by: 60) { ctx.stroke(CGRect(x: gx, y: 0, width: 60, height: h)) }
        let colors = [CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1), CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1), CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1)]
        ctx.setFillColor(colors[f / fps]); ctx.fill(CGRect(x: 40, y: h - 140, width: 300, height: 100))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: Int(0.7 * Double(w)) - 80, y: Int(0.7 * Double(h)) - 25, width: 160, height: 50))  // CG is bottom-left
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
    await writer.finishWriting()

    // 2. Cursor image + input: glide to the button, click at 1s, wander off at 2.2s.
    let arrow = NSCursor.arrow
    let rep = NSBitmapImageRep.imageReps(with: arrow.image.tiffRepresentation!).compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }!
    try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("cursors/arrow.png"))
    var moves: [MoveSample] = []
    for i in 0...(seconds * 60) {
        let t = Double(i) / 60
        let p = t < 1 ? (0.2 + 0.5 * t, 0.6 - 0.3 * t) : t < 2.2 ? (0.7, 0.3) : (0.7 - 0.3 * (t - 2.2), 0.3 + 0.4 * (t - 2.2))
        moves.append(MoveSample(t: t, x: p.0, y: p.1, cursor: "arrow"))
    }
    // System audio: 3 s of 440 Hz tone, starting slightly before the video like real captures.
    let tone = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: tone, frameCapacity: 48_000 * 3)!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![ch][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) } }
    do {
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent("system.m4a"),
                                   settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        try file.write(from: pcm)
    }  // file closes here
    let rec = Recording(duration: Double(seconds), displayWidth: 1440, displayHeight: 900, systemAudioOffset: -0.011, micOffset: nil,
                        moves: moves, clicks: [Click(t: 1, x: 0.7, y: 0.3)],
                        cursors: ["arrow": CursorInfo(hotX: arrow.hotSpot.x, hotY: arrow.hotSpot.y, width: arrow.image.size.width, height: arrow.image.size.height)])
    var project = Project(recording: rec)
    check(project.zooms.count == 1 && near(project.zooms[0].start, 0.7) && near(project.zooms[0].end, 2.2), "auto zoom from the click")
    try writeJSON(rec, dir.appendingPathComponent("recording.json"))
    try writeJSON(project, dir.appendingPathComponent("project.json"))

    // 3. Export through the real pipeline: last 1.5 s at 2x, so 2.25 s out.
    project.segments = [Segment(start: 0, end: 1.5), Segment(start: 1.5, end: 3, speed: 2)]
    // Image background (a 6K system wallpaper when present) with blur.
    let wallpaper = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
    if (try? fm.copyItem(at: wallpaper, to: dir.appendingPathComponent("bg.heic"))) != nil {
        project.style.backgroundImage = "bg.heic"
        project.style.backgroundBlur = 12
    }
    let out = dir.appendingPathComponent("export.mp4")
    final class Fractions: @unchecked Sendable { let lock = NSLock(); var values: [Double] = [] }
    let seen = Fractions()
    try await exportVideo(folder: dir, recording: rec, project: project, height: 720, codec: .h264, to: out) { f in
        seen.lock.withLock { seen.values.append(f) }
    }
    check(!seen.values.isEmpty && seen.values.allSatisfy { (0...1).contains($0) } && zip(seen.values, seen.values.dropFirst()).allSatisfy { $0 <= $1 },
          "export reports rising progress (\(seen.values.count) updates)")
    // Cancelling mid-export throws and leaves no partial file (4K so it is still running when cancelled).
    let cancelled = dir.appendingPathComponent("cancelled.mp4")
    let job = Task { try await exportVideo(folder: dir, recording: rec, project: project, height: 2160, codec: .hevc, to: cancelled) }
    try await Task.sleep(nanoseconds: 300_000_000)
    job.cancel()
    let outcome = await job.result
    check((try? outcome.get()) == nil && !FileManager.default.fileExists(atPath: cancelled.path), "cancelled export throws and removes its file")
    let asset = AVURLAsset(url: out)
    let duration = try await asset.load(.duration).seconds
    let track = try await asset.loadTracks(withMediaType: .video).first
    let size = try await track?.load(.naturalSize) ?? .zero
    check(near(duration, 2.25, 0.05), "exported duration \(duration) ≈ 2.25 s")
    check(size == CGSize(width: 1280, height: 720), "exported size \(size)")
    check(try await !asset.loadTracks(withMediaType: .audio).isEmpty, "exported file has the system audio track")

    // 4. Sample frames for eyeballing: before zoom, fully zoomed on the click, zooming out.
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    for t in [0.3, 1.05, 1.9] {
        let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
        let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent(String(format: "frame-%.2f.png", t)))
    }
    // Trim at both ends, round-trip through history, then verify the actual exported duration.
    var edits = ProjectHistory()
    edits.reset(project)
    project.segments[0] = trimmedSegment(in: project, id: project.segments[0].id, edge: .start,
                                         outputDelta: 0.25, duration: rec.duration)!
    project.segments[1] = trimmedSegment(in: project, id: project.segments[1].id, edge: .end,
                                         outputDelta: -0.25, duration: rec.duration)!
    edits.record(project)
    _ = edits.undo()
    project = edits.redo()!
    let trimmedURL = dir.appendingPathComponent("trimmed.mp4")
    try await exportVideo(folder: dir, recording: rec, project: project, height: 720, codec: .h264, to: trimmedURL)
    let trimmedDuration = try await AVURLAsset(url: trimmedURL).load(.duration).seconds
    check(near(trimmedDuration, 1.75, 0.05), "trimmed export matches retimed duration after undo/redo")
    // Exercise every new format and both framing modes through the real compositor/export path.
    for format in [CanvasFormat.portrait, .square] {
        for fit in ContentFit.allCases {
            var variant = Project(recording: rec)
            variant.style = StylePreset.builtIns[2].style
            variant.segments = [Segment(start: 0, end: 0.8)]
            variant.zooms = []
            var canvas = CanvasSettings()
            canvas.format = format
            canvas.placement.fit = fit
            canvas.placement.vertical = 0.15
            canvas.placement.horizontal = 0.7
            variant.canvas = canvas
            let name = "\(format.rawValue)-\(fit.rawValue)"
            let file = dir.appendingPathComponent(name + ".mp4")
            try await exportVideo(folder: dir, recording: rec, project: variant, height: 720, codec: .h264, to: file)
            let asset = AVURLAsset(url: file)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let dimensions = try await track.load(.naturalSize)
            check(dimensions == format.size(shortEdge: 720), "\(name) exports in the selected dimensions")
            let duration = try await asset.load(.duration).seconds
            check(near(duration, 0.8, 0.05), "\(name) preserves the clip duration")
            let frameGenerator = AVAssetImageGenerator(asset: asset)
            let (image, _) = try await frameGenerator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600))
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try png.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }
    // A separate camera source exercises real decoding, missing leading frames, cuts and speed changes.
    try fm.copyItem(at: dir.appendingPathComponent("screen.mov"), to: dir.appendingPathComponent("webcam.mov"))
    var cameraRecording = rec
    cameraRecording.webcamOffset = 0.25
    var cameraProject = Project(recording: cameraRecording)
    cameraProject.segments = [Segment(start: 0, end: 0.8), Segment(start: 1.2, end: 2.8, speed: 2)]
    cameraProject.webcam = WebcamSettings()
    cameraProject.webcam!.size = 0.45
    let cameraEdit = try await buildEdit(folder: dir, recording: cameraRecording, project: cameraProject,
                                        renderSize: CGSize(width: 1280, height: 720))
    let cameraTracks = cameraEdit.composition.tracks(withMediaType: .video)
    check(cameraTracks.count == 2, "webcam is a separate composition track")
    let cameraSegments = cameraTracks[1].segments.filter { !$0.isEmpty }
    check(cameraSegments.count == 2 && near(cameraSegments[0].timeMapping.target.start.seconds, 0.25)
          && near(cameraSegments[1].timeMapping.source.start.seconds, 0.95)
          && near(cameraSegments[1].timeMapping.target.duration.seconds, 0.8), "webcam offset, cut and 2x speed stay synchronized: \(cameraSegments.map { "source=\($0.timeMapping.source), target=\($0.timeMapping.target)" })")
    let cameraURL = dir.appendingPathComponent("webcam-export.mp4")
    try await exportVideo(folder: dir, recording: cameraRecording, project: cameraProject, height: 720, codec: .h264, to: cameraURL)
    let cameraAsset = AVURLAsset(url: cameraURL)
    check(near(try await cameraAsset.load(.duration).seconds, 1.6, 0.05), "webcam export preserves edited duration")
    let cameraGenerator = AVAssetImageGenerator(asset: cameraAsset)
    cameraGenerator.requestedTimeToleranceBefore = .zero
    cameraGenerator.requestedTimeToleranceAfter = .zero
    for t in [0.1, 0.5, 1.2] {
        let (frame, _) = try await cameraGenerator.image(at: CMTime(seconds: t, preferredTimescale: 600))
        try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(
            to: dir.appendingPathComponent("webcam-\(t).png"))
    }
    cameraProject.webcam!.enabled = false
    let hiddenCamera = try await buildEdit(folder: dir, recording: cameraRecording, project: cameraProject,
                                          renderSize: CGSize(width: 1280, height: 720))
    check(hiddenCamera.composition.tracks(withMediaType: .video).count == 1, "hidden webcam is excluded from composition")
    try writeJSON(cameraRecording, dir.appendingPathComponent("recording.json"))
    cameraProject.webcam!.enabled = true
    try writeJSON(cameraProject, dir.appendingPathComponent("project.json"))

    print("render test ok: \(out.path) (\(String(format: "%.2f", duration)) s, \(Int(size.width))x\(Int(size.height)))")
}

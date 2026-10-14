import Foundation

// Recorded data. Positions are normalized 0...1 with a top-left origin;
// times are seconds from the first captured video frame.

struct MoveSample: Codable, Equatable { var t: Double; var x: Double; var y: Double; var cursor: String; var visible: Bool? = nil }
struct Click: Codable, Equatable { var t: Double; var x: Double; var y: Double }
/// Cursor image metadata in points; the PNG lives at cursors/<id>.png.
struct CursorInfo: Codable, Equatable { var hotX: Double; var hotY: Double; var width: Double; var height: Double }

struct Recording: Codable, Equatable {
    var duration: Double
    var displayWidth: Double   // points
    var displayHeight: Double
    var systemAudioOffset: Double?  // audio file start minus video start
    var webcamOffset: Double? = nil // camera file start minus screen start
    var micOffset: Double?
    var moves: [MoveSample]
    var clicks: [Click]
    var cursors: [String: CursorInfo]
}

// Edits. Zoom and segment times are in source (recording) seconds.

/// Cuts zoom `id` at source time `t`; the right half gets a new id. nil if `t` is too close to an edge.
func splittingZoom(_ zooms: [Zoom], id: UUID, at t: Double) -> (zooms: [Zoom], right: UUID)? {
    guard let i = zooms.firstIndex(where: { $0.id == id }), t > zooms[i].start + 0.05, t < zooms[i].end - 0.05 else { return nil }
    var out = zooms, right = zooms[i]
    right.id = UUID()
    right.start = t
    out[i].end = t
    out.insert(right, at: i + 1)
    return (out, right.id)
}

struct ZoomFocus: Codable, Equatable { var x: Double; var y: Double }

struct Zoom: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale = 2.0
    var enabled = true
    var focus: ZoomFocus? // nil follows the cursor; optional for older projects
}

struct Segment: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var speed = 1.0
}

enum ClickEffectStyle: String, Codable, CaseIterable, Identifiable {
    case off, glow, ring, press
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "None"
        case .glow: return "Soft glow"
        case .ring: return "Expanding ring"
        case .press: return "Cursor press"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Keep clicks invisible."
        case .glow: return "A soft glow with a gentle cursor press."
        case .ring: return "A clean ring that expands and fades."
        case .press: return "A subtle press and release, without a halo."
        }
    }
}

/// A drawn replacement for the recorded cursor. It replaces every recorded shape (I-beam, hand…).
struct CursorLook: Codable, Hashable {
    enum Shape: String, Codable, CaseIterable {
        case classic, rounded, slim, pixel, outline, gradient
        var title: String { rawValue.capitalized }
    }
    var shape: Shape
    var fill: String     // hex
    var outline: String  // hex

    static let palette: [(name: String, fill: String, outline: String)] = [
        ("Black", "#000000", "#FFFFFF"), ("White", "#FFFFFF", "#000000"),
        ("Coral", "#FF4D5E", "#FFFFFF"), ("Pink", "#FF7EB6", "#FFFFFF"),
        ("Purple", "#9B5CFF", "#FFFFFF"), ("Blue", "#2F7BFF", "#FFFFFF"),
        ("Green", "#22C55E", "#FFFFFF"), ("Yellow", "#FFC531", "#000000")
    ]
    static let all: [CursorLook] = Shape.allCases.flatMap { shape in
        palette.map { CursorLook(shape: shape, fill: $0.fill, outline: $0.outline) }
    }

}

struct Style: Codable, Equatable {
    var padding = 0.08
    var cornerRadius = 14.0  // px at 1080p output
    var backgroundTop = "#3F37C9"
    var backgroundBottom = "#7B2FF7"
    var backgroundImage: String?   // file name inside the recording folder; nil = gradient
    var backgroundBlur: Double?    // px at 1080p (optional so older project.json files still load)
    var cursorScale = 1.5
    var cursorBlur: Double? = 0.5  // 0…1 motion blur strength; older projects (nil) have none
    var cursorLook: CursorLook?    // nil = the cursor exactly as recorded
    var smoothCursor = true
    var clickEffect = true // Retained for older projects.
    var clickEffectStyle: ClickEffectStyle?
    var resolvedClickEffect: ClickEffectStyle {
        clickEffectStyle ?? (clickEffect ? .glow : .off)
    }
}

struct Project: Codable, Equatable {
    var segments: [Segment]
    var zooms: [Zoom]
    var style = Style()
    var webcam: WebcamSettings? // nil keeps older projects compatible
    var canvas: CanvasSettings? // Missing in older projects: centered landscape fit.
    var resolvedCanvas: CanvasSettings { canvas ?? CanvasSettings() }

    init(recording r: Recording) {
        segments = [Segment(start: 0, end: r.duration)]
        zooms = autoZooms(clicks: r.clicks.map(\.t), duration: r.duration).map { Zoom(start: $0.0, end: $0.1) }
    }
}

// MARK: - Automatic zoom

/// Screen Studio 4.0.4's rule: every click opens [t-0.3s, t+2.5s] (clicks in the last
/// second are ignored), and windows less than 2.5s apart merge into one zoom.
func autoZooms(clicks: [Double], duration: Double,
               before: Double = 0.3, after: Double = 2.5, fillGap: Double = 2.5) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for t in clicks.sorted() where t < duration - 1 {
        let r = (max(t - before, 0.001), min(t + after, duration - 0.8))
        guard r.0 < r.1 else { continue }
        if let last = out.last, last.1 + fillGap >= r.0 {
            out[out.count - 1].1 = max(last.1, r.1)
        } else {
            out.append(r)
        }
    }
    return out
}

struct MoveGroup { var start: Double; var x: Double; var y: Double }

/// Greedy groups of cursor samples whose bounding box fits in `span` of the screen.
/// The camera aims at each group's dwell-time-weighted centroid (as Screen Studio does).
func moveGroups(_ m: [MoveSample], span: Double = 0.5) -> [MoveGroup] {
    var out: [MoveGroup] = []
    var i = 0
    while i < m.count {
        var j = i
        var (x0, x1, y0, y1) = (m[i].x, m[i].x, m[i].y, m[i].y)
        while j + 1 < m.count {
            let p = m[j + 1]
            let b = (min(x0, p.x), max(x1, p.x), min(y0, p.y), max(y1, p.y))
            if b.1 - b.0 > span || b.3 - b.2 > span { break }
            (x0, x1, y0, y1) = b
            j += 1
        }
        let end = j + 1 < m.count ? m[j + 1].t : m[j].t + 1
        var (wx, wy, w) = (0.0, 0.0, 0.0)
        for k in i...j {
            let d = max((k < j ? m[k + 1].t : end) - m[k].t, 1e-3)
            wx += m[k].x * d; wy += m[k].y * d; w += d
        }
        out.append(MoveGroup(start: m[i].t, x: wx / w, y: wy / w))
        i = j + 1
    }
    return out
}

// MARK: - Springs and the precomputed camera/cursor timeline

/// Near-critical damping lets the camera settle without an abrupt target crossing.
struct Spring { var stiffness = 170.0, damping = 32.0, mass = 1.5 }

/// Small integration steps preserve velocity through direction changes.
func springStep(_ x: inout Double, _ v: inout Double, to target: Double, dt: Double, _ s: Spring = Spring()) {
    v += (-s.stiffness * (x - target) - s.damping * v) / s.mass * dt
    x += v * dt
}

/// Zero-lag cursor smoothing: a centered Gaussian over the whole path, possible because we edit after
/// recording. Measured on a real recording, any causal spring smooth enough to hide the 60 Hz steps
/// lagged 45–70 pt behind clicks (and the clamped one snapped on every direction change);
/// sigma 80 ms gives half the jerk with clicks landing within ~4 pt.
func smoothPath(_ p: [(x: Double, y: Double)], sigma: Double) -> [(x: Double, y: Double)] {
    let r = Int(3 * sigma)
    guard r > 0, !p.isEmpty else { return p }
    let w = (-r...r).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
    return p.indices.map { i in
        var (sx, sy, sw) = (0.0, 0.0, 0.0)
        for (k, wk) in zip(-r...r, w) {
            let q = p[min(max(i + k, 0), p.count - 1)]
            sx += q.x * wk; sy += q.y * wk; sw += wk
        }
        return (sx / sw, sy / sw)
    }
}

struct Camera: Equatable { var x = 0.5, y = 0.5, scale = 1.0 }

/// Camera and smoothed cursor sampled at a fixed rate over source time, so seeking is deterministic.
struct Timeline {
    static let fps = 60.0
    var camera: [Camera] = []
    var cursor: [(x: Double, y: Double)] = []
    func index(_ t: Double) -> Int { min(max(Int(t * Self.fps), 0), max(camera.count - 1, 0)) }

    // Evaluate between samples: slow-motion edits and fractional timestamps must not repeat frames.
    func camera(at t: Double) -> Camera {
        guard !camera.isEmpty else { return Camera() }
        let a = index(t), b = min(a + 1, camera.count - 1)
        let f = min(max(t * Self.fps - Double(a), 0), 1)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        return Camera(x: mix(camera[a].x, camera[b].x), y: mix(camera[a].y, camera[b].y),
                      scale: mix(camera[a].scale, camera[b].scale))
    }

    func cursor(at t: Double) -> (x: Double, y: Double) {
        guard !cursor.isEmpty else { return (0.5, 0.5) }
        let a = min(index(t), cursor.count - 1), b = min(a + 1, cursor.count - 1)
        let f = min(max(t * Self.fps - Double(a), 0), 1)
        return (cursor[a].x + (cursor[b].x - cursor[a].x) * f,
                cursor[a].y + (cursor[b].y - cursor[a].y) * f)
    }
}

extension Array {
    /// Index of the last element whose key is <= t (binary search; array sorted by key).
    func lastIndex(atOrBefore t: Double, _ key: (Element) -> Double) -> Int? {
        var lo = 0, hi = count
        while lo < hi { let m = (lo + hi) / 2; if key(self[m]) <= t { lo = m + 1 } else { hi = m } }
        return lo == 0 ? nil : lo - 1
    }
}

/// Cursor samples are recorded only on change at 60 Hz, so hold the last one (no interpolation).
func rawCursor(at t: Double, _ m: [MoveSample]) -> MoveSample? {
    m.lastIndex(atOrBefore: t, \.t).map { m[$0] }
}

func cursorPosition(at t: Double, _ moves: [MoveSample]) -> (x: Double, y: Double)? {
    guard let i = moves.lastIndex(atOrBefore: t, \.t) else {
        return moves.first.map { ($0.x, $0.y) }
    }
    let a = moves[i]
    guard i + 1 < moves.count else { return (a.x, a.y) }
    let b = moves[i + 1]
    // Changed-only recordings omit stationary samples. Interpolate only the final capture interval.
    let start = max(a.t, b.t - 1 / Timeline.fps)
    let f = min(max((t - start) / max(b.t - start, 0.000001), 0), 1)
    return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
}

/// Shared, deterministic animation envelope; zero opacity and velocity at both ends.
func clickPulse(age: Double) -> (radius: Double, opacity: Double, press: Double) {
    guard age >= 0, age < 0.55 else { return (0, 0, 0) }
    func ease(_ x: Double) -> Double {
        let q = min(max(x, 0), 1)
        return min(max(q * q * q * (q * (q * 6 - 15) + 10), 0), 1)
    }
    let q = age / 0.55
    let opacity = 0.30 * ease(age / 0.065) * (1 - ease((age - 0.065) / 0.485))
    let press = ease(age / 0.065) * (1 - ease((age - 0.065) / 0.22))
    return (10 + 24 * (1 - pow(1 - q, 3)), opacity, press)
}

func simulate(_ r: Recording, zooms: [Zoom]) -> Timeline {
    let fps = Timeline.fps, substeps = 4, dt = 1 / fps / Double(substeps)
    let groups = moveGroups(r.moves)
    let active = zooms.filter(\.enabled)
    var tl = Timeline()
    var cam = Camera(), cv = (0.0, 0.0, 0.0)
    var raw: [(x: Double, y: Double)] = []
    for i in 0...Int(r.duration * fps) {
        let t = Double(i) / fps
        let cur = cursorPosition(at: t, r.moves) ?? raw.last ?? (x: 0.5, y: 0.5)
        raw.append(cur)
        var target = Camera()
        if let z = active.last(where: { t >= $0.start && t <= $0.end }) {
            let g = groups.lastIndex(atOrBefore: t, \.start).map { groups[$0] }
            let h = 0.5 / z.scale
            target = Camera(x: min(max(z.focus?.x ?? g?.x ?? cur.x, h), 1 - h), y: min(max(z.focus?.y ?? g?.y ?? cur.y, h), 1 - h), scale: z.scale)
        }
        for _ in 0..<substeps {
            springStep(&cam.x, &cv.0, to: target.x, dt: dt)
            springStep(&cam.y, &cv.1, to: target.y, dt: dt)
            springStep(&cam.scale, &cv.2, to: target.scale, dt: dt)
        }
        // Keep the visible window inside the recorded frame.
        let h = 0.5 / cam.scale
        tl.camera.append(Camera(x: min(max(cam.x, h), 1 - h), y: min(max(cam.y, h), 1 - h), scale: cam.scale))
    }
    tl.cursor = smoothPath(raw, sigma: 0.08 * fps)
    return tl
}

// MARK: - Segment (cut/speed) time mapping

func outputDuration(_ segs: [Segment]) -> Double {
    segs.reduce(0) { $0 + ($1.end - $1.start) / $1.speed }
}

func sourceTime(atOutput t: Double, _ segs: [Segment]) -> Double {
    var acc = 0.0
    for s in segs {
        let len = (s.end - s.start) / s.speed
        if t < acc + len { return s.start + (t - acc) * s.speed }
        acc += len
    }
    return segs.last?.end ?? 0
}

/// Output time for a source time; a time inside a cut snaps to the next kept segment.
func outputTime(atSource t: Double, _ segs: [Segment]) -> Double {
    var acc = 0.0
    for s in segs {
        if t < s.start { return acc }
        if t <= s.end { return acc + (t - s.start) / s.speed }
        acc += (s.end - s.start) / s.speed
    }
    return acc
}

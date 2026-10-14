import AVFoundation
import SwiftUI

private struct TimelineThumbnail {
    let time: Double
    let image: NSImage
}

struct TimelineBar: View {
    let project: Project
    let folder: URL
    let duration: Double
    let zoom: Double
    let now: Double
    @Binding var selection: EditorView.Selection?
    let seek: (Double) -> Void
    let beginTrim: () -> Void
    let trim: (Segment) -> Void
    let editZoom: (Zoom) -> Void
    let deleteClip: (UUID) -> Void
    @State private var zoomDraft: Zoom?
    @State private var zoomOriginal: Zoom?
    @State private var thumbnails: [TimelineThumbnail] = []
    @State private var thumbnailError = false
    @State private var drag: TrimDrag?

    private struct TrimDrag {
        let original: Project
        let id: UUID
        let edge: TrimEdge
        let secondsPerPoint: Double
        var clip: Segment
    }

    var body: some View {
        GeometryReader { geo in
            let total = max(outputDuration(project.segments), 0.001)
            let width = max(geo.size.width, total * 24 * zoom)
            ScrollView(.horizontal) {
                tracks(width: width, total: total)
                    .frame(width: width, height: 112)
                    .coordinateSpace(name: "timeline")
            }
        }
        .task(id: folder) { await loadThumbnails() }
        .help(thumbnailError ? "Some thumbnails could not load. You can still select and trim clips." : "Drag either clip edge to trim. Scroll horizontally to navigate longer recordings.")
    }

    private func tracks(width: Double, total: Double) -> some View {
        let x = { (t: Double) in width * t / total }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(StudioTheme.canvas.opacity(0.6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    seek(min(max(g.location.x / width, 0), 1) * total)
                })
            // A stable ruler remains in place while the trim preview moves.
            let ticks = min(200, max(2, Int(width / 90)))
            ForEach(0...ticks, id: \.self) { tick in
                Text(timeString(total * Double(tick) / Double(ticks)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .offset(x: min(max(x(total * Double(tick) / Double(ticks)) - 22, 0), width - 44), y: 2)
                    .allowsHitTesting(false)
            }
            ForEach(clips) { c in
                clipView(c, width: width, total: total)
            }
            ForEach(project.zooms) { original in
                let z = zoomDraft?.id == original.id ? zoomDraft! : original
                let a = outputTime(atSource: z.start, project.segments)
                let b = outputTime(atSource: z.end, project.segments)
                let selected = selection == .zoom(z.id)
                if b - a > 0.01 {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(StudioTheme.accent.opacity(z.enabled ? (selected ? 0.52 : 0.26) : 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioTheme.accent.opacity(selected ? 1 : 0.35), lineWidth: selected ? 1.5 : 1))
                        .overlay(Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(z.enabled ? .white.opacity(0.9) : .white.opacity(0.4)))
                        .frame(width: max(x(b) - x(a) - 2, 4), height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = .zoom(z.id)
                            beginTrim()
                            seek(min(a + 0.5, (a + b) / 2))
                        }
                        .overlay {
                            if selected {
                                HStack(spacing: 0) {
                                    zoomHandle(original, edge: .start, width: width, total: total)
                                    Spacer(minLength: 0)
                                    zoomHandle(original, edge: .end, width: width, total: total)
                                }.frame(minWidth: 26)
                            }
                        }
                        .offset(x: x(a), y: 84)
                        .zIndex(selected ? 1 : 0)
                        .accessibilityLabel("Zoom \(z.scale.formatted()) times at \(timeString(a))")
                }
            }
            Rectangle().fill(Color.primary.opacity(0.85))
                .frame(width: 1.5, height: 112)
                .overlay(alignment: .top) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                }
                .offset(x: min(max(x(now), 0), width - 2))
                .zIndex(2)
                .allowsHitTesting(false)
        }
    }

    private func zoomHandle(_ value: Zoom, edge: TrimEdge, width: Double, total: Double) -> some View {
        Capsule().fill(.white.opacity(0.9)).frame(width: 3, height: 14)
            .frame(width: 12, height: 24).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { gesture in
                    if zoomOriginal == nil { beginTrim(); zoomOriginal = value }
                    guard let original = zoomOriginal else { return }
                    zoomDraft = resizedZoom(original, edge: edge,
                        outputDelta: gesture.translation.width * total / width,
                        segments: project.segments, duration: duration)
                }
                .onEnded { _ in
                    if let value = zoomDraft { editZoom(value) }
                    zoomDraft = nil; zoomOriginal = nil
                })
            .accessibilityLabel(edge == .start ? "Zoom start" : "Zoom end")
            .accessibilityAdjustableAction { direction in
                beginTrim()
                editZoom(resizedZoom(value, edge: edge, outputDelta: direction == .increment ? 0.1 : -0.1,
                                     segments: project.segments, duration: duration))
            }
    }

    private func clipView(_ c: Clip, width: Double, total: Double) -> some View {
        let value = drag?.id == c.id ? drag!.clip : c.segment
        let start = c.a + (value.start - c.segment.start) / c.segment.speed
        let clipWidth = max((value.end - value.start) / value.speed * width / total - 2, 4)
        let selected = selection == .segment(c.id)
        return ZStack {
            thumbnailStrip(value, width: clipWidth)
                .overlay(Color.black.opacity(selected ? 0.14 : 0.38))
                .overlay(alignment: .bottom) {
                    Text(drag?.id == c.id ? "\(timeString(value.start)) – \(timeString(value.end))" : "\(value.speed.formatted())×")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.bottom, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? StudioTheme.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = .segment(c.id)
                    seek(c.a)
                }
            if selected {
                HStack(spacing: 0) {
                    trimHandle(c, edge: .start, width: width, total: total)
                    Spacer(minLength: 0)
                    trimHandle(c, edge: .end, width: width, total: total)
                }
                .frame(width: max(clipWidth, 26))
            }
        }
        .frame(width: clipWidth, height: 56)
        .offset(x: start * width / total, y: 22)
        .zIndex(selected ? 1 : 0)
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Delete clip", role: .destructive) { deleteClip(c.id) }
                .disabled(project.segments.count < 2)
        }
        .accessibilityLabel("Clip from \(timeString(value.start)) to \(timeString(value.end))")
    }

    private func thumbnailStrip(_ clip: Segment, width: Double) -> some View {
        let count = min(32, max(1, Int(ceil(width / 90))))
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let sourceTime = clip.start + (clip.end - clip.start) * (Double(index) + 0.5) / Double(count)
                let image = thumbnails.min(by: { abs($0.time - sourceTime) < abs($1.time - sourceTime) })?.image
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        StudioTheme.accent.opacity(0.3)
                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                }
                .frame(width: width / Double(count), height: 56).clipped()
            }
        }
    }

    private func trimHandle(_ c: Clip, edge: TrimEdge, width: Double, total: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(StudioTheme.accent)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 20))
            .frame(width: 10, height: 52)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { g in
                    if drag == nil {
                        beginTrim()
                        drag = TrimDrag(original: project, id: c.id, edge: edge,
                                        secondsPerPoint: total / width, clip: c.segment)
                    }
                    guard let active = drag,
                          let updated = trimmedSegment(in: active.original, id: active.id, edge: active.edge,
                                                       outputDelta: g.translation.width * active.secondsPerPoint,
                                                       duration: duration) else { return }
                    drag?.clip = updated
                }
                .onEnded { _ in
                    if let active = drag { trim(active.clip) }
                    drag = nil
                })
            .help(edge == .start ? "Drag to trim clip start" : "Drag to trim clip end")
            .accessibilityLabel(edge == .start ? "Clip start" : "Clip end")
            .accessibilityValue(timeString(edge == .start ? c.segment.start : c.segment.end))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if let updated = trimmedSegment(in: project, id: c.id, edge: edge, outputDelta: delta, duration: duration) {
                    beginTrim()
                    trim(updated)
                }
            }
    }

    private struct Clip: Identifiable {
        let segment: Segment
        let a: Double
        var id: UUID { segment.id }
    }

    private var clips: [Clip] {
        var acc = 0.0
        return project.segments.map { segment in
            defer { acc += (segment.end - segment.start) / segment.speed }
            return Clip(segment: segment, a: acc)
        }
    }

    private func loadThumbnails() async {
        thumbnails = []
        thumbnailError = false
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: folder.appendingPathComponent("screen.mov")))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 150)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let count = min(120, max(12, Int(ceil(duration / 2))))
        for i in 0..<count {
            guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
            let t = duration * (Double(i) + 0.5) / Double(count)
            do {
                let (image, actualTime) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                guard !Task.isCancelled else { return }
                thumbnails.append(TimelineThumbnail(time: actualTime.seconds, image: NSImage(cgImage: image, size: .zero)))
            } catch {
                guard !Task.isCancelled else { return }
                thumbnailError = true
            }
        }
    }
}

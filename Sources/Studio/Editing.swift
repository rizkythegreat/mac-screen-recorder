import Foundation

/// Session-local snapshots. A continuous slider gesture is one reversible edit.
struct ProjectHistory {
    private(set) var current: Project?
    private(set) var past: [Project] = []
    private(set) var future: [Project] = []
    private var gestureStart: Project?
    var isEditing: Bool { gestureStart != nil }
    var canUndo: Bool { !past.isEmpty && !isEditing }
    var canRedo: Bool { !future.isEmpty && !isEditing }

    mutating func reset(_ project: Project) {
        current = project
        past = []; future = []; gestureStart = nil
    }

    mutating func record(_ project: Project) {
        guard let previous = current else { reset(project); return }
        guard previous != project else { return }
        if !isEditing {
            past.append(previous)
            if past.count > 100 { past.removeFirst() }
            future.removeAll()
        }
        current = project
    }

    mutating func begin(_ project: Project) {
        guard !isEditing else { return }
        record(project)
        gestureStart = project
    }

    mutating func end(_ project: Project) {
        guard let start = gestureStart else { record(project); return }
        gestureStart = nil
        current = start
        record(project)
    }

    mutating func undo() -> Project? {
        guard canUndo, let previous = past.popLast(), let current else { return nil }
        future.append(current)
        self.current = previous
        return previous
    }

    mutating func redo() -> Project? {
        guard canRedo, let next = future.popLast(), let current else { return nil }
        past.append(current)
        self.current = next
        return next
    }
}

enum TrimEdge { case start, end }

/// Delta is in output seconds; source bounds account for speed and adjacent clips.
/// Trimming is nondestructive, and can reveal previously trimmed footage again.
func trimmedSegment(in project: Project, id: UUID, edge: TrimEdge,
                    outputDelta: Double, duration: Double) -> Segment? {
    guard outputDelta.isFinite, let i = project.segments.firstIndex(where: { $0.id == id }) else { return nil }
    var clip = project.segments[i]
    let minimum = min(clip.end - clip.start, max(0.05, clip.speed / 60))
    let lower = i > 0 ? project.segments[i - 1].end : 0
    let upper = i + 1 < project.segments.count ? project.segments[i + 1].start : duration
    switch edge {
    case .start:
        clip.start = min(max(clip.start + outputDelta * clip.speed, lower), clip.end - minimum)
    case .end:
        clip.end = max(min(clip.end + outputDelta * clip.speed, upper), clip.start + minimum)
    }
    return clip
}

func resizedZoom(_ zoom: Zoom, edge: TrimEdge, outputDelta: Double,
                 segments: [Segment], duration: Double) -> Zoom {
    var result = zoom
    let original = edge == .start ? zoom.start : zoom.end
    let output = min(max(outputTime(atSource: original, segments) + outputDelta, 0), outputDuration(segments))
    let source = sourceTime(atOutput: output, segments)
    if edge == .start {
        result.start = min(max(source, 0), max(zoom.end - 0.2, 0))
    } else {
        result.end = min(max(source, zoom.start + 0.2), duration)
    }
    return result
}

/// Ripple-delete one clip, preserving the source position of the playhead when possible.
func deletingSegment(in project: Project, id: UUID, playhead: Double) -> (project: Project, playhead: Double)? {
    guard project.segments.count > 1,
          let index = project.segments.firstIndex(where: { $0.id == id }) else { return nil }
    let start = outputDuration(Array(project.segments.prefix(index)))
    let length = outputDuration([project.segments[index]])
    let position = playhead < start ? playhead : (playhead < start + length ? start : playhead - length)
    var edited = project
    edited.segments.remove(at: index)
    return (edited, min(max(position, 0), outputDuration(edited.segments)))
}

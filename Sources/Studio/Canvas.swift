import Foundation
import CoreGraphics

enum CanvasFormat: String, Codable, CaseIterable, Identifiable {
    case landscape, portrait, square
    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape: return "Landscape · 16:9"
        case .portrait: return "Portrait · 9:16"
        case .square: return "Square · 1:1"
        }
    }
    var aspectRatio: Double {
        switch self {
        case .landscape: return 16 / 9
        case .portrait: return 9 / 16
        case .square: return 1
        }
    }
    /// Quality is the short edge: Full HD is 1920×1080, 1080×1920, or 1080×1080.
    func size(shortEdge: Double) -> CGSize {
        let edge = max(2, (shortEdge / 2).rounded() * 2)
        let long = (edge * 16 / 9 / 2).rounded() * 2
        switch self {
        case .landscape: return CGSize(width: long, height: edge)
        case .portrait: return CGSize(width: edge, height: long)
        case .square: return CGSize(width: edge, height: edge)
        }
    }
}

enum ContentFit: String, Codable, CaseIterable {
    case fit, fill
    var title: String { self == .fit ? "Fit" : "Fill" }
}

struct ContentPlacement: Codable, Equatable {
    var fit: ContentFit = .fit
    var horizontal = 0.5
    var vertical = 0.5 // 0 = top, 1 = bottom
}

struct CanvasSettings: Codable, Equatable {
    var format: CanvasFormat = .landscape
    var landscape = ContentPlacement()
    var portrait = ContentPlacement()
    var square = ContentPlacement()
    var placement: ContentPlacement {
        get {
            switch format {
            case .landscape: return landscape
            case .portrait: return portrait
            case .square: return square
            }
        }
        set {
            switch format {
            case .landscape: landscape = newValue
            case .portrait: portrait = newValue
            case .square: square = newValue
            }
        }
    }
}

struct ContentGeometry {
    let viewport: CGRect
    let image: CGRect
    let visible: CGRect
}

/// One mapping for the screen, cursor, and click effects; both preview and export use it.
/// Rectangles use Core Image's bottom-left origin, while UI positioning uses a top-left origin.
func contentGeometry(source: CGSize, canvas: CGSize, padding: Double, placement: ContentPlacement) -> ContentGeometry {
    let pad = min(max(padding, 0), 0.45) * min(canvas.width, canvas.height)
    let viewport = CGRect(origin: .zero, size: canvas).insetBy(dx: pad, dy: pad)
    let sx = viewport.width / max(source.width, 1), sy = viewport.height / max(source.height, 1)
    let scale = placement.fit == .fit ? min(sx, sy) : max(sx, sy)
    let width = source.width * scale, height = source.height * scale
    let x = min(max(placement.horizontal, 0), 1), y = min(max(placement.vertical, 0), 1)
    let image = CGRect(x: viewport.minX + (viewport.width - width) * x,
                       y: viewport.minY + (viewport.height - height) * (1 - y), width: width, height: height)
    return ContentGeometry(viewport: viewport, image: image, visible: image.intersection(viewport))
}

/// Focus picking uses an unzoomed frame, in SwiftUI's top-left coordinates.
func focusAtPreviewPoint(_ point: CGPoint, size: CGSize, recording: Recording, project: Project) -> ZoomFocus? {
    let layout = contentGeometry(source: CGSize(width: recording.displayWidth, height: recording.displayHeight),
                                 canvas: size, padding: project.style.padding,
                                 placement: project.resolvedCanvas.placement)
    let flipped = CGPoint(x: point.x, y: size.height - point.y)
    guard layout.visible.contains(flipped), layout.image.width > 0, layout.image.height > 0 else { return nil }
    return ZoomFocus(x: (flipped.x - layout.image.minX) / layout.image.width,
                     y: (layout.image.maxY - flipped.y) / layout.image.height)
}

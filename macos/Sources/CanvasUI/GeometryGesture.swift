import CanvasCore
import Foundation

/// One cancellable transaction, even when Tab changes handles before commit.
struct GeometryGesture {
    let id: String
    let before: CanvasGeometry
    private(set) var current: CanvasGeometry
    private(set) var handle: CanvasGeometryHandle = .bottomRight
    private(set) var pointerStart: CanvasPosition?
    private var pointerBase: CanvasGeometry
    private var lastAngle: Double = 0
    private var rotationDelta: Double = 0

    init(id: String, geometry: CanvasGeometry) {
        self.id = id
        before = geometry
        current = geometry
        pointerBase = geometry
    }

    mutating func startPointer(at point: CanvasPosition, handle: CanvasGeometryHandle) {
        self.handle = handle
        pointerStart = point
        pointerBase = current
        lastAngle = atan2(point.y - current.y - current.height / 2,
                          point.x - current.x - current.width / 2)
        rotationDelta = 0
    }

    mutating func drag(to point: CanvasPosition) throws {
        guard let pointerStart else { return }
        let candidate: CanvasGeometry
        if handle == .rotation {
            let dx = point.x - pointerBase.x - pointerBase.width / 2
            let dy = point.y - pointerBase.y - pointerBase.height / 2
            guard hypot(dx, dy) >= 0.5 else { return }
            let angle = atan2(dy, dx)
            var change = angle - lastAngle
            if change > .pi { change -= 2 * .pi }
            if change < -.pi { change += 2 * .pi }
            let delta = rotationDelta + change
            let degrees = abs(delta) < 1e-10 ? 0 : delta * 180 / .pi
            candidate = pointerBase.rotated(by: degrees)
            try candidate.validate()
            rotationDelta = delta
            lastAngle = angle
        } else {
            let delta = pointerBase.localDelta(from: CanvasPosition(
                x: point.x - pointerStart.x, y: point.y - pointerStart.y))
            candidate = pointerBase.resized(handle: handle, localDelta: delta)
            try candidate.validate()
        }
        current = candidate
    }

    mutating func cycle(backwards: Bool) {
        let count = CanvasGeometryHandle.allCases.count
        handle = CanvasGeometryHandle(rawValue: (handle.rawValue + (backwards ? count - 1 : 1)) % count)!
        pointerStart = nil
    }

    mutating func nudge(x: Double, y: Double, accelerated: Bool) throws {
        let candidate: CanvasGeometry
        if handle == .rotation {
            candidate = current.rotated(by: (x + y) * (accelerated ? 15 : 1))
        } else {
            let step = accelerated ? 10.0 : 1.0
            candidate = current.resized(handle: handle, localDelta: CanvasPosition(x: x * step, y: y * step))
        }
        try candidate.validate()
        current = candidate
    }
}

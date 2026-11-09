import Foundation

public enum CanvasGeometryHandle: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotation

    public var unit: CanvasPosition {
        switch self {
        case .topLeft: return CanvasPosition(x: -0.5, y: -0.5)
        case .top: return CanvasPosition(x: 0, y: -0.5)
        case .topRight: return CanvasPosition(x: 0.5, y: -0.5)
        case .right: return CanvasPosition(x: 0.5, y: 0)
        case .bottomRight: return CanvasPosition(x: 0.5, y: 0.5)
        case .bottom: return CanvasPosition(x: 0, y: 0.5)
        case .bottomLeft: return CanvasPosition(x: -0.5, y: 0.5)
        case .left: return CanvasPosition(x: -0.5, y: 0)
        case .rotation: return CanvasPosition(x: 0, y: -0.5)
        }
    }
}

public enum CanvasThoughtDirection: String, CaseIterable, Sendable {
    case up, right, down, left
}

/// Authored box plus optional rotation. Nil retains an omitted rotation field.
public struct CanvasGeometry: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let rotation: Double?

    public init(x: Double, y: Double, width: Double, height: Double, rotation: Double? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              width > 0, height > 0, width <= 1_000_000, height <= 1_000_000,
              rotation == nil || (rotation!.isFinite && abs(rotation!) <= 1_000_000) else {
            throw CanvasDocumentError("Geometry needs finite coordinates/rotation and positive dimensions within 1000000.")
        }
    }

    public func point(for handle: CanvasGeometryHandle) -> CanvasPosition {
        let unit = handle.unit
        let localX = unit.x * width
        let localY = unit.y * height - (handle == .rotation ? 28 : 0)
        let angle = (rotation ?? 0) * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        return CanvasPosition(x: x + width / 2 + localX * cosine - localY * sine,
                              y: y + height / 2 + localX * sine + localY * cosine)
    }

    public func localDelta(from world: CanvasPosition) -> CanvasPosition {
        let angle = (rotation ?? 0) * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        return CanvasPosition(x: world.x * cosine + world.y * sine,
                              y: -world.x * sine + world.y * cosine)
    }

    /// The opposite corner/side remains fixed in world space; crossing clamps, never flips.
    public func resized(handle: CanvasGeometryHandle, localDelta: CanvasPosition) -> CanvasGeometry {
        guard handle != .rotation else { return self }
        let unit = handle.unit
        let newWidth = unit.x == 0 ? width : max(min(1, width), width + unit.x * 2 * localDelta.x)
        let newHeight = unit.y == 0 ? height : max(min(1, height), height + unit.y * 2 * localDelta.y)
        guard newWidth != width || newHeight != height else { return self }
        let shiftX = unit.x * (newWidth - width)
        let shiftY = unit.y * (newHeight - height)
        let angle = (rotation ?? 0) * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        let centerX = x + width / 2 + shiftX * cosine - shiftY * sine
        let centerY = y + height / 2 + shiftX * sine + shiftY * cosine
        return CanvasGeometry(x: centerX - newWidth / 2, y: centerY - newHeight / 2,
                              width: newWidth, height: newHeight, rotation: rotation)
    }

    public func rotated(by degrees: Double) -> CanvasGeometry {
        guard degrees != 0 else { return self }
        return CanvasGeometry(x: x, y: y, width: width, height: height,
                              rotation: (rotation ?? 0) + degrees)
    }

    /// Axis-aligned world bounding box of the rotated geometry.
    public var rotatedAxisAlignedBounds: (x: Double, y: Double, width: Double, height: Double) {
        let angle = (rotation ?? 0) * .pi / 180
        let w = abs(cos(angle)) * width + abs(sin(angle)) * height
        let h = abs(sin(angle)) * width + abs(cos(angle)) * height
        return (x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }

    /// Places a fresh upright 160x96-minimum rectangle 48 world units beyond the source's
    /// rotated bounds along `direction`, skipping any ray blockers (and their 48-unit clearance).
    public static func adjacentThoughtBox(
        source: CanvasGeometry,
        obstacles: [CanvasGeometry],
        direction: CanvasThoughtDirection,
        height: Double = 96
    ) -> CanvasGeometry {
        let width = 160.0
        let resolvedHeight = max(96.0, height)
        let gap = 48.0
        let origin = source.rotatedAxisAlignedBounds
        let horizontal = direction == .left || direction == .right
        let forward = direction == .right || direction == .down
        var boxX = source.x + (source.width - width) / 2
        var boxY = source.y + (source.height - resolvedHeight) / 2
        if horizontal {
            boxY = floor(boxY * 10 + 0.5) / 10
            boxX = forward ? (origin.x + origin.width + gap) : (origin.x - width - gap)
        } else {
            boxX = floor(boxX * 10 + 0.5) / 10
            boxY = forward ? (origin.y + origin.height + gap) : (origin.y - resolvedHeight - gap)
        }
        let blockers = obstacles.map(\.rotatedAxisAlignedBounds).filter { other in
            if horizontal {
                return boxY < other.y + other.height + gap && boxY + resolvedHeight + gap > other.y
            } else {
                return boxX < other.x + other.width + gap && boxX + width + gap > other.x
            }
        }
        for _ in 0...blockers.count {
            let overlaps = blockers.filter { other in
                if horizontal {
                    return boxX < other.x + other.width + gap && boxX + width + gap > other.x
                } else {
                    return boxY < other.y + other.height + gap && boxY + resolvedHeight + gap > other.y
                }
            }
            if overlaps.isEmpty { break }
            if horizontal {
                boxX = forward
                    ? overlaps.map { $0.x + $0.width + gap }.max()!
                    : overlaps.map { $0.x - width - gap }.min()!
            } else {
                boxY = forward
                    ? overlaps.map { $0.y + $0.height + gap }.max()!
                    : overlaps.map { $0.y - resolvedHeight - gap }.min()!
            }
        }
        if horizontal {
            boxX = (forward ? ceil(boxX * 10) : floor(boxX * 10)) / 10
        } else {
            boxY = (forward ? ceil(boxY * 10) : floor(boxY * 10)) / 10
        }
        return CanvasGeometry(x: boxX, y: boxY, width: width, height: resolvedHeight, rotation: nil)
    }
}

public enum CanvasLineEndpoint: Int, CaseIterable, Sendable {
    case start, end
}

/// Authored bounding box, relative endpoints, and optional rotation for a standalone line.
public struct CanvasLineGeometry: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let from: CanvasPosition
    public let to: CanvasPosition
    public let rotation: Double?

    public init(
        x: Double, y: Double, width: Double, height: Double,
        from: CanvasPosition, to: CanvasPosition, rotation: Double? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.from = from
        self.to = to
        self.rotation = rotation
    }

    /// Creates a canonical 12-unit padded line box from two world endpoints.
    public init(start: CanvasPosition, end: CanvasPosition) {
        let minX = min(start.x, end.x) - 12
        let minY = min(start.y, end.y) - 12
        self.x = minX
        self.y = minY
        self.width = abs(end.x - start.x) + 24
        self.height = abs(end.y - start.y) + 24
        self.from = CanvasPosition(x: start.x - minX, y: start.y - minY)
        self.to = CanvasPosition(x: end.x - minX, y: end.y - minY)
        self.rotation = nil
    }

    public func validate() throws {
        let start = point(for: .start)
        let end = point(for: .end)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite,
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              width > 0, height > 0, width <= 1_000_000, height <= 1_000_000,
              abs(from.x) <= 1_000_000, abs(from.y) <= 1_000_000,
              abs(to.x) <= 1_000_000, abs(to.y) <= 1_000_000,
              abs(start.x) <= 1_000_000, abs(start.y) <= 1_000_000,
              abs(end.x) <= 1_000_000, abs(end.y) <= 1_000_000,
              rotation == nil || (rotation!.isFinite && abs(rotation!) <= 1_000_000) else {
            throw CanvasDocumentError("Line geometry needs finite coordinates/endpoints and positive dimensions within 1000000.")
        }
    }

    public func point(for endpoint: CanvasLineEndpoint) -> CanvasPosition {
        let rel = endpoint == .start ? from : to
        let localX = x + rel.x
        let localY = y + rel.y
        guard let rotation, rotation != 0 else {
            return CanvasPosition(x: localX, y: localY)
        }
        let centerX = x + width / 2
        let centerY = y + height / 2
        let dx = localX - centerX
        let dy = localY - centerY
        let angle = rotation * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        return CanvasPosition(
            x: centerX + dx * cosine - dy * sine,
            y: centerY + dx * sine + dy * cosine
        )
    }

    public func moving(_ endpoint: CanvasLineEndpoint, by delta: CanvasPosition) -> CanvasLineGeometry {
        guard delta.x != 0 || delta.y != 0 else { return self }
        var start = point(for: .start)
        var end = point(for: .end)
        switch endpoint {
        case .start:
            start = CanvasPosition(x: start.x + delta.x, y: start.y + delta.y)
        case .end:
            end = CanvasPosition(x: end.x + delta.x, y: end.y + delta.y)
        }
        return CanvasLineGeometry(start: start, end: end)
    }
}

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
}

import Foundation
import CoreFoundation

/// A validated, read-only canvas. The original JSON bytes are never rewritten.
public final class CanvasDocument {
    public let root: [String: Any]
    public let originalData: Data

    /// A new source-less version-2 canvas. No file is created.
    public static func blank() throws -> CanvasDocument {
        try CanvasDocument(data: Data(#"{"version":2,"nodes":[],"edges":[]}"#.utf8))
    }

    /// Validates an in-memory canvas root dictionary against all v1/v2 schema and quota rules.
    public static func validate(_ root: [String: Any]) throws {
        try Validator.validate(root)
    }

    /// Serializes and re-validates a canvas root object as portable UTF-8 JSON.
    public static func encode(_ root: [String: Any]) throws -> Data {
        try Validator.validate(root)
        let data: Data
        do {
            data = try CanvasJSON.encode(root)
        } catch {
            throw CanvasDocumentError("Invalid JSON: \(error.localizedDescription)")
        }
        _ = try CanvasDocument(data: data)
        return data
    }

    public init(data: Data) throws {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw CanvasDocumentError("Canvas JSON must be UTF-8.")
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CanvasDocumentError("Invalid JSON: \(error.localizedDescription)")
        }
        guard let root = decoded as? [String: Any] else {
            throw CanvasDocumentError("A canvas must be a JSON object.")
        }
        try Validator.validate(root)
        // Keep raw numeric-token refusal semantics, then preserve literal strings.
        // Revalidate restored strings so BOM bytes/graphemes count toward quotas.
        let preserved: [String: Any]
        do {
            guard let object = try JSONDecoder().decode(CanvasJSON.self, from: data).value as? [String: Any] else {
                throw CanvasDocumentError("A canvas must be a JSON object.")
            }
            preserved = object
        } catch {
            throw CanvasDocumentError("Invalid JSON: \(error.localizedDescription)")
        }
        try Validator.validate(preserved)
        self.root = preserved
        self.originalData = data
    }
}

public struct CanvasDocumentError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

private enum Validator {
    static let colors = ["none", "ink", "gray", "blue", "green", "yellow", "red", "violet", "accent", "surface"]
    static let fonts = ["sans", "heading", "mono", "handwritten"]
    static let limit = 262_144
    static let totalLimit = 1_048_576

    static func fail(_ message: String) throws -> Never { throw CanvasDocumentError(message) }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) else { return nil }
        return Int(exactly: n.int64Value)
    }
    static func bool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    static func optionalString(_ value: Any?) -> Bool { value == nil || value is NSNull || value is String }
    static func supported(_ object: [String: Any], _ key: String, _ values: [String], _ context: String) throws {
        if let value = object[key], !(value is String && values.contains(value as! String)) {
            try fail("\(context) has unsupported \(key).")
        }
    }
    static func style(_ data: [String: Any], _ context: String) throws {
        for key in ["fill", "stroke"] { try supported(data, key, colors, context) }
        try supported(data, "size", ["s", "m", "l"], context)
        try supported(data, "align", ["left", "center", "right"], context)
        try supported(data, "arrow", ["end", "both", "none"], context)
        for (key, values) in [("width", [1, 2, 4]), ("radius", [0, 8])] {
            if let value = data[key], !values.contains(integer(value) ?? -1) { try fail("\(context) has unsupported \(key).") }
        }
        if let value = data["dash"], !bool(value) { try fail("\(context) dash must be boolean.") }
        if let value = data["rotation"], abs(number(value) ?? .infinity) > 1_000_000 { try fail("\(context) rotation must be finite and within 1000000 degrees.") }
    }
    static func textBytes(_ value: Any?, _ context: String) throws -> Int {
        guard let text = value as? String else { try fail("\(context) must be UTF-8 text.") }
        let count = text.utf8.count
        guard count <= limit else { try fail("\(context) exceeds 262144 UTF-8 bytes.") }
        for scalar in text.unicodeScalars {
            let n = scalar.value
            if (n < 32 && n != 9 && n != 10 && n != 13) || (n >= 127 && n <= 159) {
                try fail("\(context) contains a forbidden control character.")
            }
        }
        return count
    }
    static func attachment(_ value: Any?, _ context: String) throws -> Int {
        guard let attachment = value as? [String: Any], let filename = attachment["filename"] as? String,
              !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              filename != ".", filename != "..", filename.utf8.count <= 255,
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            try fail("\(context) needs a valid attachment filename (a basename of at most 255 UTF-8 bytes).")
        }
        guard let media = attachment["media_type"] as? String, ["text/plain", "text/markdown"].contains(media),
              attachment["encoding"] as? String == "utf-8" else { try fail("\(context) has an unsupported attachment media type or encoding.") }
        return try textBytes(attachment["content"], "\(context) attachment content")
    }
    static func validate(_ root: [String: Any]) throws {
        guard let version = integer(root["version"]), version == 1 || version == 2 else {
            try fail("Unsupported or missing canvas version; expected integer 1 or 2.")
        }
        guard let nodes = root["nodes"] as? [Any], let edges = root["edges"] as? [Any] else {
            try fail("A canvas requires nodes and edges arrays.")
        }
        if let appearance = root["appearance"] {
            guard let appearance = appearance as? [String: Any] else { try fail("Appearance must be an object.") }
            try supported(appearance, "font", fonts, "Appearance")
            try supported(appearance, "align", ["left", "center", "right"], "Appearance")
        }
        if let paper = root["paper"], !(paper is NSNull) {
            guard let paper = paper as? [String: Any] else { try fail("Paper must be an object.") }
            try supported(paper, "background", ["dots", "lines", "cross", "none"], "Paper")
            if let grid = paper["grid"], !(4...200).contains(integer(grid) ?? -1) { try fail("Paper grid must be an integer from 4 to 200.") }
        }
        var ids = Set<String>()
        var attachmentTotal = 0
        var codeTotal = 0
        for (index, item) in nodes.enumerated() {
            guard let node = item as? [String: Any], let id = node["id"] as? String, !id.isEmpty,
                  let type = node["type"] as? String, ["shape", "shape-line", "code"].contains(type),
                  let data = node["data"] as? [String: Any] else {
                try fail("Node \(index + 1) needs a nonempty ID, supported type, and data object.")
            }
            guard ids.insert(id).inserted else { try fail("Duplicate node ID: \(id).") }
            let context = "Node \(id)"
            for key in ["x", "y", "width", "height"] {
                guard let value = number(node[key]), abs(value) <= 1_000_000,
                      (key != "width" && key != "height") || value > 0 else {
                    try fail("\(context) needs finite coordinates and positive dimensions within 1000000.")
                }
            }
            if let locked = node["locked"], !bool(locked) { try fail("\(context) locked must be boolean.") }
            if let parent = node["parent"], !(parent is NSNull) { try fail("\(context) uses an unsupported parent/group.") }
            try style(data, context)
            if type == "shape" {
                guard let kind = data["kind"] as? String, ["rect", "ellipse", "diamond", "triangle", "text"].contains(kind) else { try fail("\(context) has an unsupported shape kind.") }
                if let text = data["text"], (!(text is String) || ((text as? String)?.count ?? 0) > 2_000) { try fail("\(context) text must be a string of at most 2000 characters.") }
                try supported(data, "font", fonts, context)
            } else if type == "shape-line" {
                for key in ["from", "to"] {
                    guard let point = data[key] as? [Any], point.count == 2,
                          let x = number(point[0]), let y = number(point[1]),
                          abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { try fail("\(context) needs finite from and to coordinates within 1000000.") }
                }
                if data["font"] != nil { try fail("\(context) cannot have a font.") }
            } else {
                guard version == 2 else { try fail("Code nodes require canvas version 2.") }
                if let language = data["language"], ((language as? String)?.isEmpty ?? true) { try fail("\(context) language must be a nonempty string.") }
                codeTotal += try textBytes(data["content"], "\(context) code source")
                if codeTotal > totalLimit { try fail("Code sources exceed the 1048576-byte canvas limit.") }
            }
            if let value = data["attachment"] {
                guard type == "shape" else { try fail("\(context): attachments belong to shape nodes.") }
                attachmentTotal += try attachment(value, context)
                if attachmentTotal > totalLimit { try fail("Attachments exceed the 1048576-byte canvas limit.") }
            }
        }
        var edgeIDs = Set<String>()
        for (index, item) in edges.enumerated() {
            guard let edge = item as? [String: Any], let id = edge["id"] as? String, !id.isEmpty,
                  let source = edge["source"] as? String, !source.isEmpty,
                  let target = edge["target"] as? String, !target.isEmpty else { try fail("Connector \(index + 1) needs nonempty ID, source, and target strings.") }
            for key in ["source_handle", "target_handle"] {
                if let value = edge[key], !(value is NSNull),
                   (!(value is String) || !["top", "right", "bottom", "left"].contains(value as? String ?? "")) {
                    try fail("Connector \(id) has an unsupported \(key).")
                }
            }
            if source == target {
                guard let from = edge["source_handle"] as? String,
                      let to = edge["target_handle"] as? String, from != to else {
                    try fail("Connector \(id) self-loop needs two distinct named side handles.")
                }
            }
            guard edgeIDs.insert(id).inserted else { try fail("Duplicate connector ID: \(id).") }
            guard ids.contains(source), ids.contains(target) else { try fail("Connector \(id) references a missing node.") }
            for key in ["source_handle", "target_handle", "label"] where !optionalString(edge[key]) { try fail("Connector \(id) has invalid \(key).") }
            if let animated = edge["animated"], !bool(animated) { try fail("Connector \(id) animated must be boolean.") }
            if let data = edge["data"], !(data is [String: Any]) { try fail("Connector \(id) data must be an object.") }
            try supported(edge, "path", ["bezier", "smooth", "step", "straight"], "Connector \(id)")
            try supported(edge, "marker", ["arrow", "dot", "none"], "Connector \(id)")
        }
    }
}

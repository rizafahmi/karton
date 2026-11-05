import CanvasCore
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

func encoded(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
}

func shape(_ id: String) -> [String: Any] {
    ["id": id, "type": "shape", "x": 0, "y": 0, "width": 100, "height": 50,
     "data": ["kind": "rect", "text": "hello"]]
}

func code(_ id: String, _ source: String) -> [String: Any] {
    ["id": id, "type": "code", "x": 0, "y": 0, "width": 100, "height": 50,
     "data": ["content": source]]
}

func canvas(_ nodes: [[String: Any]], edges: [[String: Any]] = [], version: Int = 2) -> [String: Any] {
    ["version": version, "nodes": nodes, "edges": edges]
}

func rejects(_ object: Any, mentioning expected: String) throws {
    let bytes = try encoded(object)
    do {
        _ = try CanvasDocument(data: bytes)
        throw CheckFailure(description: "Accepted invalid canvas: \(expected)")
    } catch let error as CanvasDocumentError {
        try require(error.localizedDescription.localizedCaseInsensitiveContains(expected), "Unexpected refusal for \(expected): \(error)")
    }
}

func runChecks() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for path in ["v1/document.json", "v1/compatibility.json", "v2/document.json", "v2/code-compatibility.json"] {
        let bytes = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/\(path)"))
        let document = try CanvasDocument(data: bytes)
        try require(document.originalData == bytes, "Original bytes changed: \(path)")
        try require(document.root["nodes"] is [Any], "Missing fixture nodes: \(path)")
        print("PASS fixture \(path): original bytes retained")
    }

    let malformed = Data("{".utf8)
    do {
        _ = try CanvasDocument(data: malformed)
        throw CheckFailure(description: "Accepted malformed JSON")
    } catch is CanvasDocumentError {}
    try rejects([1, 2], mentioning: "object")
    try rejects(["version": 3, "nodes": [], "edges": []], mentioning: "version")
    try rejects(["version": true, "nodes": [], "edges": []], mentioning: "version")
    try rejects(["nodes": [], "edges": []], mentioning: "version")
    var unknown = shape("n"); unknown["type"] = "future"
    try rejects(canvas([unknown]), mentioning: "type")
    try rejects(canvas([code("c", "")], version: 1), mentioning: "version 2")
    var invalid = shape("n"); invalid["width"] = 0
    try rejects(canvas([invalid]), mentioning: "dimensions")
    invalid = shape("n"); invalid["x"] = true
    try rejects(canvas([invalid]), mentioning: "coordinates")
    invalid = shape("n"); invalid["data"] = ["kind": "star"]
    try rejects(canvas([invalid]), mentioning: "kind")
    try rejects(canvas([shape("n"), shape("n")]), mentioning: "duplicate node")
    try rejects(canvas([shape("n")], edges: [["id": "e", "source": "n", "target": "missing"]]), mentioning: "missing node")
    let edge: [String: Any] = ["id": "e", "source": "n", "target": "m"]
    try rejects(canvas([shape("n"), shape("m")], edges: [edge, edge]), mentioning: "duplicate connector")
    var badHandle = edge; badHandle["source_handle"] = "future"
    try rejects(canvas([shape("n"), shape("m")], edges: [badHandle]), mentioning: "handle")
    try rejects(canvas([shape("n")], edges: [["id": "loop", "source": "n", "target": "n"]]), mentioning: "self-loop")
    print("PASS malformed, unsupported and inconsistent documents refused")

    let maximum = String(repeating: "x", count: 262_144)
    _ = try CanvasDocument(data: encoded(canvas((0..<4).map { code("c\($0)", maximum) })))
    try rejects(canvas([code("c", maximum + "x")]), mentioning: "262144")
    try rejects(canvas((0..<4).map { code("c\($0)", maximum) } + [code("extra", "x")]), mentioning: "1048576")
    try rejects(canvas([code("c", "bad\u{0}source")]), mentioning: "control")
    var badLanguage = code("c", ""); badLanguage["data"] = ["content": "", "language": ""]
    try rejects(canvas([badLanguage]), mentioning: "language")
    func attached(_ id: String, _ text: String) -> [String: Any] {
        var node = shape(id)
        node["data"] = ["kind": "rect", "attachment": ["filename": "a.txt", "media_type": "text/plain", "encoding": "utf-8", "content": text]]
        return node
    }
    _ = try CanvasDocument(data: encoded(canvas((0..<4).map { attached("a\($0)", maximum) })))
    try rejects(canvas([attached("a", maximum + "x")]), mentioning: "262144")
    try rejects(canvas((0..<4).map { attached("a\($0)", maximum) } + [attached("extra", "x")]), mentioning: "1048576")
    try rejects(canvas([attached("a", "\u{7f}")]), mentioning: "control")
    print("PASS code and attachment byte limits and control restrictions")
}

do {
    try runChecks()
    print("All native document checks passed.")
} catch {
    fputs("Native document check failed: \(error)\n", stderr)
    exit(1)
}

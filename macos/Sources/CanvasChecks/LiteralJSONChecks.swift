import AppKit
import CanvasCore
import CanvasUI
import Foundation

func checkLiteralJSON() throws {
    let literal = "\u{feff}\u{feff}<literal>\r\nCafe\u{301}\n👩🏽‍💻\r"
    var object = canvas([code("literal", literal)])
    let integer: Int64 = 9_007_199_254_740_993
    object["metadata"] = ["\u{feff}key": "\u{feff}value", "integer": NSNumber(value: integer),
                          "fraction": 1.25, "flag": true, "null": NSNull()]
    let bytes = try encoded(object)
    let document = try CanvasDocument(data: bytes)
    let data = ((document.root["nodes"] as! [[String: Any]])[0]["data"] as! [String: Any])
    try require((data["content"] as! String).utf8.elementsEqual(literal.utf8),
                "Native JSON decoding lost BOM, line endings or literal Unicode source")
    let metadata = document.root["metadata"] as! [String: Any]
    try require((metadata["\u{feff}key"] as? String)?.utf8.elementsEqual("\u{feff}value".utf8) == true,
                "Native JSON decoding changed unknown string keys/values")
    try require((metadata["integer"] as? NSNumber)?.int64Value == integer &&
                (metadata["fraction"] as? NSNumber)?.doubleValue == 1.25 &&
                metadata["flag"] as? Bool == true && metadata["null"] is NSNull,
                "Literal string decoding changed other JSON value types/precision")
    try require(document.originalData == bytes, "Literal decoding changed original bytes")

    let maximum = "\u{feff}" + String(repeating: "x", count: 262_141)
    let maximumDocument = try CanvasDocument(data: encoded(canvas([code("maximum", maximum)])))
    let maximumData = ((maximumDocument.root["nodes"] as! [[String: Any]])[0]["data"] as! [String: Any])
    try require((maximumData["content"] as! String).utf8.count == 262_144,
                "Leading BOM bytes disappeared from accepted content")
    try rejects(canvas([code("over", maximum + "x")]), mentioning: "262144")
    var attachment = shape("attachment")
    attachment["data"] = ["kind": "rect", "attachment": ["filename": "a.txt", "media_type": "text/plain",
                                                           "encoding": "utf-8", "content": maximum + "x"]]
    try rejects(canvas([attachment]), mentioning: "262144")
    var overlongCaption = shape("caption")
    overlongCaption["data"] = ["kind": "rect", "text": "\u{feff}" + String(repeating: "x", count: 2000)]
    try rejects(canvas([overlongCaption]), mentioning: "2000")
    for json in [#"{"version":1.0,"nodes":[],"edges":[]}"#,
                 #"{"version":2,"nodes":[],"edges":[],"paper":{"grid":20.0}}"#,
                 #"{"version":1,"nodes":[{"id":"n","type":"shape","x":0,"y":0,"width":100,"height":50,"data":{"kind":"rect","width":2.0}}],"edges":[]}"#,
                 #"{"version":1,"nodes":[{"id":"n","type":"shape","x":0,"y":0,"width":100,"height":50,"data":{"kind":"rect","radius":8.0}}],"edges":[]}"#] {
        do {
            _ = try CanvasDocument(data: Data(json.utf8))
            throw CheckFailure(description: "String-preserving decoding accepted a non-integer token")
        } catch is CanvasDocumentError {}
    }
    let encodedBytes = try CanvasDocument.encode(document.root)
    let roundTripped = try CanvasDocument(data: encodedBytes)
    try require(NSDictionary(dictionary: roundTripped.root).isEqual(to: document.root),
                "CanvasDocument.encode changed literal strings, decimals, booleans or 64-bit integers")

    let combinedNodes = (0..<4).map { code("c\($0)", maximum) } + (0..<4).map { index -> [String: Any] in
        var node = shape("a\(index)")
        node["data"] = ["kind": "rect", "attachment": [
            "filename": "a\(index).txt", "media_type": "text/plain", "encoding": "utf-8", "content": maximum
        ]]
        return node
    }
    let combinedDoc = try CanvasDocument(data: CanvasDocument.encode(canvas(combinedNodes)))
    try require((combinedDoc.root["nodes"] as? [Any])?.count == 8,
                "Independent 1 MiB code and attachment budgets were conflated")
    print("PASS literal JSON: BOM/Unicode/line-ending retention, metadata precision and restored-content quotas")
}

@MainActor
func checkCompatibilityRoundTrips(repository: URL) throws {
    let fixtures = ["v1/document.json", "v1/compatibility.json", "v2/document.json", "v2/code-compatibility.json"]
    let originalBytes = try Dictionary(uniqueKeysWithValues: fixtures.map { path in
        (path, try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/\(path)")))
    })
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("elixir-canvas-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    for path in fixtures {
        let tempURL = scratch.appendingPathComponent(path.replacingOccurrences(of: "/", with: "-"))
        try originalBytes[path]!.write(to: tempURL, options: .atomic)
        let document = try CanvasDocument(data: Data(contentsOf: tempURL))
        let session = CanvasSession(document: document)
        let view = CanvasView(session: session)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try require(bitmap.pixelsWide >= 800 && bitmap.pixelsHigh >= 600,
                    "Offscreen render failed for \(path)")
        try require(NSDictionary(dictionary: session.root).isEqual(to: document.root) &&
                    document.originalData == originalBytes[path],
                    "Rendering \(path) mutated session state or original bytes")
        let snapshot = try session.encodedData()
        try snapshot.write(to: tempURL, options: .atomic)
        let reopened = try CanvasDocument(data: Data(contentsOf: tempURL))
        try require(NSDictionary(dictionary: reopened.root).isEqual(to: document.root),
                    "Unedited native round-trip lost content or metadata in \(path)")
    }

    // v1 compatibility round-trip: move, resize/rotate, caption edit, shape + connection insert, undo/redo.
    let v1Temp = scratch.appendingPathComponent("v1-roundtrip.json")
    try originalBytes["v1/compatibility.json"]!.write(to: v1Temp, options: .atomic)
    let v1Doc = try CanvasDocument(data: Data(contentsOf: v1Temp))
    let v1Session = CanvasSession(document: v1Doc)
    let moveRecord = try v1Session.move("text", to: CanvasPosition(x: -75.5, y: 420.25))
    try require(moveRecord != nil, "v1 text move did not apply")
    let ellipseBefore = v1Session.geometry(of: "ellipse")!
    let ellipseAfter = ellipseBefore
        .resized(handle: .bottomRight, localDelta: CanvasPosition(x: 30, y: 20))
        .rotated(by: 15)
    let resizedEllipse = try v1Session.setGeometry("ellipse", to: ellipseAfter)
    try require(resizedEllipse, "v1 ellipse resize/rotate did not apply")
    let triangleTextBefore = v1Session.text(of: "triangle")
    let editedTriangleText = try v1Session.setText("triangle", to: "三角\nUpdated 🌿")
    try require(editedTriangleText, "v1 triangle caption edit did not apply")
    let lineBefore = v1Session.lineGeometry(of: "line")!
    let lineAfter = lineBefore.moving(.end, by: CanvasPosition(x: 25, y: -15))
    let editedLine = try v1Session.setLineGeometry("line", to: lineAfter)
    try require(editedLine, "v1 line endpoint edit did not apply")
    let insertedShape = try v1Session.insertShape(.rectangle, at: CanvasPosition(x: 780, y: 40), text: "Added in native")
    let insertedArrow = try v1Session.insertLine(.arrow, centeredAt: CanvasPosition(x: 780, y: 220))
    let insertedEdge = try v1Session.insertConnection(source: insertedShape.id, sourceSide: .left,
                                                      target: "diamond", targetSide: .right)
    let styledDiamond = try v1Session.setNodeStyle("diamond", property: .fill, to: .string("green"))
    try require(styledDiamond != nil, "v1 diamond fill style edit did not apply")
    let styledEdgeChange = try v1Session.setConnectionStyle("styled", property: .stroke, to: .string("blue"))
    try require(styledEdgeChange != nil, "v1 styled connection stroke edit did not apply")
    let updatedStepEdge = try v1Session.updateConnection(
        "step-solid", source: "ellipse", sourceSide: .right,
        target: "triangle", targetSide: .left, label: "Reconnected"
    )
    try require(updatedStepEdge != nil, "v1 step-solid connection update did not apply")
    let originalCollisionEdge = (v1Doc.root["edges"] as! [[String: Any]])[3]
    let updatedCollisionEdge = try v1Session.updateConnection(
        "straight-collision", source: "triangle", sourceSide: .bottom,
        target: "diamond", targetSide: .bottom, label: nil
    )
    try require(updatedCollisionEdge != nil, "v1 straight-collision reconnect did not apply")
    let updatedDocPaper = try v1Session.setDocumentStyle(property: .paperBackground, to: .string("cross"))
    let updatedDocGrid = try v1Session.setDocumentStyle(property: .paperGrid, to: .int(32))
    let updatedDocFont = try v1Session.setDocumentStyle(property: .font, to: .string("heading"))
    try require(updatedDocPaper != nil && updatedDocGrid != nil && updatedDocFont != nil,
                "v1 document style edits did not apply")
    let broughtFront = try v1Session.bringToFront("ellipse")
    try require(broughtFront != nil, "v1 ellipse bringToFront did not apply")
    let lockedText = try v1Session.setLocked("text", to: true)
    try require(lockedText, "v1 text lock did not apply")
    let deletedLoop = try v1Session.deleteConnection("loop")
    let v1EditedBytes = try v1Session.encodedData()
    try v1EditedBytes.write(to: v1Temp, options: .atomic)
    let v1Reopened = try CanvasDocument(data: Data(contentsOf: v1Temp))
    try require(NSDictionary(dictionary: v1Reopened.root).isEqual(to: v1Session.root),
                "Edited v1 round-trip did not match in-memory session state")
    try require(v1Reopened.root["version"] as? Int == 1, "Edited v1 round-trip changed format version")
    let v1Nodes = v1Reopened.root["nodes"] as! [[String: Any]]
    let v1Edges = v1Reopened.root["edges"] as! [[String: Any]]
    try require(v1Nodes.map { $0["id"] as! String } == ["rect", "diamond", "triangle", "text", "line", insertedShape.id, insertedArrow.id, "ellipse"],
                "v1 round-trip altered node stacking order or IDs")
    try require(v1Edges.map { $0["id"] as! String } == ["styled", "step-solid", "straight-collision", insertedEdge.id],
                "v1 round-trip altered edge order or IDs")
    try require(v1Nodes[3]["locked"] as? Bool == true, "v1 round-trip lost newly locked state")
    let reopenedLineData = v1Nodes[4]["data"] as! [String: Any]
    try require(reopenedLineData["stroke"] as? String == "red" &&
                (reopenedLineData["width"] as? NSNumber)?.intValue == 4 &&
                reopenedLineData["dash"] as? Bool == true &&
                reopenedLineData["arrow"] as? String == "both" &&
                reopenedLineData["future"] as? String == "line",
                "Editing v1 line endpoints lost stroke, width, dash, arrow or unknown metadata")
    let reopenedEllipseData = v1Nodes[7]["data"] as! [String: Any]
    let emptyAttachment = reopenedEllipseData["attachment"] as! [String: Any]
    try require(emptyAttachment["content"] as? String == "" &&
                emptyAttachment["future"] as? String == "empty-attachment" &&
                reopenedEllipseData["font"] as? String == "handwritten" &&
                reopenedEllipseData["size"] as? String == "l" &&
                reopenedEllipseData["align"] as? String == "right",
                "Resizing/reordering v1 ellipse lost empty attachment or typography metadata")
    var expectedCollisionEdge = originalCollisionEdge
    expectedCollisionEdge["target"] = "diamond"
    expectedCollisionEdge["target_handle"] = "bottom"
    try require(NSDictionary(dictionary: v1Edges[2]).isEqual(to: expectedCollisionEdge) &&
                v1Edges[2]["label"] is NSNull,
                "Reconnecting straight-collision altered fields other than target/target_handle or dropped label: null")
    let styledEdgeData = (v1Edges[0]["data"] as! [String: Any])["connector_style"] as! [String: Any]
    try require(styledEdgeData["stroke"] as? String == "blue" &&
                styledEdgeData["future"] as? String == "kept",
                "v1 connector style edit lost unknown connector_style metadata")
    try require(v1Edges[1]["label"] as? String == "Reconnected" &&
                v1Edges[1]["source_handle"] as? String == "right" &&
                v1Edges[1]["target_handle"] as? String == "left" &&
                ((v1Edges[1]["data"] as? [String: Any])?["connector_style"] as? [String: Any])?["unsupported"] as? Int == 99,
                "v1 connection reconnection/label edit lost edge data or unknown connector_style members")
    let reopenedPaper = v1Reopened.root["paper"] as? [String: Any]
    let reopenedAppearance = v1Reopened.root["appearance"] as? [String: Any]
    try require(reopenedPaper?["background"] as? String == "cross" &&
                (reopenedPaper?["grid"] as? NSNumber)?.intValue == 32 &&
                (reopenedPaper?["future"] as? [String: Any])?["note"] as? String == "paper" &&
                reopenedAppearance?["font"] as? String == "heading" &&
                reopenedAppearance?["future"] as? String == "keep",
                "v1 document style round-trip lost paper/appearance edits or unknown metadata")
    try v1Session.restoreInsertion(deletedLoop)
    _ = try v1Session.setLocked("text", to: nil)
    _ = try v1Session.moveNode("ellipse", toIndex: broughtFront!.fromIndex)
    try v1Session.applyStyleChange(updatedDocFont!.inverse)
    try v1Session.applyStyleChange(updatedDocGrid!.inverse)
    try v1Session.applyStyleChange(updatedDocPaper!.inverse)
    try v1Session.applyConnectionUpdate(updatedCollisionEdge!.inverse)
    try v1Session.applyConnectionUpdate(updatedStepEdge!.inverse)
    try v1Session.applyStyleChange(styledEdgeChange!.inverse)
    try v1Session.applyStyleChange(styledDiamond!.inverse)
    try v1Session.removeInsertion(insertedEdge)
    try v1Session.removeInsertion(insertedArrow)
    try v1Session.removeInsertion(insertedShape)
    _ = try v1Session.setLineGeometry("line", to: lineBefore)
    _ = try v1Session.setText("triangle", to: triangleTextBefore)
    _ = try v1Session.setGeometry("ellipse", to: ellipseBefore)
    _ = try v1Session.move("text", to: moveRecord!.before)
    let v1Restored = try v1Session.encodedDocument()
    try require(NSDictionary(dictionary: v1Restored.root).isEqual(to: v1Doc.root),
                "Undoing v1 edits and re-encoding did not restore exact original document")

    // v2 compatibility round-trip: fractional decimal move (130.1), code box resize/rotate, shape caption edit, undo.
    let v2Temp = scratch.appendingPathComponent("v2-roundtrip.json")
    try originalBytes["v2/code-compatibility.json"]!.write(to: v2Temp, options: .atomic)
    let v2Doc = try CanvasDocument(data: Data(contentsOf: v2Temp))
    let v2Session = CanvasSession(document: v2Doc)
    let shapeMove = try v2Session.move("shape", to: CanvasPosition(x: -42.5, y: 130.1))!
    let codeBefore = v2Session.geometry(of: "code-explicit")!
    let codeAfter = codeBefore
        .resized(handle: .topLeft, localDelta: CanvasPosition(x: -20, y: -10))
        .rotated(by: 15)
    _ = try v2Session.setGeometry("code-explicit", to: codeAfter)
    let shapeTextBefore = v2Session.text(of: "shape")
    _ = try v2Session.setText("shape", to: "Connected & verified")
    let v2EditedBytes = try v2Session.encodedData()
    try v2EditedBytes.write(to: v2Temp, options: .atomic)
    let v2Reopened = try CanvasDocument(data: Data(contentsOf: v2Temp))
    try require(NSDictionary(dictionary: v2Reopened.root).isEqual(to: v2Session.root),
                "Edited v2 round-trip did not match in-memory session state (including decimal 130.1)")
    let v2Nodes = v2Reopened.root["nodes"] as! [[String: Any]]
    let codeAutoData = v2Nodes[1]["data"] as! [String: Any]
    let codeFutureData = v2Nodes[2]["data"] as! [String: Any]
    try require(codeAutoData["language"] == nil &&
                codeFutureData["language"] as? String == "future-language",
                "v2 round-trip materialized Auto language or lost unknown language ID")
    _ = try v2Session.setText("shape", to: shapeTextBefore)
    _ = try v2Session.setGeometry("code-explicit", to: codeBefore)
    _ = try v2Session.move("shape", to: shapeMove.before)
    let v2Restored = try v2Session.encodedDocument()
    try require(NSDictionary(dictionary: v2Restored.root).isEqual(to: v2Doc.root),
                "Undoing v2 edits and re-encoding did not restore exact original document")

    for path in fixtures {
        let current = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/\(path)"))
        try require(current == originalBytes[path], "Checked-in fixture \(path) was modified")
    }
    print("PASS compatibility round-trips: temporary v1/v2 copies, edge variants, collision retention, decimal/64-bit precision and undo restoration")
}

func exportCrossEditorRoundTrip(in directory: URL) throws {
    let v1Doc = try CanvasDocument(data: Data(contentsOf: directory.appendingPathComponent("v1.json")))
    let v1Session = CanvasSession(document: v1Doc)
    _ = try v1Session.move("text", to: CanvasPosition(x: -75.5, y: 420.25))
    let ell = v1Session.geometry(of: "ellipse")!
        .resized(handle: .right, localDelta: CanvasPosition(x: 20, y: 0))
        .rotated(by: 15)
    _ = try v1Session.setGeometry("ellipse", to: ell)
    _ = try v1Session.setText("triangle", to: "三角\nNative edit")
    let added = try v1Session.insertShape(.rectangle, at: CanvasPosition(x: 780, y: 40), text: "Native node")
    _ = try v1Session.insertConnection(source: added.id, sourceSide: .left, target: "diamond", targetSide: .right)
    try v1Session.encodedData().write(to: directory.appendingPathComponent("v1-after-native.json"), options: .atomic)

    let v2Doc = try CanvasDocument(data: Data(contentsOf: directory.appendingPathComponent("v2.json")))
    let v2Session = CanvasSession(document: v2Doc)
    _ = try v2Session.move("shape", to: CanvasPosition(x: -42.5, y: 130.1))
    let codeGeo = v2Session.geometry(of: "code-explicit")!
        .resized(handle: .bottomRight, localDelta: CanvasPosition(x: 40, y: 20))
        .rotated(by: 15)
    _ = try v2Session.setGeometry("code-explicit", to: codeGeo)
    _ = try v2Session.setText("shape", to: "Native + Web")
    try v2Session.encodedData().write(to: directory.appendingPathComponent("v2-after-native.json"), options: .atomic)
}

@MainActor
func verifyCrossEditorRoundTrip(in directory: URL) throws {
    let v1Reopened = try CanvasDocument(data: Data(contentsOf: directory.appendingPathComponent("v1-after-native.json")))
    let v1Session = CanvasSession(document: v1Reopened)
    let v1View = CanvasView(session: v1Session)
    let v1Bitmap = v1View.bitmapImageRepForCachingDisplay(in: v1View.bounds)!
    v1View.cacheDisplay(in: v1View.bounds, to: v1Bitmap)
    try require(v1Reopened.root["version"] as? Int == 1 &&
                v1Session.position(of: "diamond") == CanvasPosition(x: 500, y: 25) &&
                v1Session.position(of: "text") == CanvasPosition(x: -75.5, y: 420.25) &&
                v1Session.text(of: "triangle") == "三角\nNative edit" &&
                ((v1Reopened.root["future"] as? [String: Any])?["sequence"] as? NSNumber)?.int64Value == 9_007_199_254_740_993,
                "Native reopen of web-saved v1 lost edits or metadata")

    let converted = try CanvasDocument(data: Data(contentsOf: directory.appendingPathComponent("v1-converted-to-v2.json")))
    try require(converted.root["version"] as? Int == 2 &&
                ((converted.root["future"] as? [String: Any])?["sequence"] as? NSNumber)?.int64Value == 9_007_199_254_740_993,
                "Native reopen of web-converted v2 copy failed")

    let v2Reopened = try CanvasDocument(data: Data(contentsOf: directory.appendingPathComponent("v2-after-native.json")))
    let v2Session = CanvasSession(document: v2Reopened)
    let v2View = CanvasView(session: v2Session)
    let v2Bitmap = v2View.bitmapImageRepForCachingDisplay(in: v2View.bounds)!
    v2View.cacheDisplay(in: v2View.bounds, to: v2Bitmap)
    let v2Nodes = v2Reopened.root["nodes"] as! [[String: Any]]
    try require(v2Reopened.root["version"] as? Int == 2 &&
                v2Session.position(of: "code-auto") == CanvasPosition(x: 520, y: -20.5) &&
                v2Session.position(of: "shape") == CanvasPosition(x: -42.5, y: 130.1) &&
                v2Session.text(of: "shape") == "Native + Web" &&
                (v2Nodes[1]["data"] as! [String: Any])["language"] == nil &&
                (v2Nodes[2]["data"] as! [String: Any])["language"] as? String == "future-language",
                "Native reopen of web-saved v2 lost edits, code metadata or decimal coordinates")
    print("PASS cross-editor Native -> Web -> Native round-trip on temporary v1/v2 copies")
}

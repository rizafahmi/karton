import CanvasCore
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
                 #"{"version":2,"nodes":[],"edges":[],"paper":{"grid":20.0}}"#] {
        do {
            _ = try CanvasDocument(data: Data(json.utf8))
            throw CheckFailure(description: "String-preserving decoding accepted a non-integer token")
        } catch is CanvasDocumentError {}
    }
    print("PASS literal JSON: BOM/Unicode/line-ending retention, metadata precision and restored-content quotas")
}

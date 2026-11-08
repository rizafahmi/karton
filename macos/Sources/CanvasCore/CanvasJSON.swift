import CoreFoundation
import Foundation

/// JSONDecoder/JSONEncoder preserve leading U+FEFF in strings and exact numeric
/// precision, unlike JSONSerialization on the current macOS SDK. Numeric token
/// validation still runs on the original Foundation tree before decoding.
struct CanvasJSON: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: Key.self) {
            var result: [String: Any] = [:]
            result.reserveCapacity(object.allKeys.count)
            for key in object.allKeys { result[key.stringValue] = try object.decode(CanvasJSON.self, forKey: key).value }
            value = result
        } else if var array = try? decoder.unkeyedContainer() {
            var result: [Any] = []
            if let count = array.count { result.reserveCapacity(count) }
            while !array.isAtEnd { result.append(try array.decode(CanvasJSON.self).value) }
            value = result
        } else {
            let scalar = try decoder.singleValueContainer()
            if scalar.decodeNil() { value = NSNull() }
            else if let bool = try? scalar.decode(Bool.self) { value = bool }
            else if let string = try? scalar.decode(String.self) { value = string }
            else if let integer = try? scalar.decode(Int64.self) { value = NSNumber(value: integer) }
            else if let integer = try? scalar.decode(UInt64.self) { value = NSNumber(value: integer) }
            else { value = NSNumber(value: try scalar.decode(Double.self)) }
        }
    }

    func encode(to encoder: Encoder) throws {
        if let object = value as? [String: Any] {
            var container = encoder.container(keyedBy: Key.self)
            for (key, member) in object {
                guard let codingKey = Key(stringValue: key) else {
                    throw EncodingError.invalidValue(
                        key,
                        .init(codingPath: encoder.codingPath, debugDescription: "Invalid JSON object key.")
                    )
                }
                try container.encode(CanvasJSON(member), forKey: codingKey)
            }
        } else if let array = value as? [Any] {
            var container = encoder.unkeyedContainer()
            for element in array {
                try container.encode(CanvasJSON(element))
            }
        } else {
            var scalar = encoder.singleValueContainer()
            if value is NSNull {
                try scalar.encodeNil()
            } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                try scalar.encode(number.boolValue)
            } else if let string = value as? String {
                try scalar.encode(string)
            } else if let number = value as? NSNumber {
                let type = String(cString: number.objCType)
                if ["f", "d"].contains(type) {
                    let double = number.doubleValue
                    guard double.isFinite else {
                        throw EncodingError.invalidValue(
                            value,
                            .init(codingPath: encoder.codingPath, debugDescription: "Non-finite JSON number.")
                        )
                    }
                    try scalar.encode(double)
                } else if ["Q", "L", "I", "S", "C"].contains(type) {
                    try scalar.encode(number.uint64Value)
                } else {
                    try scalar.encode(number.int64Value)
                }
            } else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON value.")
                )
            }
        }
    }

    static func encode(_ root: [String: Any]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(CanvasJSON(root))
        data.append(0x0A)
        return data
    }
}

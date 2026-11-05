import Foundation

/// JSONDecoder preserves leading U+FEFF in strings, unlike JSONSerialization on
/// the current macOS SDK. Numeric token validation still runs on the original
/// Foundation tree before this decoding pass (notably version 1 versus 1.0).
struct CanvasJSON: Decodable {
    let value: Any

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
            else if let decimal = try? scalar.decode(Decimal.self) { value = NSDecimalNumber(decimal: decimal) }
            else { value = NSNumber(value: try scalar.decode(Double.self)) }
        }
    }
}

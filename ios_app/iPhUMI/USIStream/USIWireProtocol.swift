import Foundation

enum USIMessageType: UInt16 {
    case hello = 1, frame = 2, ping = 3, pong = 4, health = 5
}

struct USIWireHeader {
    let type: USIMessageType
    let metadataLength: Int
    let payloadLength: Int
    var totalLength: Int { 16 + metadataLength + payloadLength }
}

struct USIWirePacket {
    let type: USIMessageType
    let metadata: [String: Any]
    let payload: Data
}

enum USIWireError: Error {
    case badMagic, badVersion, badType, invalidLength, invalidJSON, unexpectedPayload
}

enum USIWire {
    static let headerLength = 16
    static let maxMetadataLength = 65_536
    static let maxPayloadLength = 16_777_216

    static func encode(type: USIMessageType, metadata: [String: Any], payload: Data = Data()) throws -> Data {
        guard JSONSerialization.isValidJSONObject(metadata) else { throw USIWireError.invalidJSON }
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard json.count <= maxMetadataLength, payload.count <= maxPayloadLength else {
            throw USIWireError.invalidLength
        }
        guard type == .frame || payload.isEmpty else { throw USIWireError.unexpectedPayload }
        var result = Data("USI2".utf8)
        appendBE(UInt16(1), to: &result)
        appendBE(type.rawValue, to: &result)
        appendBE(UInt32(json.count), to: &result)
        appendBE(UInt32(payload.count), to: &result)
        result.append(json)
        result.append(payload)
        return result
    }

    static func parseHeader(_ data: Data) throws -> USIWireHeader {
        guard data.count == headerLength else { throw USIWireError.invalidLength }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == Array("USI2".utf8) else { throw USIWireError.badMagic }
        func word(_ start: Int, _ count: Int) -> UInt32 {
            bytes[start..<(start + count)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard word(4, 2) == 1 else { throw USIWireError.badVersion }
        guard let type = USIMessageType(rawValue: UInt16(word(6, 2))) else { throw USIWireError.badType }
        let jsonLength = Int(word(8, 4)), payloadLength = Int(word(12, 4))
        guard jsonLength > 0, jsonLength <= maxMetadataLength, payloadLength <= maxPayloadLength else {
            throw USIWireError.invalidLength
        }
        guard type == .frame || payloadLength == 0 else { throw USIWireError.unexpectedPayload }
        return USIWireHeader(type: type, metadataLength: jsonLength, payloadLength: payloadLength)
    }

    static func decode(_ data: Data) throws -> USIWirePacket {
        let header = try parseHeader(Data(data.prefix(headerLength)))
        guard data.count == header.totalLength else { throw USIWireError.invalidLength }
        let json = data.subdata(in: headerLength..<(headerLength + header.metadataLength))
        guard let metadata = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              JSONSerialization.isValidJSONObject(metadata) else { throw USIWireError.invalidJSON }
        let payload = data.subdata(in: (headerLength + header.metadataLength)..<data.count)
        return USIWirePacket(type: header.type, metadata: metadata, payload: payload)
    }

    private static func appendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

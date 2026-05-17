import Foundation

public enum JSONCoders {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = makeEncoder()
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch let error as MaycastError {
            throw error
        } catch let error as EncodingError {
            throw MaycastError.encodingFailed(url, underlying: error)
        } catch {
            throw MaycastError.ioError(url, underlying: error)
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = makeDecoder()
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw MaycastError.decodingFailed(url, underlying: error)
        } catch {
            throw MaycastError.ioError(url, underlying: error)
        }
    }
}

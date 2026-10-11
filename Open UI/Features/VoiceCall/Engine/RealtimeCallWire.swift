import Foundation

enum RealtimeCallWire {
    static let sampleRate = 24_000.0

    static func pcm(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = sample.isFinite ? min(1, max(-1, sample)) : 0
            let bits = UInt16(bitPattern: Int16((value * 32767).rounded()))
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    static func samples(_ base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count % 2 == 0 else { return nil }
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }

    static func request(_ arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == ["request"], let text = object["request"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 32000 else { return nil }
        return text
    }

    static func answer(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(100000)))
    }

    static func context(_ messages: [(role: String, content: String)]) -> [[String: String]] {
        var result: [[String: String]] = []
        var remaining = 64000
        for message in messages.reversed() where ["user", "assistant"].contains(message.role) {
            guard result.count < 100, remaining > 0 else { break }
            let content = String(String.UnicodeScalarView(message.content.unicodeScalars.prefix(min(32000, remaining))))
            remaining -= content.unicodeScalars.count
            result.append(["role": message.role, "content": content])
        }
        return result.reversed()
    }
}

struct RealtimePlaybackPosition {
    let itemID: String
    let contentIndex: Int
    let startSample: Int64
    var receivedSamples = 0

    func heardMilliseconds(currentSample: Int64, outputRate: Double) -> Int {
        guard outputRate > 0 else { return 0 }
        let played = Double(max(0, currentSample - startSample)) * 1000 / outputRate
        return min(receivedSamples * 1000 / 24000, Int(played))
    }
}

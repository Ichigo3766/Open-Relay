import Foundation

@main
struct RealtimeCallWireTests {
    static func main() {
        let pcm = RealtimeCallWire.pcm([-2, 0, 2, .nan, .infinity])
        precondition(Array(pcm) == [1, 128, 0, 0, 255, 127, 0, 0, 0, 0])
        let decoded = RealtimeCallWire.samples(pcm.base64EncodedString())!
        precondition(abs(decoded[0] + 1) < 0.0001 && abs(decoded[2] - 1) < 0.0001)
        precondition(RealtimeCallWire.samples("not base64") == nil)
        precondition(RealtimeCallWire.samples(Data([1]).base64EncodedString()) == nil)
        precondition(RealtimeCallWire.request(#"{"request":"Make a paper kite."}"#) == "Make a paper kite.")
        precondition(RealtimeCallWire.request(#"{"request":" ","extra":"bad"}"#) == nil)
        precondition(RealtimeCallWire.request(#"{"request":" "}"#) == nil)
        let context = RealtimeCallWire.context((0..<110).map { (role: "user", content: "Kite \($0)") })
        precondition(context.count == 100 && context.first?["content"] == "Kite 10" && context.last?["content"] == "Kite 109")
        let large = RealtimeCallWire.context([(role: "system", content: "Excluded"), (role: "user", content: String(repeating: "🪁", count: 40000)), (role: "assistant", content: String(repeating: "a", count: 40000))])
        precondition(large.count == 2 && large.reduce(0) { $0 + $1["content"]!.unicodeScalars.count } == 64000)
        let position = RealtimePlaybackPosition(itemID: "sample-audio", contentIndex: 0, startSample: 1000, receivedSamples: 24000)
        precondition(position.heardMilliseconds(currentSample: 25000, outputRate: 48000) == 500)
        precondition(position.heardMilliseconds(currentSample: 100000, outputRate: 48000) == 1000)
        precondition(position.heardMilliseconds(currentSample: 0, outputRate: 48000) == 0)
        print("Realtime PCM, request validation, bounded context and heard-audio truncation checks passed.")
    }
}

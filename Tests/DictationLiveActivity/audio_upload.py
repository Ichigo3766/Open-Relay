"""Encode a synthetic tone with the dictation settings and inspect its upload.

Runs on macOS without a microphone or server. Production recording settings,
MIME lookup, transcription wrapper, and multipart builder are extracted unchanged.
URLProtocol intercepts the request; surrounding networking is a minimal fixture.
"""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)


def function(path, signature):
    source = (root / path).read_text()
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


service = (root / "Open UI/Core/Services/DictationService.swift").read_text()
settings = service.split("let settings: [String: Any] = [", 1)[1].split("\n        ]", 1)[0]
network = function("Open UI/Core/Networking/NetworkManager.swift", "func uploadMultipart(")
transcribe = function("Open UI/Core/Networking/APIClient.swift", "func transcribeSpeech(")
mime = function("Open UI/Core/Networking/APIModels.swift", "func mimeType(")
fixture = r'''
import Foundation
import AVFoundation

enum APIError: Error { case responseDecoding(underlying: Error, data: Data?) }
enum HTTPMethod { case post }
final class NetworkManager {
    let session: URLSession
    let certificateDelegate: URLSessionDelegate? = nil
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadProbe.self]
        session = URLSession(configuration: configuration)
    }
    func buildRequest(path: String, method: HTTPMethod, queryItems: [URLQueryItem]?, body: Data,
                      contentType: String, authenticated: Bool, timeout: TimeInterval?) throws -> URLRequest {
        precondition(path == "/api/v1/audio/transcriptions")
        var request = URLRequest(url: URL(string: "https://example.invalid" + path)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let timeout { request.timeoutInterval = timeout }
        return request
    }
    func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
    func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
    }
    __MULTIPART__
}
final class APIClient {
    let network = NetworkManager()
    __TRANSCRIBE__
}
__MIME__
final class UploadProbe: URLProtocol {
    static var audio = Data()
    static var overhead = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        precondition(request.timeoutInterval == 360)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var chunk = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                precondition(count >= 0)
                if count == 0 { break }
                body.append(contentsOf: chunk.prefix(count))
            }
        }
        let contentType = request.value(forHTTPHeaderField: "Content-Type")!
        let boundary = contentType.components(separatedBy: "boundary=")[1]
        let header = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)
        let footer = Data("\r\n--\(boundary)--\r\n".utf8)
        precondition(body == header + Self.audio + footer, "Upload must preserve the encoded file exactly")
        Self.overhead = body.count - Self.audio.count
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data(#"{"text":"Synthetic transcription"}"#.utf8))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct AudioUploadCheck {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("synthetic-tone.m4a")
        let settings: [String: Any] = [__SETTINGS__]
        // AVAudioFile uses the same native AAC encoder settings, with invented PCM input.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for second in 0..<60 {
                for i in 0..<16000 {
                    let t = Double(second * 16000 + i) / 16000
                    buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 1370 * t))
                }
                try file.write(from: buffer)
            }
        }
        let encoded = try AVAudioFile(forReading: url)
        precondition(encoded.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        precondition(encoded.fileFormat.sampleRate == 16000 && encoded.fileFormat.channelCount == 1)
        precondition(abs(Double(encoded.length) / encoded.processingFormat.sampleRate - 60) < 0.2)
        UploadProbe.audio = try Data(contentsOf: url)
        precondition(UploadProbe.audio.count < 275000, "Expected compressed 32 kbps AAC, not PCM")
        let result = try await APIClient().transcribeSpeech(audioData: UploadProbe.audio, fileName: "Recording.m4a",
            authorization: "Bearer synthetic-token", timeout: 360)
        precondition(result["text"] as? String == "Synthetic transcription")
        precondition(UploadProbe.overhead < 1024)
        print("PASS: 60-second AAC/M4A, mono 16000 Hz; \(UploadProbe.audio.count) file bytes; \(UploadProbe.overhead) multipart bytes; audio/mp4; payload unchanged")
    }
}
'''
for token, value in [("__MULTIPART__", network), ("__TRANSCRIBE__", transcribe), ("__MIME__", mime), ("__SETTINGS__", settings)]:
    fixture = fixture.replace(token, value)
source = output / "AudioUploadCheck.swift"
source.write_text(fixture)
environment = os.environ.copy()
for variable, directory in [("TMPDIR", "tmp"), ("CLANG_MODULE_CACHE_PATH", "module-cache"), ("SWIFT_MODULE_CACHE_PATH", "module-cache")]:
    location = output / directory
    location.mkdir(exist_ok=True)
    environment[variable] = str(location)
binary = output / "audio-upload-check"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], env=environment, check=True)
subprocess.run([str(binary), str(output)], env=environment, check=True)

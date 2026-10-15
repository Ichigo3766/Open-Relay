import Foundation
enum TLSChallengeHandler {static func isClientCertificateError(_ error:Error)->Bool { false }}
enum Outcome {case renewed,unavailable,rejected}
struct Logger {func info(_ text:String){};func warning(_ text:String){}}
@MainActor final class Transport {
    var status=200;var failure:URLError?
    func data(for request:URLRequest) async throws -> (Data,URLResponse) {
        if let failure {throw failure};return (Data(),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}
@MainActor final class Subject {
    let session=Transport();var authToken:String?;var onUnauthorizedRecover:Bool?;var onConnectionResult:((Bool)->Void)?;let logger=Logger()
    func attemptSilentRecovery() async -> Outcome { .rejected }
// INSERT_PERFORM
}
@main struct Checks {
    @MainActor static func main() async throws {
        let subject=Subject();var results=[Bool]();subject.onConnectionResult={results.append($0)};var count=0
        func check(_ condition:Bool,_ name:String) {count+=1;if !condition {print("FAIL: "+name);exit(1)}}
        let request=URLRequest(url:URL(string:"https://relay.example.test/api/models")!)
        for status in [200,204,401,404] {
            subject.session.status=status;results=[];_=try await subject.performRequest(request)
            check(results==[true],"HTTP \(status) proves reachability without another request")
        }
        subject.session.status=503;results=[];_=try await subject.performRequest(request)
        check(results.isEmpty,"gateway/server error does not claim healthy reachability")
        for code in [URLError.timedOut,.notConnectedToInternet,.cannotConnectToHost] {
            subject.session.failure=URLError(code);results=[];_=try? await subject.performRequest(request)
            check(results==[false],"connectivity error triggers recovery")
        }
        subject.session.failure=URLError(.cancelled);results=[];_=try? await subject.performRequest(request)
        check(results.isEmpty,"cancellation is not a disconnection")
        let health=URLRequest(url:URL(string:"https://relay.example.test/health")!)
        subject.session.failure=URLError(.timedOut);results=[];_=try? await subject.performRequest(health)
        check(results.isEmpty,"health probe failure cannot recursively trigger health probes")
        subject.session.failure=nil;subject.session.status=200;_=try await subject.performRequest(health)
        check(results.isEmpty,"health probe result is handled once by its own caller")
        print("Passed \(count) request signal checks")
    }
}

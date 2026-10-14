import Foundation

actor Transport {
    var calls = 0
    var revision=0
    var fail = false
    var responseStatus=200
    var loseWriteAck=false
    var failureCode=URLError.Code.networkConnectionLost
    func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        if request.url!.path.hasSuffix("invented-read-after-write") {
            let value=revision
            if request.httpMethod=="POST" {try await Task.sleep(for:.milliseconds(20));revision+=1;if loseWriteAck{throw URLError(.networkConnectionLost)}}
            else {try await Task.sleep(for:.milliseconds(80))}
            return (Data("Invented revision \(value)".utf8), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let fail = self.fail, code=self.failureCode, status=self.responseStatus
        try await Task.sleep(for: .milliseconds(30))
        if fail { throw URLError(code) }
        return (Data("Invented response".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func setWriteAckLoss(){loseWriteAck=true}
    func reset(fail: Bool = false,status:Int=200,code:URLError.Code = .networkConnectionLost) {calls=0;self.fail=fail;responseStatus=status;failureCode=code}
}
enum APIError: Error {
    case unknown(underlying: Int?)
    case network(URLError)
    case sessionRenewalUnavailable
    static func from(_ error:Error)->APIError{if let api=error as? APIError{return api};return .network(error as? URLError ?? URLError(.unknown))}
    var isRetryable:Bool{if case .network(let error)=self{return error.code != .cancelled && error.code != .serverCertificateUntrusted};return false}
    var localizedDescription:String{"Invented transport error"}
}
struct Logger:Sendable{func warning(_ text:String){};func info(_ text:String){}}
enum Renewal{case renewed,unavailable,rejected}
struct Session:Sendable{let transport:Transport;func data(for request:URLRequest)async throws->(Data,URLResponse){try await transport.run(request)}}
final class NetworkManager: @unchecked Sendable {
    let transport = Transport()
    let logger=Logger()
    func parseHTTPError(statusCode:Int,data:Data)->APIError{.unknown(underlying:nil)}
    let deduplicator = GETDeduplicator()
    var session:Session{Session(transport:transport)}
    let onUnauthorizedRecover:Bool?=nil
    let authToken:String?=nil
    func attemptSilentRecovery()async->Renewal{.rejected}
    INSERT_PERFORM
    // Production deduplicatedGET is inserted here.
    INSERT_METHOD
    INSERT_RETRY
}
INSERT_ACTOR
@main struct Checks {
    static func main() async throws {
        let net=NetworkManager();let request=URLRequest(url:URL(string:"https://example.invalid/invented-settings")!)
        var checks=0
        func check(_ ok:Bool,_ label:String){checks+=1;if !ok{print("FAIL: "+label);exit(1)}}
        func burst(_ requests:[URLRequest]) async -> [Bool] {
            await withTaskGroup(of:Bool.self,returning:[Bool].self){group in
                for request in requests {group.addTask{do{let(data,_)=try await net.deduplicatedGET(request);return data==Data("Invented response".utf8)}catch{return false}}}
                var values=[Bool]();for await value in group{values.append(value)};return values
            }
        }
        await withTaskGroup(of:Void.self){group in
            for _ in 0..<64 {group.addTask{_ = try? await net.performRequestWithRetry(request,maxRetries:0)}}
        }
        check(await net.transport.calls==1,"JSON retry path coalesces concurrent GETs")
        for _ in 0..<20 {
            await net.transport.reset()
            let values=await burst(Array(repeating:request,count:64))
            check(values.allSatisfy{$0},"every waiter receives data")
            check(await net.transport.calls==1,"64 concurrent identical GETs use one transport")
            _=try await net.deduplicatedGET(request)
            check(await net.transport.calls==2,"completed GET is not cached")
        }
        for field in ["Authorization","Accept","If-None-Match","X-Invented"] {
            await net.transport.reset()
            var a=request,b=request;a.setValue("invented-a",forHTTPHeaderField:field);b.setValue("invented-b",forHTTPHeaderField:field)
            let values=await burst([a,b,a,b]);check(values.allSatisfy{$0},"header variants return data")
            check(await net.transport.calls==2,"different "+field+" headers stay isolated")
        }
        await net.transport.reset()
        var a=request,b=request;a.timeoutInterval=1;b.timeoutInterval=10
        _=await burst([a,b]);check(await net.transport.calls==2,"different timeout policies remain independent")
        await net.transport.reset();a=request;b=request;a.cachePolicy = .reloadIgnoringLocalCacheData;b.cachePolicy = .returnCacheDataDontLoad
        _=await burst([a,b]);check(await net.transport.calls==2,"different cache policies remain independent")
        for kind in ["POST","GET-body","GET-stream"] {
            await net.transport.reset();var r=request
            if kind=="POST" {r.httpMethod="POST"}else if kind=="GET-body"{r.httpBody=Data("Invented body".utf8)}else{r.httpBodyStream=InputStream(data:Data("Invented stream".utf8))}
            let values=await burst(Array(repeating:r,count:32));check(values.allSatisfy{$0},kind+" returns independently")
            check(await net.transport.calls==32,kind+" never shares a transport")
        }
        await net.transport.reset(fail:true)
        let failed=await burst(Array(repeating:request,count:64));check(failed.allSatisfy{!$0},"failure reaches every waiter")
        check(await net.transport.calls==1,"failed requests are coalesced")
        await net.transport.reset();_ = try await net.deduplicatedGET(request)
        check(await net.transport.calls==1,"failure is removed and next request succeeds")
        await net.transport.reset()
        let cancelled=Task {try await net.deduplicatedGET(request)}
        try await Task.sleep(for:.milliseconds(5));cancelled.cancel()
        let other=try await net.deduplicatedGET(request);_ = try await cancelled.value
        check(other.0==Data("Invented response".utf8),"cancelled waiter does not cancel shared transport")
        check(await net.transport.calls==1,"cancellation keeps one transport")
        await net.transport.reset(fail:true)
        do {_ = try await net.performRequestWithRetry(request,maxRetries:2,baseDelay:0);check(false,"retry exhaustion throws")}catch{check(await net.transport.calls==3,"retryable failures perform bounded fresh attempts")}
        await net.transport.reset(status:503)
        let exhausted=try await net.performRequestWithRetry(request,maxRetries:2,baseDelay:0)
        let retryCalls=await net.transport.calls
        check((exhausted.1 as? HTTPURLResponse)?.statusCode==503 && retryCalls==3,"5xx retries retain existing budget")
        await net.transport.reset(status:401)
        _ = try await net.performRequestWithRetry(request,maxRetries:2,baseDelay:0)
        check(await net.transport.calls==1,"4xx responses are not retried")
        for code in [URLError.Code.cancelled,.serverCertificateUntrusted] {
            await net.transport.reset(fail:true,code:code)
            do {_ = try await net.performRequestWithRetry(request,maxRetries:2,baseDelay:0);check(false,"terminal error throws")}catch{check(await net.transport.calls==1,"cancellation and TLS errors do not retry")}
        }
        await net.transport.reset();var otherRequest=request;otherRequest.url=URL(string:"https://example.invalid/invented-other-settings")!
        _=await burst([request,otherRequest,request,otherRequest]);check(await net.transport.calls==2,"different URLs stay isolated")
        await net.transport.reset()
        let read=URLRequest(url:URL(string:"https://example.invalid/invented-read-after-write")!)
        let oldRead=Task{try await net.deduplicatedGET(read)}
        try await Task.sleep(for:.milliseconds(5))
        var write=read;write.httpMethod="POST"
        _ = try await net.performRequestWithRetry(write,maxRetries:0)
        let freshRead=Task{try await net.deduplicatedGET(read)}
        _ = try await oldRead.value
        let joinedFresh=try await net.deduplicatedGET(read)
        let fresh=try await freshRead.value
        check(fresh.0==Data("Invented revision 1".utf8),"GET after acknowledged mutation does not reuse older in-flight data")
        check(joinedFresh.0==fresh.0,"older request cleanup cannot remove a newer generation")
        check(await net.transport.calls==3,"post-mutation waiters still share one fresh GET")
        let overlap=NetworkManager()
        let writing=Task{try await overlap.performRequestWithRetry(write,maxRetries:0)}
        try await Task.sleep(for:.milliseconds(5))
        let duringWrite=Task{try await overlap.deduplicatedGET(read)}
        try await Task.sleep(for:.milliseconds(5))
        _ = try await writing.value
        let afterWrite=try await overlap.deduplicatedGET(read)
        let during=try await duringWrite.value
        check(during.0==Data("Invented revision 0".utf8),"fixture captures a read while write is pending")
        check(afterWrite.0==Data("Invented revision 1".utf8),"acknowledged write invalidates a GET that started during the write")
        check(await overlap.transport.calls==3,"post-write read uses a fresh transport")
        let uncertain=NetworkManager();await uncertain.transport.setWriteAckLoss()
        let beforeLoss=Task{try await uncertain.deduplicatedGET(read)}
        try await Task.sleep(for:.milliseconds(5))
        do {_ = try await uncertain.performRequestWithRetry(write,maxRetries:0);check(false,"lost write ACK must throw")}
        catch {check(true,"lost write ACK stays an error")}
        let reconciled=try await uncertain.deduplicatedGET(read)
        let stale=try await beforeLoss.value
        check(stale.0==Data("Invented revision 0".utf8) && reconciled.0==Data("Invented revision 1".utf8),"uncertain write completion also invalidates older GETs")
        check(await uncertain.transport.calls==3,"reconciliation starts a fresh read after lost write ACK")
        print("Passed \(checks) request coalescing checks")
    }
}

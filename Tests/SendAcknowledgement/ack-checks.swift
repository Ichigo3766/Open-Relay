import Foundation
enum TLSChallengeHandler {static func isClientCertificateError(_ error:Error)->Bool{false}}
struct ChatMessageError:Sendable{let content:String?}
struct ChatStatusUpdate:Sendable{let action:String;let description:String;let done:Bool}
struct ChatMessage:Sendable{let id:String;var content:String;var isStreaming:Bool;var error:ChatMessageError?}
enum CatchUpReason:String{case chatOpened}
struct Logger{func info(_ text:String){}}
@MainActor final class Subject {
    var recovery=0,updates=0,cleanups=0,attached=0,finished=0,syncs=0
    var hasFinishedStreaming=false,isRecoveringSendAcknowledgement=false
    var isExternallyStreaming=false
    var resulting:ChatMessage?
    let assistantMessageId="invented-response"
    let logger=Logger()
    func startRecoveryTimer(assistantMessageId:String,chatId:String?){recovery+=1}
    func appendStatusUpdate(id:String,status:ChatStatusUpdate){}
    func updateAssistantMessage(id:String,content:String,isStreaming:Bool,error:ChatMessageError?=nil){updates+=1;resulting=ChatMessage(id:id,content:content,isStreaming:isStreaming,error:error)}
    func cleanupStreaming(){cleanups+=1;isExternallyStreaming=false}
    func attachToLiveReply(_ reply:ChatMessage,reason:CatchUpReason){attached+=1;resulting=reply}
    func finishExternalFollow(with reply:ChatMessage){finished+=1;resulting=reply}
    func syncWithServer(force:Bool)async{syncs+=1}
    func failed(_ error:Error,effectiveChatId:String?) {
        INSERT_CATCH
    }
    INSERT_RESOLVE
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count=0
        func check(_ ok:Bool,_ label:String){count+=1;if !ok{print("FAIL: "+label);exit(1)}}
        for code in [URLError.Code.networkConnectionLost,.timedOut,.cannotConnectToHost,.notConnectedToInternet,.cannotFindHost,.dnsLookupFailed] {
            let vm=Subject();vm.failed(URLError(code),effectiveChatId:"invented-chat")
            check(vm.recovery==1,"uncertain network failure uses recovery: \(code.rawValue)")
            check(vm.cleanups==0 && vm.updates==0,"uncertain failure retains live listener and received content")
        }
        let definitive:[Error]=[APIError.httpError(statusCode:401,message:nil,data:nil),APIError.httpError(statusCode:503,message:nil,data:nil),URLError(.serverCertificateUntrusted),APIError.responseDecoding(underlying:URLError(.cannotDecodeRawData),data:nil)]
        for error in definitive {
            let vm=Subject();vm.failed(error,effectiveChatId:"invented-chat")
            check(vm.recovery==0 && vm.cleanups==1,"definitive response/auth/TLS errors stay terminal")
            check(vm.resulting?.error != nil,"terminal error remains visible")
        }
        let temporary=Subject();temporary.failed(URLError(.networkConnectionLost),effectiveChatId:nil)
        check(temporary.recovery==0 && temporary.cleanups==1,"chatless failure cannot poll")
        for content in [""," \n\t"] {
            let vm=Subject();vm.isExternallyStreaming=true
            let message=ChatMessage(id:"invented-empty",content:content,isStreaming:true)
            vm.resolveLastReply(message,serverSaysGenerating:true,generationRunning:false,reason:.chatOpened)
            check(vm.resulting?.error != nil && vm.resulting?.isStreaming==false,"empty orphan has an actionable error")
            check(vm.attached==0,"empty orphan does not join a nonexistent generation")
        }
        for running in [true,nil] as [Bool?] {
            let vm=Subject();let message=ChatMessage(id:"invented-live",content:"",isStreaming:true)
            vm.resolveLastReply(message,serverSaysGenerating:true,generationRunning:running,reason:.chatOpened)
            check(vm.attached==1 && vm.cleanups==0,"active or unknown task registry never declares failure")
        }
        let completed=Subject();completed.isExternallyStreaming=true
        completed.resolveLastReply(ChatMessage(id:"invented-done",content:"A fictional comet.",isStreaming:false),serverSaysGenerating:false,generationRunning:false,reason:.chatOpened)
        check(completed.finished==1 && completed.resulting?.error==nil,"completed replies retain success")
        let cancelled=Subject();let task=Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(10));cancelled.failed(URLError(.networkConnectionLost),effectiveChatId:"invented-chat")
        };task.cancel();await task.value
        check(cancelled.recovery==0 && cancelled.updates==0,"cancelled send performs no recovery or error update")
        print("Passed \(count) completion acknowledgement checks")
    }
}

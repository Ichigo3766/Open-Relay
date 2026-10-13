import Foundation
import Darwin

@main struct ProjectionChecks {
    static func main() throws {
        if CommandLine.arguments.count==3 && CommandLine.arguments[1]=="--benchmark" {
            let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
            var before=rusage(),after=rusage();getrusage(RUSAGE_SELF,&before)
            let start=DispatchTime.now().uptimeNanoseconds
            let result=CachedConversationSnapshot.compact(data)
            let wall=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6;getrusage(RUSAGE_SELF,&after)
            func cpu(_ r:rusage)->Double {Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6}
            let values:[String:Any]=["input_bytes":data.count,"result_bytes":result?.count ?? 0,"cpu_ms":(cpu(after)-cpu(before))*1000,"wall_ms":wall,"peak_rss_mib":Double(after.ru_maxrss)/1048576]
            print(String(data:try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]),encoding:.utf8)!);return
        }
        var checks=0,failures=0
        func check(_ value:Bool,_ label:String) {checks+=1;if !value {failures+=1;print("FAIL",label)}}
        let prose="A fictional cardboard tower stores blue kites.\n\nEach numbered shelf belongs to an invented museum."
        let body=String(repeating:"A freshly invented indigo kite crosses a paper tower. ",count:100)
        let reasoning="<details type=\"reasoning\" done=\"true\" duration=\"2\"><summary>Thought for 2 seconds</summary>"+body+"</details>\n\nA fictional answer."
        let tool="<details type=\"tool_calls\" done=\"true\" name=\"inspect_kites\" result=\""+body+"\"><summary>Inspect kites</summary></details>\n\nA fictional answer."
        func wire(_ content:String,_ role:String="assistant",done:Bool=true,extras:[String:Any]=[:])->Data {
            var node:[String:Any]=["id":"invented-node","role":role,"content":content,"done":done]
            for (k,v) in extras {node[k]=v}
            return try! JSONSerialization.data(withJSONObject:["id":"invented-chat","chat":["title":"Invented kite display","history":["currentId":"invented-node","messages":["invented-node":node]],"messages":[node]]],options:[.sortedKeys])
        }
        for content in ["",prose,"No markup, only an invented kite.","Literal backslash: \\u003C", "🔭 日本語 é", "A JSON-like word: output.","<em>A fictional kite</em>","<details><summary>Ordinary</summary>"+body+"</details>"] {
            check(CachedConversationSnapshot.compact(wire(content))==nil,"ordinary content stays full")
        }
        for content in [reasoning,tool,"<think>"+body+"</think>A fictional answer."] {
            let data=wire(content),compact=CachedConversationSnapshot.compact(data)
            check(compact != nil,"completed details project")
            guard let compact else {continue}
            check(compact.count<data.count,"projection reduces bytes")
            let json=try JSONSerialization.jsonObject(with:compact) as! [String:Any],chat=json["chat"] as! [String:Any]
            check(chat[CachedConversationSnapshot.marker] as? Bool==true,"compact marker")
            let nodes=(chat["history"] as! [String:Any])["messages"] as! [String:[String:Any]]
            let flat=chat["messages"] as! [[String:Any]],projected=nodes["invented-node"]!["content"] as! String
            check(flat[0]["content"] as? String==projected,"tree and flat agree")
            check(CachedConversationSnapshot.hasDeferredContent(projected),"details can hydrate")
            check(projected.contains("A fictional answer."),"answer retained")
            check(CachedConversationSnapshot.compact(wire(content,"user"))==nil,"user content stays full")
            check(CachedConversationSnapshot.compact(wire(content,done:false))==nil,"unfinished assistant stays full")
            let escaped=String(data:data,encoding:.utf8)!.replacingOccurrences(of:"<",with:"\\u003c").replacingOccurrences(of:">",with:"\\u003E")
            check(CachedConversationSnapshot.compact(Data(escaped.utf8)) != nil,"Unicode-escaped tags still project")
            let escapedKeys=String(data:data,encoding:.utf8)!.replacingOccurrences(of:"\"content\"",with:"\"con\\u0074ent\"")
            check(CachedConversationSnapshot.compact(Data(escapedKeys.utf8)) != nil,"Unicode-escaped keys still project")
        }
        for (content,extras) in [(reasoning,["embeds":["<html>Invented view</html>"]]),(reasoning,["output":[["files":[["id":"invented-file"]]]]]),(tool,["output":[["name":"display_file"]]])] {
            check(CachedConversationSnapshot.compact(wire(content,extras:extras))==nil,"visible output stays full")
        }
        for content in [reasoning.replacingOccurrences(of:"done=\"true\"",with:"done=\"false\""),String(reasoning.dropLast(50)),tool.replacingOccurrences(of:"done=\"true\"",with:"done=\"false\"")] {
            check(CachedConversationSnapshot.compact(wire(content))==nil,"unfinished details stay full")
        }
        let structured:[[String:Any]]=[["type":"reasoning","status":"completed","content":[["type":"reasoning_text","text":body]]],["type":"message","content":[["type":"output_text","text":"A fictional answer."]]]]
        let structuredWire=wire("",extras:["output":structured]),structuredCompact=CachedConversationSnapshot.compact(structuredWire)
        check(structuredCompact != nil,"structured output reconstructs without literal tags")
        let escapedOutput=String(data:structuredWire,encoding:.utf8)!.replacingOccurrences(of:"\"output\"",with:"\"out\\u0070ut\"")
        check(CachedConversationSnapshot.compact(Data(escapedOutput.utf8)) != nil,"escaped output key reconstructs")
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let escapedReason = String(data: wire(reasoning), encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c")
            let structuredJSON = String(data: structuredWire, encoding: .utf8)!
            for value in [escapedReason, structuredJSON] {
                check(CachedConversationSnapshot.compact(value.data(using: encoding)!) != nil, "wide-encoded JSON still projects")
            }
        }
        for bytes in [Data(),Data("not JSON".utf8),Data("[]".utf8),Data("{\"output\":[]}".utf8),Data("{\"chat\":null}".utf8)] {check(CachedConversationSnapshot.compact(bytes)==nil,"invalid or missing chat")}
        print("\(checks-failures)/\(checks) cache-projection checks passed")
        if failures>0 {exit(1)}
    }
}

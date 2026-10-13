import Foundation
import Darwin

@main struct IdentityBenchmark {
    @MainActor static func main() throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let history=(json["chat"] as! [String:Any])["history"] as! [String:Any]
        let nodes=history["messages"] as! [String:[String:Any]]
        let tree=MessageHistory(nodes:Dictionary(uniqueKeysWithValues:nodes.map {($0.key,MessageHistory.parseNode(id:$0.key,from:$0.value))}),currentId:history["currentId"] as? String)
        let messages=tree.createMessagesList()
        let v=ChatRowVirtualizer();v.updateWidth(393);v.updateViewport(top:1000,height:800)
        let current=v.updatedRange(messages:messages,current:nil)
        var before=rusage(),after=rusage();getrusage(RUSAGE_SELF,&before)
        let start=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {v.updateAnchor(messages:messages);_ = v.updatedRange(messages:messages,current:current)}
        let wall=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6;getrusage(RUSAGE_SELF,&after)
        func cpu(_ r:rusage)->Double {Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6}
        let result:[String:Any]=["messages":messages.count,"iterations":100,"cpu_ms":(cpu(after)-cpu(before))*1000,"wall_ms":wall,"peak_rss_mib":Double(after.ru_maxrss)/1048576]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    }
}

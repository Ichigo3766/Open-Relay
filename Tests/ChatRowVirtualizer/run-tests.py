"""Compile the production virtualizer with invented heights and a scroll-view stub."""
from pathlib import Path
import argparse
import os
import subprocess

parser = argparse.ArgumentParser()
repo = Path(__file__).resolve().parents[2]
parser.add_argument("--source", type=Path, default=repo / "Open UI/Features/Chat/Views/ChatRowVirtualizer.swift")
parser.add_argument("--view-source", type=Path)
parser.add_argument("--benchmark", type=Path)
parser.add_argument("--benchmark-operation", choices=["identity", "render", "render-forced"], default="identity")
parser.add_argument("--value-traversal-control", action="store_true", help="Use the previous two value traversals in the extracted render benchmark.")
parser.add_argument("output", type=Path)
args = parser.parse_args()
out = args.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit("Keep generated binaries and caches outside the checkout.")
out.mkdir(parents=True, exist_ok=True)
(out / "tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"] = str(out / "tmp") + "/"
source = args.source.read_text().replace("import SwiftUI\nimport UIKit", "import Foundation")
stubs = """import Foundation
import CoreGraphics
@MainActor final class UIScreen {static let main=UIScreen();let bounds=CGRect(x:0,y:0,width:393,height:852)}
@MainActor final class UIScrollView {var adjustedContentInset=Insets();var contentOffset=CGPoint.zero;struct Insets {var top:CGFloat=0}}
enum MessageRole {case user,assistant}
struct ChatMessage {let id:String;let role:MessageRole;let content:String;let files=[Int]();let isInternalMessage=false}
"""
bridge = "@MainActor func report(_ v:ChatRowVirtualizer,_ id:String,_ index:Int,_ y:CGFloat,_ h:CGFloat,_ drawn:Bool) {"
if "func report(id: String, index:" in source:
    bridge += "v.report(id:id,index:index,height:h" + (",isDrawn:drawn" if "height: CGFloat, isDrawn: Bool" in source else "") + ")"
else:
    bridge += "v.report(id:id,minY:y,height:h,isDrawn:drawn)"
bridge += "}\n"
view = (args.view_source or args.source.with_name("ChatDetailView.swift")).read_text()
rendering = ""
groups = "@MainActor func verifyRenderGroups(_ check:(Bool,String)->Void) {}\n"
if "private enum ChatRenderItemID" in view:
    enum_start = view.index("    private enum ChatRenderItemID")
    enum_end = view.index("    private var messagesList", enum_start)
    start = view.index("        let allMessages = viewModel.messages", enum_end)
    end = view.index("        return ForEach(items", start)
    rendering = view[enum_start:enum_end].replace("private enum", "enum") + """
struct Stream {var isActive=false;var streamingMessageId:String?}
struct Owner {var messages:[ChatMessage];var streamingStore=Stream();var isStreaming=false}
@MainActor struct Renderer {
 var viewModel:Owner
 var drawnRange:ClosedRange<Int>?
 var editingMessageId:String?
 var heldReservationTurnId:String?
 var viewState_containerHeight:CGFloat=800
 let virtualizer:ChatRowVirtualizer
 func items() -> [(id:ChatRenderItemID,rows:[(index:Int,message:ChatMessage,isDrawn:Bool)]?,height:CGFloat)] {
""" + view[start:end] + "return items\n}\n}\n"
    groups = (Path(__file__).with_name("RenderGroupChecks.swift")).read_text()
if args.benchmark:
    stubs = stubs[:stubs.index("enum MessageRole")] + "enum InlineImageStore {static func extractAndReplace(content:String)->String {content}}\n"
    benchmark = "IdentityBenchmark.swift"
    if args.benchmark_operation != "identity":
        if not rendering:
            raise SystemExit("Render benchmarks require an aggregate-render view source.")
        if args.value_traversal_control:
            replacements = {
                "allMessages.indices.first { allMessages[$0].id == id }": "allMessages.firstIndex { $0.id == id }",
                "for index in allMessages.indices where allMessages[index].role == .user || turnStarts.isEmpty {": "for (index, message) in allMessages.enumerated() where message.role == .user || turnStarts.isEmpty {",
            }
            for new, previous in replacements.items():
                if rendering.count(new) != 1:
                    raise SystemExit("Expected one indexed traversal in the production render source.")
                rendering = rendering.replace(new, previous)
        benchmark = "RenderBenchmark.swift"
    else:
        rendering = ""
        if args.value_traversal_control:
            raise SystemExit("The value-traversal control applies to render benchmarks only.")
    subject = out / "BenchmarkSubject.swift"
    subject.write_text(stubs + source + rendering + Path(__file__).with_name(benchmark).read_text())
    models = repo / "Open UI/Core/Models"
    files = [models / (n + ".swift") for n in ["ChatMessage", "Conversation", "MessageHistory", "ChatAdvancedParams", "ChatContextUsage"]]
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules"),
                    *(str(f) for f in files), str(subject), "-o", str(out / "checks")], check=True)
    subprocess.run([str(out / "checks"), str(args.benchmark), *(["forced"] if args.benchmark_operation == "render-forced" else [])], check=True)
    raise SystemExit()

subject = out / "Subject.swift"
subject.write_text(stubs + source + bridge + rendering + groups + (Path(__file__).with_name("AnchorChecks.swift")).read_text())
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules"),
                str(subject), "-o", str(out / "checks")], check=True)
subprocess.run([str(out / "checks")], check=True)

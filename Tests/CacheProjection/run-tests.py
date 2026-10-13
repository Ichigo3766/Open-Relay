"""Compile production cache projection, structural parsers and history models."""
from pathlib import Path
import argparse, os, subprocess
repo=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument("--source",type=Path,default=repo/"Open UI/Core/Services/CachedConversationSnapshot.swift")
p.add_argument("--benchmark",type=Path)
p.add_argument("output",type=Path)
a=p.parse_args();out=a.output.resolve()
if out==repo or repo in out.parents:raise SystemExit("Use an output directory outside the checkout.")
out.mkdir(parents=True,exist_ok=True);(out/"tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"]=str(out/"tmp")+"/"
tool=(repo/"Open UI/Shared/Components/ToolCallView.swift").read_text()
parser=tool[tool.index("// MARK: - Tool Call Data"):tool.index("// MARK: - Rich UI Height Cache")]
(out/"Parser.swift").write_text("import Foundation\n"+parser+"\nstruct TerminalFileAttachment {init(result:String?,arguments:String?) {}}\nenum InlineImageStore {static func extractAndReplace(content:String)->String {content}}\n")
(out/"Projection.swift").write_text(a.source.read_text())
models=repo/"Open UI/Core/Models";services=repo/"Open UI/Core/Services"
files=[models/(n+".swift") for n in ["ChatMessage","Conversation","MessageHistory","ChatAdvancedParams","ChatContextUsage"]]
files += [services/(n+".swift") for n in ["DetailsBlockScanner","DetailsBlockScanner+Bytes","DetailsBlockScanner+Scan","DetailsBlockScanner+Code"]]
files += [out/"Parser.swift",out/"Projection.swift",Path(__file__).with_name("ProjectionChecks.swift")]
subprocess.run(["swiftc","-O","-parse-as-library","-module-cache-path",str(out/"modules"),*(str(f)for f in files),"-o",str(out/"checks")],check=True)
subprocess.run([str(out/"checks"),*(["--benchmark",str(a.benchmark)] if a.benchmark else [])],check=True)

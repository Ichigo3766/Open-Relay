"""Compile production history methods and model types with synthetic ownership."""
from pathlib import Path
import argparse
import os
import subprocess

repo = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=repo / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift")
parser.add_argument("--benchmark", nargs=2, metavar=("ROWS", "MODE"))
parser.add_argument("output", type=Path)
args = parser.parse_args()
out = args.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit("Keep generated binaries and module caches outside the checkout.")
if args.benchmark and (int(args.benchmark[0]) <= 0 or args.benchmark[1] not in ["adopt", "load", "adopt-aligned", "metadata"]):
    raise SystemExit("Benchmark requires a positive row count and mode adopt, load, adopt-aligned or metadata.")
out.mkdir(parents=True, exist_ok=True)
(out / "tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"] = str(out / "tmp") + "/"
source = args.source.read_text()
a = source.index("    func adoptServerMessages(")
b = source.index("\n    // MARK: - Entry Sync", a)
adopt = source[a:b]
a = source.index("    private func prepareLoadedConversation(")
b = source.index("\n    /// Syncs local conversation state", a)
load = source[a:b].replace("private func", "func", 1)
a = source.index("    private func applyContextMetadata(")
b = source.index("\n    /// Bumped each time", a)
metadata = source[a:b].replace("private func", "func", 1)
stubs = """import Foundation
import Observation
import Darwin
// These tests construct model values directly; no image extraction or networking runs.
enum InlineImageStore {static func extractAndReplace(content:String)->String{content}}
struct SyntheticModel {var id:String}
@MainActor final class StreamStore {var streamingMessageId:String?;var isActive=false}
@MainActor final class Logger {func info(_ message:String){} }
@MainActor @Observable final class Subject {
    var conversation:Conversation? {didSet {writes+=1}}
    @ObservationIgnored var writes=0
    var isStreaming=false
    var isSavingContext=false
    var selectedModelId:String?
    var deletedMessageIds=Set<String>()
    var tasks=[ChatTask]()
    let logger=Logger()
    let streamingStore=StreamStore()
    var chatFiles:[ChatMessageFile] {
        get {conversation?.files ?? []}
        set {conversation?.files=newValue}
    }
    var availableModels=[SyntheticModel]()
    var userDisabledBuiltinFeatures=Set<String>()
    var conversationId:String?
    var contextNeedsRefresh=true
    var backfills=0
    var restores=0
    var scans=0
    func backfillLegacyChatContextIfNeeded(){backfills+=1}
    func restoreToolApprovalMode(){restores+=1}
    func scanForPendingToolActions(){scans+=1}
    func syncCurrentIdToServer() async {}
"""
subject = out / "Subject.swift"
subject.write_text(stubs + adopt + load + metadata + "\n}\n" + Path(__file__).with_name("HistoryChecks.swift").read_text())
models = repo / "Open UI/Core/Models"
files = [models / (name + ".swift") for name in
         ["ChatMessage", "Conversation", "MessageHistory", "ChatAdvancedParams", "ChatContextUsage"]]
subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "modules"),
                *(str(file) for file in files), str(subject), "-o", str(out / "checks")], check=True)
subprocess.run([str(out / "checks"), *( ["--benchmark", *args.benchmark] if args.benchmark else [] )], check=True)

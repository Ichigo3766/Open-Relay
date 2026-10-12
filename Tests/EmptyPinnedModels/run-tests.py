from pathlib import Path
import argparse,os,subprocess
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[2]/'Open UI/Features/Chat/ViewModels/ChatViewModel.swift');args=p.parse_args()
out=args.output.resolve();repo=Path(__file__).resolve().parents[2]
if out == repo or repo in out.parents:raise SystemExit('Keep generated binaries outside the checkout.')
out.mkdir(parents=True,exist_ok=True);(out/'tmp').mkdir(exist_ok=True);os.environ['TMPDIR']=str(out/'tmp')+'/'
source=args.source.read_text();start=source.index('    func fetchPinnedModels() async {');end=source.index('    /// Toggles a model',start)
qstart=source.index("    func fetchMessageQueueSettingFromServer() async {");qend=source.index("    /// Persists the message queue toggle state",qstart)
stub="""import Foundation
import Observation
@MainActor final class Store { var cachedPinnedModelIds: [String]?; var cachedMessageQueueSetting: Bool?; var generation = UUID()
    func clear() { generation = UUID(); cachedPinnedModelIds = nil; cachedMessageQueueSetting = nil }
}
@MainActor final class Logger { func debug(_ message: String) {} }
@MainActor final class SyntheticAPI {
    var hold = false; var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() { let pending=waiters;waiters.removeAll();hold=false;for waiter in pending { waiter.resume() } }
    var settings: [String: Any]; var fail = false; var calls = 0; var bytes = 0; var delay = 0
    init(_ settings: [String: Any]) { self.settings = settings }
    func getUserSettings() async throws -> [String: Any] {
        calls += 1
        if hold { await withCheckedContinuation { waiters.append($0) } }
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        if fail { throw NSError(domain: "org.example.synthetic", code: 1) }
        bytes += try JSONSerialization.data(withJSONObject: settings, options: .sortedKeys).count
        return settings
    }
}
@MainActor final class Manager { let apiClient: SyntheticAPI; init(_ api: SyntheticAPI) { apiClient = api } }
@MainActor @Observable final class Subject {
    var pinnedModelIds: [String] = []
    var enableMessageQueue = false
    var activeChatStore: Store?
    var manager: Manager?
    let logger = Logger()
    init(_ api: SyntheticAPI?, _ store: Store?) { manager = api.map(Manager.init); activeChatStore = store }
"""+source[start:end]+source[qstart:qend]+"\n}\n"
(out/'Subject.swift').write_text(stub);(out/'Checks.swift').write_text((Path(__file__).parent/'Checks.swift').read_text())
subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(out/'modules'),str(out/'Subject.swift'),str(out/'Checks.swift'),'-o',str(out/'checks')],check=True)
raise SystemExit(subprocess.run([str(out/'checks')]).returncode)

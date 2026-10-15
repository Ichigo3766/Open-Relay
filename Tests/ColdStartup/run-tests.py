"""Exercise production discovery/cache/loading methods with invented data only."""
from pathlib import Path
import argparse, os, subprocess
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[2]);a=p.parse_args()
r=Path(__file__).resolve().parent;src=a.source_root;out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
if src.resolve() in [out,*out.parents]:raise SystemExit('Keep build output outside the checkout.')
def section(s,start,end):
    i=s.index(start);return s[i:s.index(end,i)]
auth=(src/'Open UI/Features/Auth/ViewModels/AuthViewModel.swift').read_text()
api=(src/'Open UI/Core/Networking/APIClient.swift').read_text();vm=(src/'Open UI/Features/Chat/ViewModels/ChatViewModel.swift').read_text()
methods=section(api,'    func getModels()','    /// Fetches all models including')+section(api,'    func getDefaultModel()','    func getModelDetails(')
if 'func cachedModelDiscovery(' not in methods:methods+='    func cachedModelDiscovery() async -> (models:[AIModel],defaultId:String?)? { nil }\n'
cache=(src/'Open UI/Core/Services/ConversationCache.swift').read_text().replace('static let shared = ConversationCache()', 'static let shared = ConversationCache(directory: FixtureStorage.directory, defaults: FixtureStorage.defaults)')
if 'func cachedMetadata(' not in cache:cache=cache.replace('    private func read(scope:', '    func cachedMetadata(scope:String?,id:String)->Data? { nil }\n    func saveMetadata(_ data:Data?,scope:String?,id:String,revision:UUID) {}\n    private func read(scope:',1)
code=(r/'checks.swift').read_text().replace('// INSERT_CACHE',cache).replace('// INSERT_API',methods).replace('// INSERT_LOAD',section(vm,'    func load() async {','        // Ensure socket is connected')+'    }').replace('// INSERT_AUTH',section(auth,'    func restoreSession() async','    /// Manually retries session restore.')).replace('// INSERT_MODELS',section(vm,'    func loadModels() async','    /// Silently refreshes'))
(out/'Checks.swift').write_text(code);(out/'tmp').mkdir(exist_ok=True)
env=dict(os.environ,TMPDIR=str(out/'tmp'),SWIFT_MODULECACHE_PATH=str(out/'modules'),CLANG_MODULE_CACHE_PATH=str(out/'modules'))
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(src/'Open UI/Core/Networking/APIError.swift'),str(out/'Checks.swift'),'-o',str(out/'checks')],env=env,check=True)
subprocess.run([str(out/'checks'),str(out/'cache')],env=env,check=True)

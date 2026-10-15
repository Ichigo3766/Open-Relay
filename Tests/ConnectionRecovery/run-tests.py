"""Compile production socket/monitor code against invented transports; no live server."""
from pathlib import Path
import argparse, os, subprocess
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[2]);a=p.parse_args()
r=Path(__file__).resolve().parent;out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
if a.source_root.resolve() in [out,*out.parents]:raise SystemExit('Keep build output outside the checkout.')
socket=(a.source_root/'Open UI/Core/Networking/SocketIOService.swift').read_text().replace('private','fileprivate')
monitor=(a.source_root/'Open UI/Core/Services/ServerConnectionMonitor.swift').read_text().replace('import Network','').replace('private','fileprivate')
# Accelerate only the fallback poll; negotiated socket timings are supplied by fixtures.
monitor=monitor.replace('let interval = self.currentPollInterval()', 'let interval = await self.currentPollInterval()')
monitor=monitor.replace('URLSession.shared', 'ExternalFixture.session')
monitor=monitor.replace('connectedPollInterval: TimeInterval = 30','connectedPollInterval: TimeInterval = 0.06').replace('Task.sleep(for: .seconds(2))','Task.sleep(for: .seconds(0.06))')
# The upstream control predates the callback; this unused fixture field keeps it compilable.
if 'var onServerPing:' not in socket:socket=socket.replace('    var onConnect:', '    var onServerPing: (() -> Void)?\n    var onConnect:',1)
if 'func recordConnectionResult(' not in monitor:monitor=monitor.replace('    // MARK: - NWPathMonitor','    @MainActor func recordConnectionResult(_ connected: Bool) {}\n    // MARK: - NWPathMonitor',1)
code=(r/'checks.swift').read_text().replace('// INSERT_SOCKET',socket).replace('// INSERT_MONITOR',monitor)
(out/'Checks.swift').write_text(code);(out/'tmp').mkdir(exist_ok=True)
env=dict(os.environ,TMPDIR=str(out/'tmp'),SWIFT_MODULECACHE_PATH=str(out/'modules'),CLANG_MODULE_CACHE_PATH=str(out/'modules'))
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(out/'Checks.swift'),'-o',str(out/'checks')],env=env,check=True)
subprocess.run([str(out/'checks')],env=env,check=True)

network=(a.source_root/'Open UI/Core/Networking/NetworkManager.swift').read_text()
i=network.index('    private func performRequest(');j=network.index('    /// Retries',i)
method=network[i:j].replace('private func','func',1)
(out/'Network.swift').write_text((r/'network-checks.swift').read_text().replace('// INSERT_PERFORM',method))
subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(a.source_root/'Open UI/Core/Networking/APIError.swift'),str(out/'Network.swift'),'-o',str(out/'network')],env=env,check=True)
subprocess.run([str(out/'network')],env=env,check=True)

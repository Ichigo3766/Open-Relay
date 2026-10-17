"""Compile the production connection monitor against invented, in-process transports."""
from pathlib import Path
import argparse
import os
import subprocess

p = argparse.ArgumentParser()
p.add_argument('output', type=Path)
p.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[2])
a = p.parse_args()
out = a.output.resolve()
source = a.source_root.resolve()
if source == out or source in out.parents:
    raise SystemExit('Keep build output outside the checkout.')
out.mkdir(parents=True, exist_ok=True)
monitor = (source / 'Open UI/Core/Services/ServerConnectionMonitor.swift').read_text()
monitor = monitor.replace('import Network', '').replace('private', 'fileprivate')
monitor = monitor.replace('let interval = self.currentPollInterval()', 'let interval = await self.currentPollInterval()')
monitor = monitor.replace('URLSession.shared', 'ExternalFixture.session')
code = Path(__file__).with_name('checks.swift').read_text().replace('// INSERT_MONITOR', monitor)
(out / 'Checks.swift').write_text(code)
(out / 'tmp').mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(out / 'tmp'), SWIFT_MODULECACHE_PATH=str(out / 'modules'), CLANG_MODULE_CACHE_PATH=str(out / 'modules'))
subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library', str(out / 'Checks.swift'), '-o', str(out / 'checks')], env=env, check=True)
subprocess.run([str(out / 'checks')], env=env, check=True)

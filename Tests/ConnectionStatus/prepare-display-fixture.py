"""Add a display-state hook to a disposable Open Relay checkout, for native UI tests only."""
from pathlib import Path
import argparse

p = argparse.ArgumentParser()
p.add_argument('disposable_checkout', type=Path)
a = p.parse_args()
root = a.disposable_checkout.resolve()
view = root / 'Open UI/Features/Chat/Views/ChatDetailView.swift'
monitor = (root / 'Open UI/Core/Services/ServerConnectionMonitor.swift').read_text()
s = view.read_text()
anchor = '        .onAppear {\n            dependencies.activeChatStore.appeared(viewModel)'
if s.count(anchor) != 1 or 'SYNTHETIC_STATUS_FIXTURE' in s:
    raise SystemExit('Expected one uninstrumented ChatDetailView in a disposable checkout.')
hook = '''
        // Native UI test fixture. Never distribute this build.
        if let fixture = ProcessInfo.processInfo.environment["SYNTHETIC_STATUS_FIXTURE"] {
            if fixture == "draft" {
                viewModel.inputText = (1...12).map { "Invented clockwork planet sample \\($0)." }.joined(separator: "\\n")
            }
            Task { @MainActor in
                for _ in 0..<400 {
                    let monitor = dependencies.connectionMonitor
                    monitor.connectionState = fixture == "offline" ? .internetDown : fixture == "server" || fixture == "blocking" ? .serverDown : fixture == "checking" || fixture == "reconnecting" ? .checking : .connected
                    monitor.disconnectedSince = fixture == "reconnecting" ? Date().addingTimeInterval(-10) : nil
                    CONTROL_FLAGS
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
'''
flags = ''
if 'var isShowingOverlay:' in monitor:
    flags = 'monitor.isShowingOverlay = ["server", "blocking", "offline"].contains(fixture)\n                    monitor.hasCachedContent = fixture != "blocking"'
hook = hook.replace('CONTROL_FLAGS', flags)
view.write_text(s.replace(anchor, '        .onAppear {\n' + hook + '            dependencies.activeChatStore.appeared(viewModel)', 1))
updates = root / 'Open UI/Core/Services/UpdateChecker.swift'
updates.write_text(updates.read_text().replace('https://itunes.apple.com/lookup', 'http://127.0.0.1:18365/audit/app-update'))
print('Prepared a synthetic display-only test build. Use a disposable simulator.')

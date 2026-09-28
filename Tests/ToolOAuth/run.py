#!/usr/bin/env python3
"""Compile the actual connection policy against fresh synthetic state."""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent

def block(path, marker):
    text = (ROOT / path).read_text()
    start = text.index(marker)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

model = block('Open UI/Shared/Components/ToolsMenuSheet.swift', 'struct ToolItem:')
urls = block('Open UI/Shared/Components/ToolConnectionView.swift', 'extension ToolItem')
fetch = block('Open UI/Core/Services/ConversationManager.swift', '    func fetchTools()')
if '--baseline-auth' in sys.argv:
    baseline = subprocess.check_output(['git', 'show', '4151a735:Open UI/Core/Services/ConversationManager.swift'], cwd=ROOT, text=True)
    start = baseline.index('    func fetchTools()')
    fetch = baseline[start:baseline.index('\n    // MARK: - Chat Completion', start)]
gate = block('Open UI/Features/Chat/ViewModels/ChatViewModel.swift', '    private func checkToolConnections()').replace('private func', 'func', 1)
refresh = block('Open UI/Shared/Components/ToolConnectionView.swift', '    @MainActor private func refresh()').replace('@MainActor private func', 'func', 1)
source = (HERE / 'Checks.swift').read_text().replace('// MODEL', model + '\n' + urls).replace('// FETCH', fetch).replace('// GATE', gate).replace('// REFRESH', refresh)
with tempfile.TemporaryDirectory(prefix='relay-tool-oauth-') as scratch:
    source_path = Path(scratch) / 'Checks.swift'
    source_path.write_text(source)
    binary = Path(scratch) / 'checks'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source_path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

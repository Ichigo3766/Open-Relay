#!/usr/bin/env python3
"""Run the actual cache implementation against synthetic responses in a disposable directory."""
from pathlib import Path
import subprocess
import argparse
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--baseline-ref', help='Run the navigation regression against a previous Git revision (expected to fail)')
args = parser.parse_args()
tests = Path(__file__).parent
with tempfile.TemporaryDirectory(prefix='relay-cache-tests-') as directory:
    binary = str(Path(directory) / 'checks')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root/'Open UI/Core/Networking/APIError.swift'),
                    str(root/'Open UI/Core/Services/ConversationCache.swift'),
                    str(root/'Open UI/Core/Services/ConversationIndex.swift'),
                    str(Path(__file__).parent/'Fixtures.swift'),
                    str(Path(__file__).parent/'Checks.swift'), '-o', binary], check=True)
    subprocess.run([binary], check=True, timeout=30)
    source = (root/'Open UI/Features/Chat/ViewModels/ChatListViewModel.swift').read_text()
    methods = source[source.index('    func loadConversations()'):source.index('    // MARK: - Search')]
    harness = (tests/'SidebarChecks.swift').read_text().replace('// PRODUCTION_METHODS', methods.replace('ConversationCache.shared', 'testCache'))
    # Shared synthetic gate/server helpers, without the other test executable's main.
    helpers = (tests/'Checks.swift').read_text().split('struct Failure: Error')[1]
    generated = Path(directory)/'Sidebar.swift'
    generated.write_text(harness + '\nstruct Failure: Error' + helpers)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root/'Open UI/Core/Networking/APIError.swift'),
                    str(root/'Open UI/Core/Services/ConversationCache.swift'),
                    str(root/'Open UI/Core/Services/ConversationIndex.swift'),
                    str(tests/'Fixtures.swift'), str(generated), '-o', binary], check=True)
    subprocess.run([binary], check=True, timeout=30)
    for name, path, start, end in [
        ('API', 'Open UI/Core/Networking/APIClient.swift', '    func cachedConversation(', '    /// Creates a new permanent chat'),
        ('Load', 'Open UI/Features/Chat/ViewModels/ChatViewModel.swift', '    func loadConversation(', '    /// Syncs local conversation state with the server.')]:
        source = (root/path).read_text()
        if args.baseline_ref and name == 'API':
            source = subprocess.check_output(['git', 'show', f'{args.baseline_ref}:{path}'], cwd=root, text=True)
            start = '    func getConversation('
        methods = source[source.index(start):source.index(end, source.index(start))]
        harness = (tests/f'{name}Checks.swift').read_text().replace('// PRODUCTION_METHODS', methods.replace('ConversationCache.shared', 'testCache'))
        if name == 'Load':
            startup = source[source.index('    func load() async {'):source.index('        // Ensure socket is connected')]
            harness = harness.replace('// STARTUP_METHOD', startup + '    }')
        if name == 'API':
            page_method = source[source.index('    func getConversationsPage('):source.index('    /// Fetches all pinned conversations')]
            harness = harness.replace('// PAGE_METHOD', page_method.replace('ConversationCache.shared', 'testCache'))
        harness = harness.replace('/* NAVIGATION */', '' if args.baseline_ref else ', preferRecent: true')
        generated = Path(directory)/f'{name}.swift'
        generated.write_text(harness + '\nstruct Failure: Error' + helpers)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                        str(root/'Open UI/Core/Networking/APIError.swift'),
                        str(root/'Open UI/Core/Services/ConversationCache.swift'),
                        str(root/'Open UI/Core/Services/ConversationIndex.swift'),
                        str(tests/'Fixtures.swift'), str(generated), '-o', binary], check=True)
        subprocess.run([binary], check=True, timeout=30)

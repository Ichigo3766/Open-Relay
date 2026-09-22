#!/usr/bin/env python3
"""Compile production Swift against disposable synthetic fixtures; never contact a live server."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
tests = Path(__file__).parent
parser = argparse.ArgumentParser()
parser.add_argument('--baseline-ref', help='Run navigation against a previous Git revision (expected to fail)')
parser.add_argument('--only', nargs='+', choices=['Cache', 'Sidebar', 'API', 'Load', 'Network'])
parser.add_argument('--repeat', type=int, default=1, help='Runs per compiled executable')
parser.add_argument('--sanitize-thread', action='store_true')
args = parser.parse_args()
if args.repeat < 1:
    parser.error('--repeat must be positive')

helpers = 'struct Failure: Error' + (tests/'Checks.swift').read_text().split('struct Failure: Error', 1)[1]
common = [root/'Open UI/Core/Networking/APIError.swift', root/'Open UI/Core/Services/ConversationCache.swift',
          root/'Open UI/Core/Services/ConversationIndex.swift', tests/'Fixtures.swift']

def between(source, start, end):
    offset = source.index(start)
    return source[offset:source.index(end, offset)]

with tempfile.TemporaryDirectory(prefix='relay-cache-tests-') as directory:
    for name in args.only or ['Cache', 'Sidebar', 'API', 'Load', 'Network']:
        flags = ['-sanitize=thread'] if args.sanitize_thread else []
        extra = []
        if name == 'Cache':
            harness = (tests/'Checks.swift').read_text()
        else:
            harness = (tests/f'{name}Checks.swift').read_text()
            if name == 'Sidebar':
                source = (root/'Open UI/Features/Chat/ViewModels/ChatListViewModel.swift').read_text()
                methods = between(source, '    func loadConversations()', '    // MARK: - Search')
                for marker, declaration in [('CONVERSATIONS_PROPERTY', '    var conversations:'), ('PINNED_PROPERTY', '    var pinnedConversations:')]:
                    harness = harness.replace('// ' + marker, between(source, declaration, '\n\n'))
            elif name == 'Load':
                source = (root/'Open UI/Features/Chat/ViewModels/ChatViewModel.swift').read_text()
                methods = between(source, '    func loadConversation(', '    /// Syncs local conversation state with the server.')
                harness = harness.replace('// STARTUP_METHOD', between(source, '    func load() async {', '        // Ensure socket is connected') + '    }')
                harness = harness.replace('// REMOVE_FILE_METHOD', between(source, '    func removeFile(', '    // MARK: - Prompt Slash Commands'))
                harness = harness.replace('// TREE_SYNC_METHOD', between(source, '    private func syncToServerViaTree()', '    var selectedModel:'))
            elif name == 'API':
                path = 'Open UI/Core/Networking/APIClient.swift'
                source = subprocess.check_output(['git', 'show', f'{args.baseline_ref}:{path}'], cwd=root, text=True) if args.baseline_ref else (root/path).read_text()
                start = '    func getConversation(' if args.baseline_ref else '    func cachedConversation('
                methods = between(source, start, '    /// Creates a new permanent chat')
                harness = harness.replace('// PAGE_METHOD', between(source, '    func getConversationsPage(', start))
                harness = harness.replace('// SUMMARY_METHOD', between(source, '    private func parseConversationSummary(', '    nonisolated private func parseFullConversation('))
                harness = harness.replace('/* NAVIGATION */', '' if args.baseline_ref else ', preferRecent: true')
                if args.baseline_ref:
                    flags += ['-D', 'BASELINE']
            elif name == 'Network':
                source = (root/'Open UI/Core/Networking/NetworkManager.swift').read_text()
                old_init = between(source, '    init(serverConfig:', '    // MARK: - Request Building')
                new_init = """    init(serverConfig: ServerConfig, session: URLSession, cache: ConversationCache) {
        self.serverConfig = serverConfig
        self.keychain = KeychainService()
        self.session = session
        self.certificateDelegate = nil
        self.testCache = cache
        super.init()
    }
"""
                # Only dependency construction is replaced. The complete production transport,
                # authentication, mutation hooks, response validation and request builders compile unchanged.
                source = source.replace(old_init, new_init).replace('    let session: URLSession', '    let session: URLSession\n    let testCache: ConversationCache', 1)
                network = Path(directory)/'NetworkManager.swift'
                network.write_text(source.replace('ConversationCache.shared', 'testCache'))
                extra = [str(network), str(root/'Open UI/Core/Networking/SSEStream.swift')]
                methods = ''
            else:
                raise NotImplementedError(name)
            harness = harness.replace('// PRODUCTION_METHODS', methods).replace('ConversationCache.shared', 'testCache') + '\n' + helpers
        generated = Path(directory)/f'{name}.swift'
        binary = Path(directory)/name
        generated.write_text(harness)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *flags, *map(str, common), *extra, str(generated), '-o', str(binary)], check=True)
        for _ in range(args.repeat):
            subprocess.run([str(binary)], check=True, timeout=60)

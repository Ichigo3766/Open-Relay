"""Compile actual conversation parsing and models against freshly invented fixtures."""
import argparse
import json
import os
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--source-root', type=Path, default=repo)
parser.add_argument('--benchmark', type=int)
args = parser.parse_args()
out = args.output.resolve()
if out == repo or repo in out.parents:
    raise SystemExit('Generated files must be outside the checkout.')
out.mkdir(parents=True, exist_ok=True)
(out / 'tmp').mkdir(exist_ok=True)
os.environ['TMPDIR'] = str(out / 'tmp') + '/'
source = (args.source_root / 'Open UI/Core/Networking/APIClient.swift').read_text()
parts = []
for start, end in [
    ('    nonisolated func parseFullConversation(', '    /// Builds a `MessageHistory`'),
    ('    nonisolated static func buildHistoryFromFlatMessages(', '    private func parseMessages('),
    ('    nonisolated private func parseSingleMessage(', '    private func buildChatPayload('),
]:
    a = source.index(start)
    parts.append(source[a:source.index(end, a)])
(out / 'Subject.swift').write_text('''import Foundation
import Darwin
// No fixture contains inline image data; image registration is outside this test's scope.
nonisolated enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }
nonisolated enum CachedConversationSnapshot { static let marker = "openrelay_cache_compact" }
final class Subject {
''' + '\n'.join(parts) + '\n}\n' + Path(__file__).with_name('DecodingChecks.swift').read_text())
models = args.source_root / 'Open UI/Core/Models'
subprocess.run(['swiftc', '-O', '-parse-as-library', '-module-cache-path', str(out / 'modules'),
    *[str(models / (name + '.swift')) for name in
      ['ChatMessage', 'Conversation', 'MessageHistory', 'ChatAdvancedParams', 'ChatContextUsage']],
    str(out / 'Subject.swift'), '-o', str(out / 'checks')], check=True)
arguments = []
if args.benchmark:
    n = args.benchmark
    if n < 2:
        raise SystemExit('Benchmark needs at least two rows.')
    nodes = {}
    for i in range(n):
        node = {'id': f'fixture-{i}', 'parentId': f'fixture-{i-1}' if i else None,
                'childrenIds': [f'fixture-{i+1}'] if i + 1 < n else [],
                'role': 'assistant' if i % 2 else 'user', 'timestamp': 1700000000 + i,
                'content': f'Invented violet telescope {i}. ' + 'The paper comet follows a chalk orbit. ' * 4,
                'done': True}
        nodes[node['id']] = node
    fixture = out / 'fixture.json'
    fixture.write_text(json.dumps({'id': 'fixture-chat', 'chat': {'title': 'Invented telescope',
        'history': {'messages': nodes, 'currentId': f'fixture-{n-1}'}, 'messages': list(nodes.values())}}, separators=(',', ':')))
    arguments = ['--benchmark', str(fixture), str(n)]
subprocess.run([str(out / 'checks'), *arguments], check=True)

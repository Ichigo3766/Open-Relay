from pathlib import Path
import os
import argparse,subprocess,resource
p=argparse.ArgumentParser();p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);p.add_argument('output',type=Path);args=p.parse_args()
out=args.output.resolve()
repo=Path(__file__).resolve().parents[2]
if out == repo or repo in out.parents:raise SystemExit("Keep generated binaries outside the checkout.")
out.mkdir(parents=True,exist_ok=True)
(out / "tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"] = str(out / "tmp") + "/"
source=(args.root/'Open UI/Features/Chat/ViewModels/ChatViewModel.swift').read_text()
start=source.index('        conversation?.messages.append(ChatMessage(')
end=source.index('\n\n',start)
append=source[start:end]
author='        let sharedAuthor = isSharedChat ? viewerUserId : nil'
shared=(args.root/'Open UI/Features/Chat/ViewModels/ChatViewModel+SharedChat.swift').read_text()
start=shared.index('    var isSharedChat: Bool {');end=shared.index('\n    }',start)+6
getter=shared[start:end]
method=(args.root/'Open UI/Core/Models/MessageHistory.swift').read_text()
start=method.index('    func withAuthor(id: String?, name: String?) -> ChatMessage {');end=method.index('\n    }',start)+6
method=method[start:end]
body=(author+'\n'+append) if source.index(author)<source.index(append) else (append+'\n'+author)
stub = """import Foundation
import Observation
struct ChatMessage {
    var id: String; var role: Role; var content: String; var timestamp: Date
    var model: String; var isStreaming: Bool
    var authorId: String?; var authorName: String?
    enum Role { case assistant, user }
""" + method + "\n}\n" + """
struct Conversation {
    var owner: String?
    var messages: [ChatMessage] = []
    func isShared(withViewer viewer: String?) -> Bool {
        guard let viewer, let owner else { return false }
        return owner != viewer
    }
}
@MainActor @Observable final class Subject {
    var conversation: Conversation?
    var viewerUserId: String?
""" + getter + "\n    func append() -> String? {\n" + """
        let assistantMessageId = "invented-assistant"
        let modelId = "invented-model"
""" + body + "\n        return sharedAuthor\n    }\n}\n"
(out / 'Subject.swift').write_text(stub)
(out / 'Checks.swift').write_text((Path(__file__).parent / 'Checks.swift').read_text())
subprocess.run(['swiftc', '-O', '-parse-as-library', '-module-cache-path', str(out / 'modules'),
                str(out / 'Subject.swift'), str(out / 'Checks.swift'), '-o', str(out / 'checks')], check=True)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
result = subprocess.run([str(out / 'checks')], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if result.returncode:
    print('Synthetic append failed; return code:', result.returncode,
          '; exclusivity trap:', 'Simultaneous accesses' in result.stderr)
    raise SystemExit(1)
print(result.stdout, end='')

from pathlib import Path
import subprocess,os,sys
r=Path(__file__).resolve().parent;s=Path(sys.argv[1]).read_text();out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True);(out/'tmp').mkdir(exist_ok=True)
a=s.index('    func sendMessage(');b=s.index('    /// Why the most recent',a);send=s[a:b];assert send.index('let draftBeforeSend = inputText') < send.index('guard await restoreDetailsForAction()'), 'Draft snapshot must precede asynchronous restoration'
first=send.index('let json = try await manager.sendMessageHTTP(request: request)');before=send[:first]
assert 'inputText = ""' not in before, 'Composer is cleared before server acknowledgement'
assert 'attachments = []' not in before, 'Attachments are discarded before acknowledgement'
a=send.index('                guard !Task.isCancelled, self.streamingSessionId');b=send.index('                if capturedUseSSEFallback',a);accept=send[a:b]
a=s.index('    private func parseTaskIdsFromCompletionResponse(');b=s.index('\n    /// Stops the current',a);parse=s[a:b].replace('private func','func',1)
(out/'Checks.swift').write_text((r/'draft-checks.swift').read_text().replace('        INSERT_ACCEPT',accept).replace('    INSERT_PARSE',parse))
env=dict(os.environ,TMPDIR=str(out/'tmp'),SWIFT_MODULECACHE_PATH=str(out/'modules'),CLANG_MODULE_CACHE_PATH=str(out/'modules'))
subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-swift-version','6',str(out/'Checks.swift'),'-o',str(out/'checks')],env=env,check=True)
subprocess.run([str(out/'checks')],env=env,check=True)

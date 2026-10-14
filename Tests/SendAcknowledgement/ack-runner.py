from pathlib import Path
import subprocess,sys,os
r=Path(__file__).resolve().parent;vm=Path(sys.argv[1]).read_text();catchup=Path(sys.argv[2]).read_text();api=Path(sys.argv[3]);out=Path(sys.argv[4]);out.mkdir(parents=True,exist_ok=True);(out/'tmp').mkdir(exist_ok=True)
a=vm.index('        streamingTask = Task { [weak self] in',vm.index('    func sendMessage('));b=vm.index('\n        return true',a);block=vm[a:b];a=block.rindex('            } catch {')+len('            } catch {');b=block.rindex('\n            }\n        }');failure=block[a:b]
a=catchup.index('    private func resolveLastReply(');b=catchup.rindex('\n}');resolve=catchup[a:b].replace('private func','func',1)
(out/'Checks.swift').write_text((r/'ack-checks.swift').read_text().replace('        INSERT_CATCH',failure).replace('    INSERT_RESOLVE',resolve))
env=dict(os.environ,TMPDIR=str(out/'tmp'),SWIFT_MODULECACHE_PATH=str(out/'modules'),CLANG_MODULE_CACHE_PATH=str(out/'modules'))
subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-swift-version','6',str(out/'Checks.swift'),str(api),'-o',str(out/'checks')],env=env,check=True)
subprocess.run([str(out/'checks')],env=env,check=True)

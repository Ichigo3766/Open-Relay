from pathlib import Path
import subprocess,os,sys
root=Path(__file__).resolve().parent
source=Path(sys.argv[1]).read_text()
out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True);(out/'tmp').mkdir(exist_ok=True)
a=source.index('    func deduplicatedGET(');b=source.index('\n    // MARK: - Auth Token Management',a)
method=source[a:b]
a=source.index('actor GETDeduplicator {');b=source.index('\n// MARK: - Certificate Trust Delegate',a)
a2=source.index('    func performRequestWithRetry(');b2=source.index('\n    /// Downloads an explicitly opened file',a2)
a3=source.index('    private func performRequest(');b3=source.index('\n    /// Retries up to',a3)
text=(root/'network-checks.swift').read_text().replace('    INSERT_METHOD',method).replace('INSERT_ACTOR',source[a:b]).replace('    INSERT_RETRY',source[a2:b2]).replace('    INSERT_PERFORM',source[a3:b3].replace('private func','func',1))
(out/'Checks.swift').write_text(text)
env=dict(os.environ,TMPDIR=str(out/'tmp'),SWIFT_MODULECACHE_PATH=str(out/'modules'),CLANG_MODULE_CACHE_PATH=str(out/'modules'))
subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-swift-version','6',str(out/'Checks.swift'),'-o',str(out/'checks')],env=env,check=True)
subprocess.run([str(out/'checks')],env=env,check=True)

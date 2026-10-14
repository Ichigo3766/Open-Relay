from pathlib import Path
import subprocess,sys,os
r=Path(__file__).resolve().parent;s=Path(sys.argv[1]).read_text();out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True);(out/'tmp').mkdir(exist_ok=True)
a=s.index('    func loadModels()');b=s.index('\n    /// Silently refreshes',a);code=(r/'model-checks.swift').read_text().replace('    INSERT_METHOD',s[a:b]);(out/'Checks.swift').write_text(code)
env=dict(os.environ,TMPDIR=str(out/'tmp'),SWIFT_MODULECACHE_PATH=str(out/'modules'),CLANG_MODULE_CACHE_PATH=str(out/'modules'))
subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-swift-version','6',str(out/'Checks.swift'),'-o',str(out/'checks')],env=env,check=True)
subprocess.run([str(out/'checks')],env=env,check=True)

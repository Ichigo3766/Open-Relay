"""Generate a disposable native test host for the deferred-details placeholder.
Usage: python3 Tests/TieredCache/generate-loader-project.py /path/outside/checkout
Requires XcodeGen; run the Regression scheme on an iOS simulator.
"""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
if out == root or root in out.parents:
    raise SystemExit("Use an output directory outside the checkout.")
for name in ["Host", "Tests"]:
    (out / name).mkdir(parents=True, exist_ok=True)
(out / "Host/Host.swift").write_text('import SwiftUI\n@main struct Host: App { var body: some Scene { WindowGroup { Text("Synthetic regression fixture") } } }\n')
(out / "Tests/CachedDetailsLoader.swift").write_text((root / "Open UI/Shared/Components/CachedDetailsLoader.swift").read_text())
(out / "Tests/Checks.swift").write_text((root / "Tests/TieredCache/CachedDetailsLoaderTests.swift").read_text())
PROJECT = "name: Regression\noptions:\n  deploymentTarget:\n    iOS: '18.1'\nsettings:\n  base:\n    CODE_SIGNING_ALLOWED: NO\n    GENERATE_INFOPLIST_FILE: YES\n    SWIFT_VERSION: '5.0'\n    SWIFT_OPTIMIZATION_LEVEL: '-O'\ntargets:\n  Host:\n    type: application\n    platform: iOS\n    sources: Host\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.host\n  Checks:\n    type: bundle.unit-test\n    platform: iOS\n    sources: Tests\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.checks\n      TEST_HOST: '$(BUILT_PRODUCTS_DIR)/Host.app/Host'\n      BUNDLE_LOADER: '$(TEST_HOST)'\n    dependencies:\n      - target: Host\nschemes:\n  Regression:\n    build:\n      targets:\n        Host: all\n        Checks: [test]\n    test:\n      targets: [Checks]\n"
(out / "project.yml").write_text(PROJECT)
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml")], check=True)

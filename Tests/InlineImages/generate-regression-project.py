"""Generate a disposable native regression project from the current production source.
Usage: python3 Tests/InlineImages/generate-regression-project.py /path/outside/checkout
Requires Xcode and XcodeGen; build the resulting Regression scheme on an iOS simulator.
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
source = (root / "Open UI/Shared/Components/StreamingMarkdownView.swift").read_text()
start = source.index("    private static let base64ImageCache")
end = source.index("    var body: some View {", start)
source = source[start:end].replace("private static", "static").replace("private nonisolated", "nonisolated")
store = next(line.strip() for line in (root / "Open UI/Shared/Components/StreamingMarkdownView.swift").read_text().splitlines() if "base64ImageCache.setObject(image" in line)
source += '    static func store(_ image: UIImage, for key: NSString) { ' + store + ' }\n'
(out / "Tests/Production.swift").write_text('import UIKit\nimport CryptoKit\n@MainActor enum InlineImageFixture {\n' + source + '}\n')
PROJECT = "name: Regression\noptions:\n  deploymentTarget:\n    iOS: '18.1'\nsettings:\n  base:\n    CODE_SIGNING_ALLOWED: NO\n    GENERATE_INFOPLIST_FILE: YES\n    SWIFT_VERSION: '5.0'\n    SWIFT_OPTIMIZATION_LEVEL: '-O'\ntargets:\n  Host:\n    type: application\n    platform: iOS\n    sources: Host\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.host\n  Checks:\n    type: bundle.unit-test\n    platform: iOS\n    sources: Tests\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.checks\n      TEST_HOST: '$(BUILT_PRODUCTS_DIR)/Host.app/Host'\n      BUNDLE_LOADER: '$(TEST_HOST)'\n    dependencies:\n      - target: Host\nschemes:\n  Regression:\n    build:\n      targets:\n        Host: all\n        Checks: [test]\n    test:\n      targets: [Checks]\n"
(out / "Tests/Checks.swift").write_text((root / "Tests/InlineImages/RegressionChecks.swift").read_text())
(out / "project.yml").write_text(PROJECT)
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml")], check=True)

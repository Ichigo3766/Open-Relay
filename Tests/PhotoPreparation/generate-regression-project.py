"""Generate a disposable native regression project from the current production source.
Usage: python3 Tests/PhotoPreparation/generate-regression-project.py /path/outside/checkout
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
source = (root / "Open UI/Core/Services/FileAttachmentService.swift").read_text()
source = source[source.index("    // MARK: - Image Size Limit"):]
source = 'import UIKit\nimport SwiftUI\nimport CoreImage\nimport os.log\n@MainActor final class FileAttachmentService {\n' + source
source += (root / "Open UI/Core/Services/FileAttachmentService+ImagePipeline.swift").read_text()
source += '\nstruct ChatAttachment { enum Kind { case image, file }; let type: Kind; let name: String; let thumbnail: Image?; let data: Data }\n'
(out / "Tests/Production.swift").write_text(source)
PROJECT = "name: Regression\noptions:\n  deploymentTarget:\n    iOS: '18.1'\nsettings:\n  base:\n    CODE_SIGNING_ALLOWED: NO\n    GENERATE_INFOPLIST_FILE: YES\n    SWIFT_VERSION: '5.0'\n    SWIFT_OPTIMIZATION_LEVEL: '-O'\ntargets:\n  Host:\n    type: application\n    platform: iOS\n    sources: Host\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.host\n  Checks:\n    type: bundle.unit-test\n    platform: iOS\n    sources: Tests\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.checks\n      TEST_HOST: '$(BUILT_PRODUCTS_DIR)/Host.app/Host'\n      BUNDLE_LOADER: '$(TEST_HOST)'\n    dependencies:\n      - target: Host\nschemes:\n  Regression:\n    build:\n      targets:\n        Host: all\n        Checks: [test]\n    test:\n      targets: [Checks]\n"
(out / "Tests/Checks.swift").write_text((root / "Tests/PhotoPreparation/RegressionChecks.swift").read_text())
(out / "project.yml").write_text(PROJECT)
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml")], check=True)

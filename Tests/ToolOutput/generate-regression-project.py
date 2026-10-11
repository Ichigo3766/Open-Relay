"""Generate a disposable native regression project from the current production source.
Usage: python3 Tests/ToolOutput/generate-regression-project.py /path/outside/checkout
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
import json
source = (root / "Open UI/Shared/Components/ToolCallView.swift").read_text()
start = source.index("private struct ToolCallResultBlockView")
end = source.index("// MARK: - Tool Call Arguments View", start)
source = source[start:end].replace("private struct", "struct")
source = 'import SwiftUI\n' + source + '\nprivate struct ThemeKey: EnvironmentKey { static let defaultValue = FixtureTheme() }\nextension EnvironmentValues { var theme: FixtureTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }\nstruct FixtureTheme { let textSecondary = Color.black; let textPrimary = Color.black; let textTertiary = Color.gray; let surfaceContainer = Color.gray; let cardBorder = Color.gray; let background = Color.white; let isDark = false }\nenum CornerRadius { static let sm: CGFloat = 8 }\n'
(out / "Tests/Production.swift").write_text(source)
(out / "Tests/ReasoningText.swift").write_text((root / "Open UI/Shared/Components/ReasoningText.swift").read_text())
pins = json.loads((root / "Open UI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]
revision = next(pin["state"]["revision"] for pin in pins if pin["identity"] == "litext")
PROJECT = "name: Regression\noptions:\n  deploymentTarget:\n    iOS: '18.1'\nsettings:\n  base:\n    CODE_SIGNING_ALLOWED: NO\n    GENERATE_INFOPLIST_FILE: YES\n    SWIFT_VERSION: '5.0'\n    SWIFT_OPTIMIZATION_LEVEL: '-O'\ntargets:\n  Host:\n    type: application\n    platform: iOS\n    sources: Host\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.host\n  Checks:\n    type: bundle.unit-test\n    platform: iOS\n    sources: Tests\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: org.example.regression.checks\n      TEST_HOST: '$(BUILT_PRODUCTS_DIR)/Host.app/Host'\n      BUNDLE_LOADER: '$(TEST_HOST)'\n    dependencies:\n      - target: Host\nschemes:\n  Regression:\n    build:\n      targets:\n        Host: all\n        Checks: [test]\n    test:\n      targets: [Checks]\n"
(out / "Tests/Checks.swift").write_text((root / "Tests/ToolOutput/RegressionChecks.swift").read_text())
PROJECT = PROJECT.replace("targets:\n", "packages:\n  Litext:\n    url: https://github.com/Ichigo3766/Litext.git\n    revision: " + revision + "\ntargets:\n", 1).replace("      - target: Host\n", "      - target: Host\n      - package: Litext\n")
(out / "project.yml").write_text(PROJECT)
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml")], check=True)

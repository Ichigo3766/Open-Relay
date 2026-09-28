"""Exercise the production decoder and consent state with a synthetic transport."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
path = "Open UI/Core/Networking/APIModels.swift"
source = subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True) if baseline else (root / path).read_text()
features = source[source.index("    struct BackendFeatures:"):source.index("    struct PromptSuggestion:")]
model = "import Foundation\nstruct BackendConfig: Decodable { let features: BackendFeatures?\n" + features + "}\n"
if baseline:
    checks = '''
import Foundation
let data = Data(#"{"features":{"enable_web_search_confirmation":true}}"#.utf8)
let config = try JSONDecoder().decode(BackendConfig.self, from: data)
let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.features!)) as! [String: Any]
precondition(json["enable_web_search_confirmation"] as? Bool == true, "Required consent is lost in the baseline decoder")
'''
    production = ""
else:
    production = (root / "Open UI/Core/Services/WebSearchConsent.swift").read_text()
    checks = (root / "Tests/WebSearchConsent/Checks.swift").read_text()
    vm = (root / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift").read_text()
    for name in ("sendMessage(", "continueLastResponse(", "regenerateResponse(", "editMessage("):
        entry = vm.split("    func " + name, 1)[1].split("\n    func ", 1)[0]
        assert "guard await authorizeWebSearch() else { return }" in entry[:600], name
    voice = (root / "Open UI/Features/VoiceCall/ViewModels/VoiceCallViewModel.swift").read_text()
    assert voice.index("guard await chat.authorizeWebSearch()") < voice.index("guard await Self.requestPermissions")
    store = (root / "Open UI/Core/Services/DependencyContainer.swift").read_text()
    assert "viewModels.values.forEach { $0.webSearchConsent.reset() }" in store
    auth = vm.split("    func authorizeWebSearch()", 1)[1].split("    /// Builds chat features", 1)[0]
    assert auth.index("let revision") < auth.index("await refreshSelectedModelMetadata()") < auth.index("guard revision == webSearchConsent.revision")

with tempfile.TemporaryDirectory(prefix="relay-search-consent-") as directory:
    work = Path(directory)
    (work / "Model.swift").write_text(model + production)
    (work / ("main.swift" if baseline else "Checks.swift")).write_text(checks)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Model.swift"), str(work / ("main.swift" if baseline else "Checks.swift")), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)

import SwiftUI

// MARK: - Language Picker View

/// In-app language picker. Sets AppleLanguages in UserDefaults and prompts
/// the user to restart the app — no trip to iOS Settings needed.
struct LanguagePickerView: View {
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var showRestartAlert = false
    @State private var pendingLocale: AppLanguage? = nil

    // The languages the app is fully translated into
    static let supportedLanguages: [AppLanguage] = [
        AppLanguage(code: "en",       flag: "🇺🇸", nativeName: "English",               englishName: "English"),
        AppLanguage(code: "ar",       flag: "🇸🇦", nativeName: "العربية",                englishName: "Arabic"),
        AppLanguage(code: "az",       flag: "🇦🇿", nativeName: "Azərbaycan",             englishName: "Azerbaijani"),
        AppLanguage(code: "eu",       flag: "🏴", nativeName: "Euskara",                englishName: "Basque"),
        AppLanguage(code: "bn",       flag: "🇧🇩", nativeName: "বাংলা",                  englishName: "Bengali"),
        AppLanguage(code: "bs",       flag: "🇧🇦", nativeName: "Bosanski",               englishName: "Bosnian"),
        AppLanguage(code: "bg",       flag: "🇧🇬", nativeName: "Български",              englishName: "Bulgarian"),
        AppLanguage(code: "ca",       flag: "🏴", nativeName: "Català",                 englishName: "Catalan"),
        AppLanguage(code: "zh-Hans",  flag: "🇨🇳", nativeName: "简体中文",                 englishName: "Chinese (Simplified)"),
        AppLanguage(code: "zh-Hant",  flag: "🇹🇼", nativeName: "繁體中文",                 englishName: "Chinese (Traditional)"),
        AppLanguage(code: "hr",       flag: "🇭🇷", nativeName: "Hrvatski",               englishName: "Croatian"),
        AppLanguage(code: "cs",       flag: "🇨🇿", nativeName: "Čeština",                englishName: "Czech"),
        AppLanguage(code: "da",       flag: "🇩🇰", nativeName: "Dansk",                  englishName: "Danish"),
        AppLanguage(code: "nl",       flag: "🇳🇱", nativeName: "Nederlands",             englishName: "Dutch"),
        AppLanguage(code: "en-GB",    flag: "🇬🇧", nativeName: "English (UK)",           englishName: "English (UK)"),
        AppLanguage(code: "et",       flag: "🇪🇪", nativeName: "Eesti",                  englishName: "Estonian"),
        AppLanguage(code: "fi",       flag: "🇫🇮", nativeName: "Suomi",                  englishName: "Finnish"),
        AppLanguage(code: "fr",       flag: "🇫🇷", nativeName: "Français",               englishName: "French"),
        AppLanguage(code: "fr-CA",    flag: "🇨🇦", nativeName: "Français (Canada)",      englishName: "French (Canada)"),
        AppLanguage(code: "gl",       flag: "🏴", nativeName: "Galego",                 englishName: "Galician"),
        AppLanguage(code: "ka",       flag: "🇬🇪", nativeName: "ქართული",               englishName: "Georgian"),
        AppLanguage(code: "de",       flag: "🇩🇪", nativeName: "Deutsch",                englishName: "German"),
        AppLanguage(code: "el",       flag: "🇬🇷", nativeName: "Ελληνικά",               englishName: "Greek"),
        AppLanguage(code: "he",       flag: "🇮🇱", nativeName: "עברית",                  englishName: "Hebrew"),
        AppLanguage(code: "hi",       flag: "🇮🇳", nativeName: "हिन्दी",                  englishName: "Hindi"),
        AppLanguage(code: "hu",       flag: "🇭🇺", nativeName: "Magyar",                 englishName: "Hungarian"),
        AppLanguage(code: "id",       flag: "🇮🇩", nativeName: "Bahasa Indonesia",       englishName: "Indonesian"),
        AppLanguage(code: "ga",       flag: "🇮🇪", nativeName: "Gaeilge",                englishName: "Irish"),
        AppLanguage(code: "it",       flag: "🇮🇹", nativeName: "Italiano",               englishName: "Italian"),
        AppLanguage(code: "ja",       flag: "🇯🇵", nativeName: "日本語",                  englishName: "Japanese"),
        AppLanguage(code: "ko",       flag: "🇰🇷", nativeName: "한국어",                  englishName: "Korean"),
        AppLanguage(code: "lt",       flag: "🇱🇹", nativeName: "Lietuvių",               englishName: "Lithuanian"),
        AppLanguage(code: "lv",       flag: "🇱🇻", nativeName: "Latviešu",               englishName: "Latvian"),
        AppLanguage(code: "ms",       flag: "🇲🇾", nativeName: "Bahasa Melayu",          englishName: "Malay"),
        AppLanguage(code: "nb",       flag: "🇳🇴", nativeName: "Norsk Bokmål",           englishName: "Norwegian Bokmål"),
        AppLanguage(code: "fa",       flag: "🇮🇷", nativeName: "فارسی",                  englishName: "Persian"),
        AppLanguage(code: "pl",       flag: "🇵🇱", nativeName: "Polski",                 englishName: "Polish"),
        AppLanguage(code: "pt-BR",    flag: "🇧🇷", nativeName: "Português (Brasil)",     englishName: "Portuguese (Brazil)"),
        AppLanguage(code: "pt-PT",    flag: "🇵🇹", nativeName: "Português (Portugal)",   englishName: "Portuguese (Portugal)"),
        AppLanguage(code: "pa",       flag: "🇮🇳", nativeName: "ਪੰਜਾਬੀ",                englishName: "Punjabi"),
        AppLanguage(code: "ro",       flag: "🇷🇴", nativeName: "Română",                 englishName: "Romanian"),
        AppLanguage(code: "ru",       flag: "🇷🇺", nativeName: "Русский",                englishName: "Russian"),
        AppLanguage(code: "sr",       flag: "🇷🇸", nativeName: "Српски",                 englishName: "Serbian"),
        AppLanguage(code: "sk",       flag: "🇸🇰", nativeName: "Slovenčina",             englishName: "Slovak"),
        AppLanguage(code: "es",       flag: "🇪🇸", nativeName: "Español",                englishName: "Spanish"),
        AppLanguage(code: "sv",       flag: "🇸🇪", nativeName: "Svenska",                englishName: "Swedish"),
        AppLanguage(code: "th",       flag: "🇹🇭", nativeName: "ภาษาไทย",                englishName: "Thai"),
        AppLanguage(code: "tr",       flag: "🇹🇷", nativeName: "Türkçe",                 englishName: "Turkish"),
        AppLanguage(code: "tk",       flag: "🇹🇲", nativeName: "Türkmen",                englishName: "Turkmen"),
        AppLanguage(code: "uk",       flag: "🇺🇦", nativeName: "Українська",             englishName: "Ukrainian"),
        AppLanguage(code: "ur",       flag: "🇵🇰", nativeName: "اردو",                   englishName: "Urdu"),
        AppLanguage(code: "ug",       flag: "🇨🇳", nativeName: "ئۇيغۇرچە",               englishName: "Uyghur"),
        AppLanguage(code: "uz",       flag: "🇺🇿", nativeName: "Oʻzbekcha",              englishName: "Uzbek"),
        AppLanguage(code: "vi",       flag: "🇻🇳", nativeName: "Tiếng Việt",             englishName: "Vietnamese"),
    ]

    static var selectedLanguageCode: String? {
        // Ignore the global device-language fallback when there is no app override.
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return (UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first
    }

    private var filteredLanguages: [AppLanguage] {
        guard !searchText.isEmpty else { return Self.supportedLanguages }
        let q = searchText.lowercased()
        return Self.supportedLanguages.filter {
            $0.nativeName.lowercased().contains(q) ||
            $0.englishName.lowercased().contains(q) ||
            $0.code.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            Section {
                systemDefaultRow
            }
            Section {
                ForEach(filteredLanguages) { lang in
                    languageRow(lang)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search language")
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Restart Now", role: .destructive) {
                applyLanguage(pendingLocale)
            }
            Button("Later", role: .cancel) {
                pendingLocale = nil
            }
        } message: {
            if let lang = pendingLocale {
                Text("The app will restart to apply \(lang.nativeName).")
            } else {
                Text("The app will restart to apply the system language.")
            }
        }
    }

    // MARK: - System Default Row

    private var systemDefaultRow: some View {
        Button {
            pendingLocale = nil
            showRestartAlert = true
        } label: {
            HStack(spacing: 14) {
                Text("🌐")
                    .scaledFont(size: 28)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("System Default")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text("Follows your iPhone language")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                // Checkmark if system default is active
                if Self.selectedLanguageCode == nil {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(Self.selectedLanguageCode == nil ? .isSelected : [])
    }

    // MARK: - Language Row

    private func languageRow(_ lang: AppLanguage) -> some View {
        let isSelected = Self.selectedLanguageCode == lang.code

        return Button {
            pendingLocale = lang
            showRestartAlert = true
        } label: {
            HStack(spacing: 14) {
                Text(lang.flag)
                    .scaledFont(size: 28)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(lang.nativeName)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text(lang.englishName)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Apply Language

    private func applyLanguage(_ lang: AppLanguage?) {
        if let lang {
            UserDefaults.standard.set([lang.code], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        } else {
            // Remove override → falls back to device language
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
        // Restart the app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(0)
        }
    }
}

// MARK: - AppLanguage Model

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let flag: String
    let nativeName: String
    let englishName: String

    var id: String { code }
}

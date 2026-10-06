import SwiftUI

/// "Translations" section for the model editor (`meta.i18n`).
struct ModelTranslationsSection: View {
    @Environment(\.theme) private var theme
    @Binding var i18n: LocalizedMap
    /// Arena models only translate name + description (web ArenaModelModal).
    var showsPrompts = true

    @State var locale = ""
    @State private var showLocalePicker = false

    private var translatedLocales: [String] { LocalizedContent.prune(i18n).keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Translations")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            Text("Show a different name, description and starter prompts to people using another language.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)

            if !translatedLocales.isEmpty { localeChips }

            Button { showLocalePicker = true } label: {
                HStack {
                    Image(systemName: "globe")
                    Text(locale.isEmpty ? "Add a language" : OpenWebUILanguages.title(for: locale)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").scaledFont(size: 11)
                }
                .scaledFont(size: 14)
                .foregroundStyle(theme.brandPrimary)
                .padding(10)
                .background(theme.surfaceContainer.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)

            if !locale.isEmpty { editor }
        }
        .padding(Spacing.md)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .sheet(isPresented: $showLocalePicker) {
            LocalePickerSheet(selected: locale) { code in
                locale = code
                showLocalePicker = false
            }
        }
    }

    private var localeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(translatedLocales, id: \.self) { code in
                    Button { locale = code } label: {
                        Text(code)
                            .scaledFont(size: 12, weight: locale == code ? .semibold : .regular)
                            .padding(.vertical, 4).padding(.horizontal, 10)
                            .background(Capsule().fill(locale == code
                                ? theme.brandPrimary.opacity(0.15) : theme.surfaceContainer))
                            .foregroundStyle(locale == code ? theme.brandPrimary : theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            textField("Name", key: "name", placeholder: "Translated name", multiline: false)
            textField("Description", key: "description", placeholder: "Translated description", multiline: true)

            if showsPrompts {
            HStack {
                Text("Starter prompts").scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textSecondary)
                Spacer()
                if prompts != nil {
                    Button("Use default") { setPrompts(nil) }.scaledFont(size: 12)
                } else {
                    Button("Customize") { setPrompts([SuggestionPrompt()]) }.scaledFont(size: 12)
                }
            }
            if let list = prompts {
                ForEach(list.indices, id: \.self) { promptRow($0) }
                Button { setPrompts(list + [SuggestionPrompt()]) } label: {
                    Label("Add Prompt", systemImage: "plus").scaledFont(size: 13)
                }
            }
            }

            Button(role: .destructive) {
                i18n.removeValue(forKey: locale)
                locale = ""
            } label: {
                Label("Remove this language", systemImage: "trash").scaledFont(size: 13)
            }
            .padding(.top, 4)
        }
    }

    private func textField(_ title: String, key: String, placeholder: String, multiline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textSecondary)
            TextField(placeholder, text: Binding(
                get: { i18n[locale]?[key] as? String ?? "" },
                set: { setField(key, $0) }
            ), axis: .vertical)
            .lineLimit(multiline ? 2...6 : 1...2)
            .scaledFont(size: 14)
            .padding(10)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        }
    }

    private func promptRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Title", text: promptBinding(i, \.title))
                Button { removePrompt(i) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            TextField("Subtitle", text: promptBinding(i, \.subtitle))
            TextField("Prompt", text: promptBinding(i, \.content), axis: .vertical)
        }
        .scaledFont(size: 13)
        .padding(8)
        .background(theme.surfaceContainer.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
    }
}

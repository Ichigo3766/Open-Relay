import SwiftUI

struct WebSearchConsentAlert: ViewModifier {
    let consent: WebSearchConsent?

    func body(content: Content) -> some View {
        content.alert("Use Web Search?", isPresented: Binding(
            get: { consent?.prompt != nil },
            set: { showing in
                if !showing, let prompt = consent?.prompt {
                    consent?.resolve(id: prompt.id, approved: false)
                }
            }
        ), presenting: consent?.prompt) { prompt in
            Button("Cancel", role: .cancel) { consent?.resolve(id: prompt.id, approved: false) }
            Button("Continue") { consent?.resolve(id: prompt.id, approved: true) }
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

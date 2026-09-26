import Litext
import SwiftUI

@main
struct GestureHarness: App {
    var body: some Scene { WindowGroup { Page() } }
}

private struct Page: View {
    @State private var offset: CGFloat = 0
    @State private var open = false
    @State private var selected = false
    @State private var draft = "Editable sample"

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Text("Sidebar").accessibilityIdentifier("sidebar")
                    .accessibilityHidden(!open)
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 30) {
                            Text("First row").accessibilityIdentifier("first-row")
                            Label(selected: selected)
                                .frame(height: 60)
                            Button("Select sample") { selected = true }
                            ScrollView(.horizontal) {
                                Text(String(repeating: "Wide code sample. ", count: 25))
                                    .fixedSize().accessibilityIdentifier("wide-text")
                            }
                            .frame(height: 60).accessibilityIdentifier("horizontal-scroll")
                            ForEach(0..<30) { index in
                                Text("Invented row \(index)").frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 20)
                            }
                        }.padding()
                    }
                    // Chat scrolling also observes a low-threshold drag to stop auto-scroll.
                    .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in })
                    .safeAreaInset(edge: .bottom) {
                        TextField("Draft", text: $draft).padding().background(.bar)
                    }
                }
                .gesture(SidebarOpeningGesture(isEnabled: !open,
                    onChanged: { offset = max(0, $0) },
                    onEnded: { x, _, cancelled in
                        open = !cancelled && x > 70
                        offset = open ? geometry.size.width * 0.82 : 0
                    }))
                .overlay {
                    if open { Color.clear.contentShape(Rectangle()).onTapGesture { open = false; offset = 0 } }
                }
                .offset(x: offset)
            }
            .overlay(alignment: .topTrailing) {
                Text(open ? "open" : "closed").accessibilityIdentifier("drawer-state")
                    .accessibilityValue(String(Int(offset))).allowsHitTesting(false)
            }
        }
    }
}

private struct Label: UIViewRepresentable {
    var selected: Bool
    func makeUIView(context: Context) -> LTXLabel {
        let label = LTXLabel()
        label.attributedText = NSAttributedString(string: "Invented selectable sample text", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        label.isSelectable = true
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "selectable-text"
        return label
    }
    func updateUIView(_ view: LTXLabel, context: Context) {
        view.selectionRange = selected ? NSRange(location: 0, length: 8) : nil
    }
}

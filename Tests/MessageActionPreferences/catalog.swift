import UIKit
import SFSafeSymbols

@main
struct CatalogChecks {
    static func main() {
        let names = SFSymbol.allSymbols.map(\.rawValue).sorted()
        precondition(names.count > 4_000, "The picker must offer the full catalog")
        precondition(Set(names).count == names.count, "Picker identities must be unique")
        var missing: [String] = []
        for name in names {
            autoreleasepool {
                if UIImage(systemName: name) == nil { missing.append(name) }
            }
            let symbol = MessageActionSymbol(name)
            precondition(!symbol.title.isEmpty)
            precondition(symbol.matches(MessageActionSymbol.searchTerms(name)))
            precondition(symbol.matches(MessageActionSymbol.searchTerms(symbol.title)))
        }
        precondition(missing.isEmpty, "Unavailable symbols: \(missing)")
        if #available(iOS 26, *) {
            precondition(names.contains("1.calendar"))
        } else {
            precondition(!names.contains("1.calendar"), "New symbols must be omitted on older systems")
        }
        print("Catalog: \(names.count) symbols rendered and searchable on iOS \(UIDevice.current.systemVersion)")
    }
}

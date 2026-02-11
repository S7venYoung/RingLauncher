import Foundation

struct ActionItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String // SFSymbols 名称
    let action: () -> Void
}
import Foundation

struct ActionItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let action: () -> Void
}
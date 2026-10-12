import SwiftUI

@main
struct SpyClashGameCoreLabApp: App {
    @State private var store = LabStore()
    var body: some Scene { WindowGroup { LabView(store: store) } }
}

import AppKit
import SwiftUI

@main
struct ProxyAppXApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ProxyAppX", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.isRunning ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)
    }
}

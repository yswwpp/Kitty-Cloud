import SwiftUI

@main
struct KittyApp: App {
    // 注册 AppDelegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            TabView {
                CallView()
                    .tabItem {
                        Label("通话", systemImage: "phone.fill")
                    }

                ChatView()
                    .tabItem {
                        Label("聊天", systemImage: "message.fill")
                    }
            }
        }
    }
}
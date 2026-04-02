// ContentView.swift
import SwiftUI
import UserNotifications

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                HomeView()
            }
            Tab("Diagnose", systemImage: "camera.viewfinder", value: 1) {
                CameraView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: 2) {
                HistoryView()
            }
        }
        .tint(Theme.brandPrimary)
        .background(Color(hex: 0x0D0D0F).ignoresSafeArea())
        .dismissKeyboardOnTap()
        // Deep-link to History when user taps a push notification
        .onReceive(NotificationCenter.default.publisher(
            for: AppDelegate.notificationTappedNotification)
        ) { _ in
            selectedTab = 2
            clearBadge()
        }
        // Clear badge whenever the app comes to the foreground
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            clearBadge()
        }
    }

    private func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}

#Preview {
    ContentView()
}

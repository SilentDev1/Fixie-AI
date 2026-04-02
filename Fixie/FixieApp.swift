// FixieApp.swift
import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseMessaging
import UserNotifications

// MARK: – AppDelegate
//
// FirebaseApp.configure() MUST be called here — NOT in App.init().
//
// When called in App.init(), the UIApplicationDelegate hasn't been registered
// with UIApplication yet. Firebase's swizzler scans the existing app delegate
// immediately on configure(), finds nothing conforming to UIApplicationDelegate,
// and logs:  [I-SWZ001014] App Delegate does not conform to UIApplicationDelegate protocol.
//
// Moving configure() into application(_:didFinishLaunchingWithOptions:) ensures
// the delegate is fully registered before Firebase inspects it — warning gone.

final class AppDelegate: NSObject, UIApplicationDelegate,
                          UNUserNotificationCenterDelegate, MessagingDelegate {

    // Posted when the user taps a push notification — HomeView can react to deep-link.
    static let notificationTappedNotification = Notification.Name("com.fixie.notificationTapped")
    // Posted when the app is opened via fixie://lead/{leadId} — HomeView opens the matching card.
    static let deepLinkLeadNotification       = Notification.Name("com.fixie.deepLinkLead")
    // Posted specifically for dispatch (pro en-route) push taps.
    static let dispatchTappedNotification       = Notification.Name("com.fixie.dispatchTapped")
    // Homeowner's reschedule request was sent — pro will accept or decline.
    static let rescheduleTappedNotification     = Notification.Name("com.fixie.rescheduleTapped")
    // Pro accepted the reschedule — new scheduledTime confirmed.
    static let rescheduleAcceptedNotification   = Notification.Name("com.fixie.rescheduleAccepted")
    // Pro declined the reschedule — original time stands.
    static let rescheduleDeclinedNotification   = Notification.Name("com.fixie.rescheduleDeclined")
    // Homeowner just confirmed a reschedule request — HomeView updates the card immediately.
    static let rescheduleRequestedByUserNotification = Notification.Name("com.fixie.rescheduleRequestedByUser")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()

        // ── Push notifications ─────────────────────────────────────────────
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }

        // FCM delegate — delivers registration tokens via messaging(_:didReceiveRegistrationToken:)
        Messaging.messaging().delegate = self

        return true
    }

    // MARK: – APNs device token → hand off to FCM

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    // MARK: – FCM token received / refreshed

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        Task { await FirebaseService.shared.saveFCMToken(token) }
    }

    // MARK: – Shared payload parser
    //
    // Previously all parsing lived only in didReceive (tap handler), so pushes
    // arriving while the app was foregrounded — or when the user never tapped the
    // banner — were silently ignored. handlePushPayload is now called from:
    //   • willPresent     — foreground delivery (no tap required)
    //   • didReceiveRemoteNotification — background / silent delivery
    //   • didReceive      — user tapped the banner (deep-link navigation still works
    //                        because the same notifications are posted; HomeView
    //                        handlers are idempotent so double-firing is harmless)

    private func handlePushPayload(_ userInfo: [AnyHashable: Any]) {
        let pushType = userInfo["type"] as? String ?? ""

        if pushType == "dispatch",
           let leadId  = userInfo["leadId"]  as? String,
           let proName = userInfo["proName"] as? String {
            let mins    = Int(userInfo["etaMinutes"] as? String ?? "") ?? 0
            let etaDate = mins > 0
                ? Calendar.current.date(byAdding: .minute, value: mins, to: Date())
                : nil
            NotificationCenter.default.post(
                name:     AppDelegate.dispatchTappedNotification,
                object:   nil,
                userInfo: ["leadId": leadId, "proName": proName, "etaDate": etaDate as Any]
            )
        } else if pushType == "reschedule",
                  let leadId = userInfo["leadId"] as? String {
            NotificationCenter.default.post(
                name:     AppDelegate.rescheduleTappedNotification,
                object:   nil,
                userInfo: ["leadId": leadId]
            )
        } else if pushType == "reschedule_accepted",
                  let leadId = userInfo["leadId"] as? String {
            let epochStr = userInfo["scheduledTime"] as? String ?? ""
            let newTime  = Double(epochStr).map { Date(timeIntervalSince1970: $0) }
            NotificationCenter.default.post(
                name:     AppDelegate.rescheduleAcceptedNotification,
                object:   nil,
                userInfo: ["leadId": leadId, "scheduledTime": newTime as Any]
            )
        } else if pushType == "reschedule_declined",
                  let leadId = userInfo["leadId"] as? String {
            NotificationCenter.default.post(
                name:     AppDelegate.rescheduleDeclinedNotification,
                object:   nil,
                userInfo: ["leadId": leadId]
            )
        } else if pushType == "reschedule_request" {
            NotificationCenter.default.post(
                name:     AppDelegate.notificationTappedNotification,
                object:   nil,
                userInfo: userInfo
            )
        } else {
            NotificationCenter.default.post(
                name:     AppDelegate.notificationTappedNotification,
                object:   nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: – Foreground delivery: show banner AND process payload immediately

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handlePushPayload(notification.request.content.userInfo)
        completionHandler([.banner, .sound, .badge])
    }

    // MARK: – Background / silent delivery (content-available pushes)

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        handlePushPayload(userInfo)
        completionHandler(.newData)
    }

    // MARK: – Tap handler: user tapped the banner (also calls shared parser for deep-link)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handlePushPayload(response.notification.request.content.userInfo)
        completionHandler()
    }
}

// MARK: – App entry point

@main
struct FixieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenOnboarding {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .preferredColorScheme(.dark)
            // Start location after the first frame renders — never blocks launch
            .task { LocationService.shared.start() }
            // Handle fixie://lead/{leadId} deep links (e.g. tapped from Apple Calendar notes)
            .onOpenURL { url in
                guard url.scheme == "fixie",
                      url.host == "lead",
                      let leadId = url.pathComponents.dropFirst().first
                else { return }
                NotificationCenter.default.post(
                    name:     AppDelegate.deepLinkLeadNotification,
                    object:   nil,
                    userInfo: ["leadId": leadId]
                )
            }
        }
        .modelContainer(RepairHistoryStore.sharedContainer)
    }
}

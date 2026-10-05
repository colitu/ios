import BackgroundTasks
import Flutter
import MessageUI
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, MFMailComposeViewControllerDelegate {
    private let backgroundVpnTaskIdentifier = "com.colitu.vpn.background.task"
    private var networkPathMonitor: NWPathMonitor?
    private var networkPathChannel: FlutterMethodChannel?
    private var lastNetworkInterfaceType: String?
    private var lastNetworkTransitionSentAt: Date?
    private let networkPathQueue = DispatchQueue(label: "com.colitu.vpn.network-path")

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundVpnRefresh()
        scheduleBackgroundVpnRefresh()
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        super.applicationDidEnterBackground(application)
        scheduleBackgroundVpnRefresh()
    }
    
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        let binaryMessenger = engineBridge.applicationRegistrar.messenger()
        let flutterApi = AppFlutterApi(binaryMessenger: binaryMessenger)
        BridgeHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: AppHostApi(flutterApi: flutterApi))
        setUpMailComposer(binaryMessenger: binaryMessenger)
        setUpPasteboardImage(binaryMessenger: binaryMessenger)
        startNetworkTransitionMonitor(binaryMessenger: binaryMessenger)
        
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    }

    private func setUpMailComposer(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "colitu/mail", binaryMessenger: binaryMessenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "composeEmail" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard MFMailComposeViewController.canSendMail() else {
                result(false)
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let to = args["to"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing recipient", details: nil))
                return
            }

            let composer = MFMailComposeViewController()
            composer.mailComposeDelegate = self
            composer.setToRecipients([to])
            composer.setSubject(args["subject"] as? String ?? "")
            composer.setMessageBody(args["body"] as? String ?? "", isHTML: false)

            guard let controller = self?.rootViewController() else {
                result(false)
                return
            }
            controller.present(composer, animated: true)
            result(true)
        }
    }

    private func setUpPasteboardImage(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "colitu/pasteboard", binaryMessenger: binaryMessenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "readImage" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let image = UIPasteboard.general.image else {
                result(nil)
                return
            }

            if let data = image.pngData(), data.count <= 5 * 1024 * 1024 {
                result([
                    "dataUrl": "data:image/png;base64,\(data.base64EncodedString())",
                    "fileName": "clipboard-image.png",
                    "mimeType": "image/png",
                    "sizeBytes": data.count
                ])
                return
            }

            if let data = image.jpegData(compressionQuality: 0.86), data.count <= 5 * 1024 * 1024 {
                result([
                    "dataUrl": "data:image/jpeg;base64,\(data.base64EncodedString())",
                    "fileName": "clipboard-image.jpg",
                    "mimeType": "image/jpeg",
                    "sizeBytes": data.count
                ])
                return
            }

            result(nil)
        }
    }

    private func rootViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func registerBackgroundVpnRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundVpnTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundVpnRefresh(task)
        }
    }

    private func scheduleBackgroundVpnRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundVpnTaskIdentifier)
        let request = BGProcessingTaskRequest(identifier: backgroundVpnTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // This task is intentionally lightweight. It must not restart the VPN:
        // iOS schedules it opportunistically, which can look like a random drop.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugPrint("Background VPN refresh schedule failed: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundVpnRefresh(_ task: BGTask) {
        scheduleBackgroundVpnRefresh()
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        var work: Task<Void, Never>?
        processingTask.expirationHandler = {
            work?.cancel()
        }
        work = Task { @MainActor in
            let success = await self.refreshVpnStatusInBackground()
            processingTask.setTaskCompleted(success: success)
        }
    }

    @MainActor
    private func refreshVpnStatusInBackground() async -> Bool {
        await VPNManager.shared.refreshVpn()
        _ = VPNManager.shared.readStatus()
        return true
    }

    private func startNetworkTransitionMonitor(binaryMessenger: FlutterBinaryMessenger) {
        networkPathChannel = FlutterMethodChannel(
            name: "colitu/network_path",
            binaryMessenger: binaryMessenger
        )
        networkPathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPath(path)
        }
        networkPathMonitor = monitor
        monitor.start(queue: networkPathQueue)
    }

    private func handleNetworkPath(_ path: NWPath) {
        guard path.status == .satisfied else {
            return
        }
        let next = networkInterfaceType(path)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let previous = self.lastNetworkInterfaceType
            self.lastNetworkInterfaceType = next
            guard let previous = previous, previous != next else {
                return
            }
            guard (previous == "wifi" && next == "cellular") ||
                  (previous == "cellular" && next == "wifi") else {
                return
            }
            let now = Date()
            if let last = self.lastNetworkTransitionSentAt,
               now.timeIntervalSince(last) < 8 {
                return
            }
            self.lastNetworkTransitionSentAt = now
            self.networkPathChannel?.invokeMethod(
                "networkChanged",
                arguments: ["from": previous, "to": next]
            )
        }
    }

    private func networkInterfaceType(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) {
            return "wifi"
        }
        if path.usesInterfaceType(.cellular) {
            return "cellular"
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return "ethernet"
        }
        return "other"
    }

    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        controller.dismiss(animated: true)
    }
}

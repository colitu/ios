import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        let engine = flutterViewController.engine
        let flutterApi = AppFlutterApi(binaryMessenger: engine.binaryMessenger)
        BridgeHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: AppHostApi(flutterApi: flutterApi))
        setUpTunnelChannel(binaryMessenger: engine.binaryMessenger)

        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
    }

    /// Warm-spare swap (the tunnel reloads its core) and pings while the VPN is up.
    private func setUpTunnelChannel(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "colitu/tunnel", binaryMessenger: binaryMessenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "reloadCore":
                Task {
                    let ok = await VPNManager.shared.reloadCore()
                    await MainActor.run { result(ok) }
                }
            case "measureLatency":
                // [{address, port}] -> [ms, -1 = no answer], or nil.
                let raw = call.arguments as? [[String: Any]] ?? []
                let targets = raw.compactMap { item -> LatencyTarget? in
                    guard let address = item["address"] as? String, let port = item["port"] as? Int else { return nil }
                    return LatencyTarget(address: address, port: port)
                }
                guard targets.count == raw.count, !targets.isEmpty else {
                    result(nil)
                    return
                }
                Task {
                    let ms = await VPNManager.shared.measureLatency(targets)
                    await MainActor.run { result(ms) }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

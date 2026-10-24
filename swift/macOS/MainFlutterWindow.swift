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

    /// Warm-spare swap: the app asks the tunnel to reload its core.
    private func setUpTunnelChannel(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "colitu/tunnel", binaryMessenger: binaryMessenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "reloadCore" else {
                result(FlutterMethodNotImplemented)
                return
            }
            Task {
                let ok = await VPNManager.shared.reloadCore()
                await MainActor.run { result(ok) }
            }
        }
    }
}

import Combine
import Foundation
import NetworkExtension

typealias VPNStatusCallback = @MainActor () -> Void

enum VPNError: Error {
    case sessionNotReady
    case noGroupContainer
}

@MainActor
class VPNManager {
    static let shared = VPNManager()
    
    var vpn: NETunnelProviderManager?
    private var cancellable: Cancellable?
    private var statusObserver: VPNStatusCallback?
    private var systemExtensionSetupTask: Task<Bool, Never>?
    private var protectedReconnectTask: Task<Void, Never>?
    private var suppressProtectedReconnect = false

    init() {
        YGLog("VPNManager init")
        cancellable = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)
            .sink(receiveValue: { noti in
                if let session = noti.object as? NETunnelProviderSession {
                    if session == self.vpn?.connection {
                        if session.status == .disconnected {
                            Task { @MainActor in
                                if self.suppressProtectedReconnect {
                                    YGLog("VPN protected reconnect suppressed because stop was requested")
                                    if let vpn = self.vpn {
                                        await self.disableAutomaticReconnect(vpn, logMessage: "VPN on-demand reconnect disabled after stop disconnect")
                                    }
                                    self.runStatusObserver()
                                    return
                                } else if self.reconnectAfterProtectedDisconnect() {
                                    self.runStatusObserver()
                                    return
                                }
                                await self.disableAutomaticReconnectAfterDisconnect()
                                self.runStatusObserver()
                            }
                        } else {
                            self.runStatusObserver()
                        }
                    }
                }
            })
    }
    
    private func runStatusObserver() {
        if let observer = statusObserver {
            observer()
        }
    }
    
    func registerStatusObserver(_ observer: @escaping VPNStatusCallback) {
        statusObserver = observer
    }
    
    func unregisterStatusObserver() {
        statusObserver = nil
    }
    
    private func findVpn() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        for vpn in managers {
            if let conf = vpn.protocolConfiguration as? NETunnelProviderProtocol {
                if conf.providerBundleIdentifier == packetTunnelId() {
                    return vpn
                }
            }
        }
        return nil
    }
    
    private func newVpn() -> NETunnelProviderManager {
        let serverAddress = vpnServerAddress()
        
        let vpn = NETunnelProviderManager()
        let conf = NETunnelProviderProtocol()
        conf.providerBundleIdentifier = packetTunnelId()
        conf.serverAddress = serverAddress
        
        conf.username = serverAddress
        conf.excludeLocalNetworks = true
        
        vpn.protocolConfiguration = conf
        vpn.localizedDescription = serverAddress
        return vpn
    }
    
    func refreshVpn() async {
        #if os(macOS)
        if Constants.useSystemExtension {
            guard await ensureSystemExtensionIfNeeded() else {
                return
            }
        }
        #endif
        do {
            if let vpn = try await findVpn() {
                self.vpn = vpn
                await disableAutomaticReconnectIfUnused(vpn)
            } else {
                vpn = newVpn()
                try await saveVpn(vpn: vpn!, tun: TunJson())
            }
        } catch {
            YGLog(error)
        }
    }

    #if os(macOS)
    private func ensureSystemExtensionIfNeeded() async -> Bool {
        if let existing = systemExtensionSetupTask {
            let cached = await existing.value
            if cached { return true }
            // Previous attempt returned nil (approval pending) or failed.
            // Re-check current state: the user may have approved in System
            // Settings since then.
            let installed = await SystemExtensionManager.isInstalled()
            if installed {
                systemExtensionSetupTask = Task { true }
            }
            return installed
        }
        let task = Task { await self.runSystemExtensionSetup() }
        systemExtensionSetupTask = task
        return await task.value
    }

    private func runSystemExtensionSetup() async -> Bool {
        #if DEBUG
        let force = true
        #else
        let force = false
        #endif
        do {
            if await SystemExtensionManager.isInstalled() && !force {
                return true
            }
            if let result = try await SystemExtensionManager.activate(forceReplace: force) {
                return result == .completed
            }
            return false
        } catch {
            YGLog("setup system extension error: \(error.localizedDescription)")
            return false
        }
    }
    #endif
    
    func readStatus() -> NEVPNStatus? {
        return VPNManager.shared.vpn?.connection.status
    }
    
    func startVpn() async -> Bool {
        suppressProtectedReconnect = false
        cancelProtectedReconnectTask()
        guard let request = StartVpnRequest.startModel else {
            suppressProtectedReconnect = true
            await refreshVpn()
            if let vpn = vpn {
                await disableAutomaticReconnect(
                    vpn,
                    logMessage: "VPN on-demand reconnect disabled because start request was missing",
                    clearRuntimeRequest: true
                )
            }
            return false
        }

        do {
            await refreshVpn()
            if let vpn = vpn {
                if let tun = request.tun {
                    try await saveVpn(vpn: vpn, tun: tun, request: request)
                } else {
                    try await saveVpn(vpn: vpn, tun: TunJson(), request: request)
                }
                if let session = vpn.connection as? NETunnelProviderSession {
                    if Constants.useSystemExtension {
                        try session.startTunnel(options: ["source": "app" as NSString])
                        try await syncDatAndStart(session: session)
                    } else {
                        try session.startTunnel()
                    }
                    return true
                } else {
                    suppressProtectedReconnect = true
                    await disableAutomaticReconnect(
                        vpn,
                        logMessage: "VPN on-demand reconnect disabled after failed start",
                        clearRuntimeRequest: true
                    )
                    return false
                }
            } else {
                suppressProtectedReconnect = true
                return false
            }
        } catch {
            YGLog(error)
            suppressProtectedReconnect = true
            cancelProtectedReconnectTask()
            if let vpn = vpn {
                await disableAutomaticReconnect(
                    vpn,
                    logMessage: "VPN on-demand reconnect disabled after failed start",
                    clearRuntimeRequest: true
                )
            }
            return false
        }
    }

    func stopVpn() async {
        suppressProtectedReconnect = true
        cancelProtectedReconnectTask()
        await refreshVpn()
        if let vpn = vpn {
            await disableAutomaticReconnect(
                vpn,
                logMessage: "VPN on-demand reconnect disabled for stop request",
                clearRuntimeRequest: true
            )
            switch vpn.connection.status {
            case .connecting, .connected, .reasserting, .disconnecting:
                if let session = vpn.connection as? NETunnelProviderSession {
                    session.stopTunnel()
                }
            case .disconnected:
                runStatusObserver()
            case .invalid:
                runStatusObserver()
            @unknown default:
                if let session = vpn.connection as? NETunnelProviderSession {
                    session.stopTunnel()
                }
            }
        }
    }

    private func disableAutomaticReconnectAfterDisconnect() async {
        guard let vpn = vpn else {
            return
        }
        guard vpn.connection.status == .disconnected else {
            return
        }
        await disableAutomaticReconnectIfUnused(vpn)
    }

    private func disableAutomaticReconnectIfUnused(_ vpn: NETunnelProviderManager) async {
        guard vpn.isOnDemandEnabled || vpn.onDemandRules != nil else {
            return
        }
        guard !requestWantsOnDemand(vpn) else {
            return
        }

        await disableAutomaticReconnect(vpn, logMessage: "VPN on-demand reconnect disabled after disconnect")
    }

    private func disableAutomaticReconnect(
        _ vpn: NETunnelProviderManager,
        logMessage: String,
        clearRuntimeRequest: Bool = false
    ) async {
        vpn.isOnDemandEnabled = false
        vpn.onDemandRules = nil
        vpn.protocolConfiguration?.disconnectOnSleep = false
        if clearRuntimeRequest {
            clearProviderRuntimeRequest(vpn)
            // A stopped tunnel must not keep capturing traffic; the next
            // start writes the user's setting again.
            applyTrafficCapture(vpn, strict: false)
        }
        do {
            try await vpn.saveToPreferences()
            try await vpn.loadFromPreferences()
            YGLog(logMessage)
            if clearRuntimeRequest {
                YGLog("VPN provider runtime request cleared")
            }
        } catch {
            YGLog("VPN on-demand disable failed: \(error.localizedDescription)")
        }
    }

    private func clearProviderRuntimeRequest(_ vpn: NETunnelProviderManager) {
        guard let conf = vpn.protocolConfiguration as? NETunnelProviderProtocol else {
            YGLog("VPN provider runtime request clear skipped: missing tunnel protocol configuration")
            return
        }
        var providerConfig = conf.providerConfiguration ?? [:]
        let hadRequest = providerConfig["request"] != nil
        let hadXrayJson = providerConfig["xrayJson"] != nil
        providerConfig.removeValue(forKey: "request")
        providerConfig.removeValue(forKey: "xrayJson")
        conf.providerConfiguration = providerConfig
        YGLog("VPN provider runtime request clear prepared request=\(hadRequest) xrayJson=\(hadXrayJson)")
    }

    private func reconnectAfterProtectedDisconnect() -> Bool {
        guard !suppressProtectedReconnect else {
            YGLog("VPN protected reconnect suppressed because stop was requested")
            return false
        }
        guard let vpn = vpn else {
            YGLog("VPN protected reconnect skipped: manager is missing")
            return false
        }
        guard vpn.connection.status == .disconnected else {
            YGLog("VPN protected reconnect skipped: status is \(vpn.connection.status.rawValue), expected disconnected")
            return false
        }
        guard requestWantsOnDemand(vpn) || canFallbackToManagerOnDemand(vpn) else {
            YGLog("VPN protected reconnect skipped: on-demand request is not enabled")
            return false
        }
        guard protectedReconnectTask == nil else {
            YGLog("VPN protected reconnect already scheduled")
            return true
        }

        protectedReconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            defer {
                self.protectedReconnectTask = nil
            }
            guard !Task.isCancelled else {
                return
            }
            guard !self.suppressProtectedReconnect else {
                YGLog("VPN protected reconnect suppressed because stop was requested")
                return
            }
            guard let vpn = self.vpn else {
                YGLog("VPN protected reconnect cancelled: manager is missing")
                return
            }
            guard vpn.connection.status == .disconnected else {
                YGLog("VPN protected reconnect cancelled: status is \(vpn.connection.status.rawValue), expected disconnected")
                return
            }
            guard self.requestWantsOnDemand(vpn) || self.canFallbackToManagerOnDemand(vpn) else {
                YGLog("VPN protected reconnect cancelled: on-demand request is not enabled")
                return
            }
            YGLog("VPN protected reconnect after disconnect")
            _ = await self.startVpn()
        }
        return true
    }

    private func cancelProtectedReconnectTask() {
        protectedReconnectTask?.cancel()
        protectedReconnectTask = nil
    }

    private func requestWantsOnDemand(_ vpn: NETunnelProviderManager) -> Bool {
        guard let conf = vpn.protocolConfiguration as? NETunnelProviderProtocol else {
            YGLog("VPN requestWantsOnDemand=false: missing tunnel protocol configuration managerOnDemand=\(vpn.isOnDemandEnabled)")
            return false
        }
        guard let providerConfig = conf.providerConfiguration else {
            YGLog("VPN requestWantsOnDemand=false: providerConfiguration missing managerOnDemand=\(vpn.isOnDemandEnabled)")
            return false
        }
        guard let encodedRequest = providerConfig["request"] as? Data else {
            let keys = providerConfig.keys.sorted().joined(separator: ",")
            YGLog("VPN requestWantsOnDemand=false: providerConfiguration request missing managerOnDemand=\(vpn.isOnDemandEnabled) providerKeys=\(keys)")
            return false
        }
        do {
            let request = try JSONDecoder().decode(StartVpnRequest.self, from: encodedRequest)
            let tunOnDemandEnabled = request.tun?.onDemandEnabled == true
            YGLog("VPN requestWantsOnDemand=\(tunOnDemandEnabled): request=true tun.onDemandEnabled=\(String(describing: request.tun?.onDemandEnabled)) managerOnDemand=\(vpn.isOnDemandEnabled)")
            return tunOnDemandEnabled
        } catch {
            YGLog("VPN requestWantsOnDemand=false: request decode failed \(error.localizedDescription)")
            return false
        }
    }

    private func canFallbackToManagerOnDemand(_ vpn: NETunnelProviderManager) -> Bool {
        guard vpn.isOnDemandEnabled else {
            return false
        }
        guard let conf = vpn.protocolConfiguration as? NETunnelProviderProtocol else {
            YGLog("VPN protected reconnect fallback unavailable: missing tunnel protocol configuration")
            return false
        }
        let hasRuntimeRequest = (conf.providerConfiguration?["request"] as? Data) != nil
        guard !hasRuntimeRequest else {
            return false
        }
        YGLog("VPN protected reconnect fallback enabled: manager on-demand is true but provider request is missing")
        return true
    }
    
    private func saveVpn(vpn: NETunnelProviderManager, tun: TunJson, request: StartVpnRequest? = nil) async throws {
        vpn.isEnabled = true
        if let request, let conf = vpn.protocolConfiguration as? NETunnelProviderProtocol {
            var providerConfig = conf.providerConfiguration ?? [:]
            let encodedRequest: Data
            if Constants.useSystemExtension {
                let rewritten = rewriteRequestForExtension(request)
                encodedRequest = try JSONEncoder().encode(rewritten)
                if let xrayJson = readAndRewriteXrayJson() {
                    providerConfig["xrayJson"] = xrayJson
                }
            } else {
                encodedRequest = try JSONEncoder().encode(request)
            }
            providerConfig["request"] = encodedRequest
            conf.providerConfiguration = providerConfig
            // NETunnelProviderManager persists a copied protocol object.
            // Reassign it explicitly so the freshly encoded runtime request
            // is guaranteed to reach the packet-tunnel extension.
            vpn.protocolConfiguration = conf
        }
        // Written on every save, not only when the profile is first created,
        // so existing installs pick the setting up on their next connect.
        applyTrafficCapture(vpn, strict: tun.includeAllNetworks == true)
        if let onDemandEnabled = tun.onDemandEnabled, onDemandEnabled {
            if let rules = tun.onDemandRules, !rules.isEmpty {
                let onDemandRules = convertRules(rules)
                if onDemandRules.isEmpty {
                    vpn.isOnDemandEnabled = false
                    vpn.onDemandRules = nil
                } else {
                    vpn.isOnDemandEnabled = true
                    vpn.onDemandRules = onDemandRules
                }
            } else {
                vpn.isOnDemandEnabled = true
                vpn.onDemandRules = [NEOnDemandRuleConnect()]
            }
            if let disconnectOnSleep = tun.disconnectOnSleep, disconnectOnSleep {
                vpn.protocolConfiguration?.disconnectOnSleep = true
            } else {
                vpn.protocolConfiguration?.disconnectOnSleep = false
            }
        } else {
            vpn.isOnDemandEnabled = false
            vpn.onDemandRules = nil
            vpn.protocolConfiguration?.disconnectOnSleep = false
        }
        try await vpn.saveToPreferences()
        try await vpn.loadFromPreferences()
    }

    /// Strict kill switch. With `includeAllNetworks` iOS sends all traffic
    /// into the tunnel (also connections opened before it came up) and
    /// drops it while the tunnel is connecting or reconnecting, instead of
    /// letting it out unprotected; the extension's own sockets stay exempt.
    /// `enforceRoutes` keeps more specific routes of the local network from
    /// overriding the tunnel's. Local networks (printers, AirDrop, AirPlay,
    /// CarPlay over Wi-Fi) stay reachable outside the tunnel either way.
    private func applyTrafficCapture(_ vpn: NETunnelProviderManager, strict: Bool) {
        guard let conf = vpn.protocolConfiguration else { return }
        if #available(iOS 14.2, macOS 11.0, *) {
            conf.includeAllNetworks = strict
            conf.excludeLocalNetworks = true
            conf.enforceRoutes = strict
        }
        vpn.protocolConfiguration = conf
        YGLog("VPN traffic capture includeAllNetworks=\(strict) enforceRoutes=\(strict) excludeLocalNetworks=true")
    }


    private func convertRules(_ rules: [OnDemandRule]) -> [NEOnDemandRule] {
        var onDemandRules: [NEOnDemandRule] = []
        for rule in rules {
            if let onDemandRule = convertRule(rule) {
                onDemandRules.append(onDemandRule)
            }
        }
        return onDemandRules
    }
    
    private func convertRule(_ rule: OnDemandRule) -> NEOnDemandRule? {
        if let mode = rule.mode {
            switch mode {
            case .connect:
                let onDemandRule = NEOnDemandRuleConnect()
                if fillOnDemandRule(onDemandRule, rule) {
                    return onDemandRule
                }
                
            case .disconnect:
                let onDemandRule = NEOnDemandRuleDisconnect()
                if fillOnDemandRule(onDemandRule, rule) {
                    return onDemandRule
                }
            }
        }
        return nil
    }
    
    private func fillOnDemandRule(_ onDemandRule: NEOnDemandRule, _ rule: OnDemandRule) -> Bool {
        guard let interfaceType = rule.interfaceType else {
            return false
        }
        let interfaceTypeMatch = convertInterfaceType(interfaceType)
        onDemandRule.interfaceTypeMatch = interfaceTypeMatch
        if interfaceTypeMatch == .wiFi {
            if let ssid = rule.ssid, !ssid.isEmpty {
                onDemandRule.ssidMatch = ssid
            }
        }
        return true
    }
    
    private func convertInterfaceType(_ interfaceType: OnDemandRuleInterfaceType) -> NEOnDemandRuleInterfaceType {
        switch interfaceType {
        case .any:
            return .any
        case .wifi:
            return .wiFi
#if os(macOS)
        case .ethernet:
            return .ethernet
        case .cellular:
            return .any
#else
        case .cellular:
            return .cellular
        case .ethernet:
            return .any
#endif
        }
    }

    // MARK: - System Extension path rewriting + XPC dat sync

    private func pathMapping() -> (user: String, ext: String)? {
        guard let userGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId()),
              let extGroup = extensionGroupContainerURL() else {
            return nil
        }
        var u = userGroup.adaptedPath()
        var e = extGroup.adaptedPath()
        while u.hasSuffix("/") { u.removeLast() }
        while e.hasSuffix("/") { e.removeLast() }
        if u == e { return nil }
        return (u, e)
    }

    private func rewriteRequestForExtension(_ request: StartVpnRequest) -> StartVpnRequest {
        guard let mapping = pathMapping() else { return request }
        var newRequest = request
        if let coreBase64 = request.coreBase64Text,
           let data = Data(base64Encoded: coreBase64),
           let text = String(data: data, encoding: .utf8) {
            let rewritten = text.replacingOccurrences(of: mapping.user, with: mapping.ext)
            if let rewrittenData = rewritten.data(using: .utf8) {
                newRequest.coreBase64Text = rewrittenData.base64EncodedString()
            }
        }
        return newRequest
    }

    private func readAndRewriteXrayJson() -> Data? {
        guard let userGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId()) else {
            return nil
        }
        let xrayURL = userGroup.adaptedAppendPath(path: "run/xray.json")
        guard let data = try? Data(contentsOf: xrayURL) else { return nil }
        guard let mapping = pathMapping() else { return data }
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let rewritten = text.replacingOccurrences(of: mapping.user, with: mapping.ext)
        return rewritten.data(using: .utf8) ?? data
    }

    private func syncDatAndStart(session: NETunnelProviderSession) async throws {
        try await waitSessionMessageable(session: session)

        let remote: [String: Int64]
        let listResp = try await sendTunnelRequest(session: session, .listDat)
        if case let .datManifest(m) = listResp {
            remote = m
        } else {
            remote = [:]
        }

        let local = buildLocalDatManifest()
        if needsDatSync(local: local, remote: remote) {
            YGLog("dat manifest mismatch, syncing \(local.count) files")
            _ = try await sendTunnelRequest(session: session, .clearDat)
            for (name, mtime) in local {
                guard let content = try? readLocalDatFile(name: name) else { continue }
                _ = try await sendTunnelRequest(session: session, .putDat(name: name, content: content, mtimeMs: mtime))
            }
            _ = try await sendTunnelRequest(session: session, .commitDat)
        } else {
            YGLog("dat manifest in sync")
        }

        _ = try await sendTunnelRequest(session: session, .startXray)
    }

    private func waitSessionMessageable(session: NETunnelProviderSession, timeout: TimeInterval = 10) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            switch session.status {
            case .connecting, .connected, .reasserting:
                return
            default:
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VPNError.sessionNotReady
    }

    private func sendTunnelRequest(session: NETunnelProviderSession, _ request: TunnelRequest) async throws -> TunnelResponse {
        let data = try TunnelMessageCoder.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    guard let response else {
                        continuation.resume(returning: .ok)
                        return
                    }
                    do {
                        let decoded = try TunnelMessageCoder.decode(TunnelResponse.self, from: response)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func buildLocalDatManifest() -> [String: Int64] {
        let fm = FileManager.default
        guard let userGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId()) else {
            return [:]
        }
        let datDir = userGroup.adaptedAppendPath(path: "dat")
        guard let entries = try? fm.contentsOfDirectory(at: datDir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return [:]
        }
        var result: [String: Int64] = [:]
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let mtime = values?.contentModificationDate else { continue }
            result[url.lastPathComponent] = Int64(mtime.timeIntervalSince1970 * 1000)
        }
        return result
    }

    private func readLocalDatFile(name: String) throws -> Data {
        guard let userGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId()) else {
            throw VPNError.noGroupContainer
        }
        let url = userGroup.adaptedAppendPath(path: "dat").adaptedAppendPath(path: name)
        return try Data(contentsOf: url)
    }

    private func needsDatSync(local: [String: Int64], remote: [String: Int64]) -> Bool {
        if Set(local.keys) != Set(remote.keys) { return true }
        for (name, localMtime) in local {
            guard let remoteMtime = remote[name] else { return true }
            if abs(localMtime - remoteMtime) > 1000 { return true }
        }
        return false
    }
}

import Foundation
import Network
import NetworkExtension
import Darwin

enum TunnelError: Error {
    case noSocketFd
    case noStartModel
    case noGroupContainer
    case startXrayTimeout
    case coreStartFailed
    case packetFlowBridgeFailed
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let stateQueue = DispatchQueue(label: "com.colitu.vpn.tunnel.state")
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var pendingStartSignal = false
    private let pathQueue = DispatchQueue(label: "com.colitu.vpn.tunnel.path")
    private var pathMonitor: Network.NWPathMonitor?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    // The keepalive, path, wake and memory checks run as separate tasks and can
    // all ask for a reconnect at once; the lock makes "is one running, else
    // start one" a single step, so two never restart the core in parallel.
    private let reconnectLock = NSLock()
    private var reconnectTaskID: UUID?
    private var pathRecoveryTask: Task<Void, Never>?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var powerObserver: NSObjectProtocol?
    private var currentCoreBase64Text: String?
    private var currentProfile = TunnelProfileInfo()
    private var currentPath = TunnelPathInfo()
    private var state: TunnelStabilityState = .disconnected
    private var reconnectAttempt = 0
    /// `awakeClock` reading when the current reconnect episode began; nil
    /// outside an episode.
    private var reconnectStartedUptime: TimeInterval?
    private var lastPathChangeAt: Date?
    private var lastSuccessfulProbeAt: Date?
    private var keepAliveFailCount = 0
    private var tunnelShouldRun = false
    private var userInitiatedStop = false
    private var restartingCore = false
    private var coreRunning = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let packetBridgeLock = NSLock()
    private var packetBridgeSwiftFD: Int32 = -1
    private var packetBridgeTunFD: Int32 = -1
    private let tun2socks = Tun2Socks()
    /// Loopback port of the core's probe inbound (0 while the core is down).
    private var probeSocksPort: UInt16 = 0
    /// Credentials of the core's loopback SOCKS inbounds, new for every core
    /// start. Any app on the device can reach 127.0.0.1: without them the
    /// ports were an open proxy and an easy way to tell that a VPN runs.
    private var socksUser = ""
    private var socksPass = ""
    private var sleptAt: Date?
    private var lastWakeAt: Date?
    /// The proxy server's name and the IPv4 address it had when the tunnel
    /// started (also the address excluded from the tunnel's routes).
    private var pinnedServer: PinnedServer?
    private var lastReachabilityCheckAt: Date?
    /// Network interface type the running core was started on.
    private var coreInterfaceType = "unknown"
    /// Automatic (non-crash) core restarts, for the restart budget.
    private var automaticRestarts: [Date] = []
    /// Core restarts in a row whose validation failed. Two of them mean the
    /// server (or its network) is the problem, not the local core; the app
    /// reads `serverProblem` from the heartbeat and offers another server.
    private var failedRestarts = 0
    private var serverProblem = false
    private var packetBridgeGeneration: UInt64 = 0
    private var packetBridgeRunning = false
    /// Guarded by packetBridgeLock. The one readPackets chain of this
    /// provider; it outlives bridges (see forwardPacketsFromSystem).
    private var systemPacketReaderStarted = false
    private let traffic = TrafficCounter()
    private var trafficReportTask: Task<Void, Never>?


    /// iOS kills a packet-tunnel extension that grows past roughly 50 MB,
    /// without calling stopTunnel. The Go heap gets a soft limit well below
    /// that, and freed pages are handed back once the footprint gets close.
    /// The Go heap plus goroutine stacks reach 22-24 MB under load; a 20 MB
    /// soft limit kept the GC running ~20 times a second.
    private static let goMemoryLimitBytes: Int64 = 26 << 20
    private static let goGCPercent: Int32 = 50
    private static let goMaxProcs: Int32 = 2
    private static let memoryTrimThreshold: UInt64 = 34 << 20
    /// Seconds between two trims. Each one is a full GC.
    private static let memoryTrimInterval = 10
    private var peakFootprint: UInt64 = 0
    private var trafficTicks = 0
    private var lastTrimTick = 0
    private var lastSampleUp: UInt64 = 0
    private var lastSampleDown: UInt64 = 0
    private static let sampleIntervalTicks = 120
    /// Memory the Go runtime holds from the OS (heap, stacks, runtime
    /// metadata), sampled every few seconds for the drop report.
    private var goSysBytes: UInt64 = 0
    /// Last breakdown of the footprint, one line, for the drop report.
    private var memoryDetail = ""
    /// Above this footprint the core is restarted before iOS kills the
    /// extension (devices on iOS 26 kill it at about 45 MB).
    private static let memoryRestartThreshold: UInt64 = 43 << 20
    private var lastMemoryRestartTick = -1000

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        // A previous run that never reached stopTunnel was killed by iOS or
        // crashed; its stderr log tells which. Read it before reopening it.
        recordPreviousExitIfUnclean(onDemand: options == nil)
        redirectStandardError()
        setStabilityState(.connecting, reason: "startTunnel")
        userInitiatedStop = false
        tunnelShouldRun = true
        if Constants.useSystemExtension {
            try await startTunnelSE(options: options)
        } else {
            try await startTunnelLegacy()
        }
    }

    private func startTunnelLegacy() async throws {
        guard let request = StartVpnRequest.startModel else {
            YGLog("startTunnel noStartModel")
            throw TunnelError.noStartModel
        }
        let settings = buildSettings(request: request)
        try await setTunnelNetworkSettings(settings)
        if let coreBase64Text = request.coreBase64Text {
            prepareStability(coreBase64Text: coreBase64Text)
            try startXray(coreBase64Text)
        }
        startStabilityLayer()
        YGLog("startTunnel finished")
    }

    private func startTunnelSE(options: [String: NSObject]?) async throws {
        guard let providerConfig = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            YGLog("startTunnel no providerConfiguration")
            throw TunnelError.noStartModel
        }
        guard let requestData = providerConfig["request"] as? Data,
              let request = try? JSONDecoder().decode(StartVpnRequest.self, from: requestData) else {
            YGLog("startTunnel decode request failed")
            throw TunnelError.noStartModel
        }

        guard let extGroupURL = extensionGroupContainerURL() else {
            YGLog("startTunnel noGroupContainer")
            throw TunnelError.noGroupContainer
        }

        // Prepare extension-side directories.
        let runDir = extGroupURL.adaptedAppendPath(path: "run")
        let datDir = extGroupURL.adaptedAppendPath(path: "dat")
        let stagingDir = extGroupURL.adaptedAppendPath(path: "dat.staging")
        let fm = FileManager.default
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: datDir, withIntermediateDirectories: true)
        // Abandoned staging from an aborted previous sync → discard.
        try? fm.removeItem(at: stagingDir)

        // Materialize xray.json (already path-rewritten by the app).
        if let xrayJson = providerConfig["xrayJson"] as? Data {
            let xrayURL = runDir.adaptedAppendPath(path: "xray.json")
            do {
                try xrayJson.write(to: xrayURL)
            } catch {
                YGLog("startTunnel write xray.json error: \(error)")
            }
        }

        // App-driven path waits for the dat sync + start_xray signal.
        // On-demand path skips the wait and uses whatever is already in dat/.
        if options != nil {
            YGLog("startTunnel awaiting start_xray signal")
            try await waitStartSignal(timeout: 30)
        } else {
            YGLog("startTunnel on-demand, skipping XPC sync")
        }

        let settings = buildSettings(request: request)
        try await setTunnelNetworkSettings(settings)

        if let coreBase64Text = request.coreBase64Text {
            prepareStability(coreBase64Text: coreBase64Text)
            try startXray(coreBase64Text)
        }
        startStabilityLayer()
    }

    private func buildSettings(request: StartVpnRequest) -> NEPacketTunnelNetworkSettings {
        let profile = request.coreBase64Text.map(TunnelProfileInfo.fromCoreRequest) ?? TunnelProfileInfo()
        let remoteAddress = profile.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredRemoteAddress = (remoteAddress?.isEmpty == false ? remoteAddress : nil) ?? ProxyHost
        // Endpoint hostnames must also be excluded from the default tunnel
        // route. Resolve them before installing the route; otherwise the
        // core's own transport socket is captured by the TUN it is trying to
        // establish.
        let routedRemoteAddress = resolveIPv4Address(configuredRemoteAddress) ?? configuredRemoteAddress
        // Resolved here, before the tunnel's DNS settings apply. Once they
        // do, every lookup (the core's own included) goes to the tunnel's
        // DNS, which answers through the proxy: the core could not resolve
        // its own server whenever the cached answer had expired (after a
        // sleep, typically) and every restart hung until iOS found another
        // path. The core is given this address instead of the name.
        if let host = remoteAddress, !host.isEmpty, !isIPv4Address(host), isIPv4Address(routedRemoteAddress) {
            pinnedServer = PinnedServer(host: host, ipv4: routedRemoteAddress)
        } else {
            pinnedServer = nil
        }
        let ipv4 = NEIPv4Settings(addresses: ["192.168.20.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if isIPv4Address(routedRemoteAddress) {
            // The VPN core opens its transport socket from inside the packet
            // tunnel extension. Excluding the real server endpoint prevents
            // that socket from being captured by the default TUN route and
            // fed back into the tunnel before the core can connect.
            ipv4.excludedRoutes = [
                NEIPv4Route(
                    destinationAddress: routedRemoteAddress,
                    subnetMask: "255.255.255.255"
                )
            ]
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: routedRemoteAddress)
        settings.ipv4Settings = ipv4
        settings.mtu = TunMtu
        var servers: [String] = []
        if let tun = request.tun {
            if let tunDnsIPv4 = tun.tunDnsIPv4 {
                servers.append(tunDnsIPv4)
            }
            if let enableIPv6 = tun.enableIPv6, enableIPv6 {
                let ipv6 = NEIPv6Settings(addresses: ["FC00::0001"], networkPrefixLengths: [7])
                ipv6.includedRoutes = [NEIPv6Route.default()]
                settings.ipv6Settings = ipv6
                if let tunDnsIPv6 = tun.tunDnsIPv6 {
                    servers.append(tunDnsIPv6)
                }
            }

            if let enableDot = tun.enableDot, enableDot {
                let dnsSettings = NEDNSOverTLSSettings(servers: servers)
                if let serverName = tun.dnsServerName {
                    dnsSettings.serverName = serverName
                }
                dnsSettings.matchDomains = [""]
                settings.dnsSettings = dnsSettings
            } else {
                let dnsSettings = NEDNSSettings(servers: servers)
                dnsSettings.matchDomains = [""]
                settings.dnsSettings = dnsSettings
            }
        }
        return settings
    }

    private func isIPv4Address(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.count <= 3,
                  octet.allSatisfy({ $0.isNumber }),
                  UInt8(String(octet)) != nil else {
                return false
            }
            return true
        }
    }

    private func resolveIPv4Address(_ host: String) -> String? {
        if isIPv4Address(host) { return host }

        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0,
              let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET,
               let socketAddress = info.pointee.ai_addr {
                let status = getnameinfo(
                    socketAddress,
                    info.pointee.ai_addrlen,
                    &address,
                    socklen_t(address.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    return String(cString: address)
                }
            }
            cursor = info.pointee.ai_next
        }
        return nil
    }

    private func waitStartSignal(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.stateQueue.async {
                if self.pendingStartSignal {
                    self.pendingStartSignal = false
                    continuation.resume(returning: ())
                    return
                }
                self.startContinuation = continuation
                let deadline = DispatchTime.now() + timeout
                Self.stateQueue.asyncAfter(deadline: deadline) {
                    if let c = self.startContinuation {
                        self.startContinuation = nil
                        c.resume(throwing: TunnelError.startXrayTimeout)
                    }
                }
            }
        }
    }

    private func fulfillStartSignal() {
        Self.stateQueue.async {
            if let c = self.startContinuation {
                self.startContinuation = nil
                c.resume(returning: ())
            } else {
                self.pendingStartSignal = true
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        userInitiatedStop = reason == .userInitiated
        tunnelShouldRun = false
        let reasonName = Self.stopReasonName(reason)
        stabilityLog("tunnel_stopped", reason: reasonName)
        if !userInitiatedStop {
            stabilityLog("tunnel_stopped_unexpectedly", reason: reasonName)
        }
        // Every stop is recorded; the app ignores the ones it asked for itself.
        let footprint = Self.memoryFootprint()
        appendDrop([
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
            "kind": reasonName,
            "mem": footprint,
            "peak": max(peakFootprint, footprint)
        ])
        stopStabilityLayer()
        self.stopXray()
        setStabilityState(.disconnected, reason: userInitiatedStop ? "manual_disconnect" : "stopTunnel")
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        sleptAt = Date()
        stabilityLog("tunnel_sleep", reason: "provider_sleep")
        completionHandler()
    }

    override func wake() {
        let slept = sleptAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        sleptAt = nil
        lastWakeAt = Date()
        stabilityLog("tunnel_wake", reason: "provider_wake", metadata: ["sleptSec": slept])
        guard tunnelShouldRun, state != .networkUnavailable else { return }
        handleProviderWake(sleptSeconds: slept)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        if Constants.useSystemExtension {
            return handleAppMessageSE(messageData)
        }
        return messageData
    }

    private func handleAppMessageSE(_ data: Data) -> Data? {
        let request: TunnelRequest
        do {
            request = try TunnelMessageCoder.decode(TunnelRequest.self, from: data)
        } catch {
            YGLog("handleAppMessage decode error: \(error)")
            return try? TunnelMessageCoder.encode(TunnelResponse.error("decode"))
        }

        let response: TunnelResponse
        switch request {
        case .listDat:
            response = .datManifest(listDatManifest())
        case .clearDat:
            response = clearStaging() ? .ok : .error("clear")
        case let .putDat(name, content, mtimeMs):
            response = putStaged(name: name, content: content, mtimeMs: mtimeMs) ? .ok : .error("put \(name)")
        case .commitDat:
            response = commitStaging() ? .ok : .error("commit")
        case .startXray:
            fulfillStartSignal()
            response = .ok
        }
        return try? TunnelMessageCoder.encode(response)
    }

    // MARK: - dat staging operations

    private func datDir() -> URL? {
        extensionGroupContainerURL()?.adaptedAppendPath(path: "dat")
    }

    private func stagingDir() -> URL? {
        extensionGroupContainerURL()?.adaptedAppendPath(path: "dat.staging")
    }

    private func listDatManifest() -> [String: Int64] {
        let fm = FileManager.default
        guard let dir = datDir(),
              let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
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

    private func clearStaging() -> Bool {
        let fm = FileManager.default
        guard let dir = stagingDir() else { return false }
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            YGLog("clearStaging error: \(error)")
            return false
        }
    }

    private func putStaged(name: String, content: Data, mtimeMs: Int64) -> Bool {
        let fm = FileManager.default
        guard let dir = stagingDir() else { return false }
        // Reject path traversal. File names must be single segments.
        let sanitized = (name as NSString).lastPathComponent
        guard !sanitized.isEmpty, sanitized == name else {
            YGLog("putStaged invalid name: \(name)")
            return false
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.adaptedAppendPath(path: sanitized)
        do {
            try content.write(to: target)
            let date = Date(timeIntervalSince1970: TimeInterval(mtimeMs) / 1000.0)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.adaptedPath())
            return true
        } catch {
            YGLog("putStaged write \(sanitized) error: \(error)")
            return false
        }
    }

    private func commitStaging() -> Bool {
        let fm = FileManager.default
        guard let staging = stagingDir(), let dat = datDir() else { return false }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: staging.adaptedPath(), isDirectory: &isDir), isDir.boolValue else {
            YGLog("commitStaging: staging missing")
            return false
        }
        let parent = dat.deletingLastPathComponent()
        let backup = parent.adaptedAppendPath(path: "dat.old")
        try? fm.removeItem(at: backup)
        // If current dat/ exists, move aside first; otherwise just rename staging → dat.
        if fm.fileExists(atPath: dat.adaptedPath()) {
            do {
                try fm.moveItem(at: dat, to: backup)
            } catch {
                YGLog("commitStaging move dat→dat.old error: \(error)")
                return false
            }
        }
        do {
            try fm.moveItem(at: staging, to: dat)
        } catch {
            YGLog("commitStaging move staging→dat error: \(error)")
            // Rollback.
            if fm.fileExists(atPath: backup.adaptedPath()) {
                try? fm.moveItem(at: backup, to: dat)
            }
            return false
        }
        try? fm.removeItem(at: backup)
        return true
    }

    // MARK: - Xray lifecycle

    /// The packet path is iOS → packet bridge → hev-socks5-tunnel (C, lwIP) →
    /// Xray's local SOCKS5 inbound → outbound. Xray's own TUN inbound runs a
    /// gVisor TCP stack whose per-connection buffers are far too large for
    /// the extension's memory cap, so it is never started on iOS.
    private func startXray(_ base64Text: String) throws {
        if tun2socks.isRunning {
            // hev keeps global state: a second instance must never start
            // while the previous one is still shutting down.
            _ = tun2socks.stop(timeout: 2)
            guard !tun2socks.isRunning else {
                stabilityLog("core_start_failed", reason: "tun2socks_still_running")
                throw TunnelError.coreStartFailed
            }
        }
        guard let socksPort = Self.freeLoopbackPort(),
              let probePort = Self.freeLoopbackPort(excluding: socksPort) else {
            stabilityLog("core_start_failed", reason: "no_free_socks_port")
            throw TunnelError.coreStartFailed
        }
        let user = Self.socksCredential()
        let pass = Self.socksCredential()
        let coreRequest: String
        do {
            coreRequest = try Self.socksCoreRequest(
                from: base64Text,
                socksPort: socksPort,
                probePort: probePort,
                socksUser: user,
                socksPass: pass,
                pinnedServer: pinnedServer
            )
        } catch {
            stabilityLog("core_start_failed", reason: "socks_config_failed", error: "\(error)")
            throw TunnelError.coreStartFailed
        }
        let bridge = try openPacketFlowBridge()
        // Keep the Go heap well under the extension's memory cap.
        CGoSetMaxProcs(Self.goMaxProcs)
        CGoSetMemoryLimit(Self.goMemoryLimitBytes, Self.goGCPercent)
        let res = coreRequest.withCString { p in
            let p0 = UnsafeMutablePointer(mutating: p)
            return CGoRunXray(p0)
        }
        let result = CallResponse.fromResponse(res)
        guard result.success else {
            coreRunning = false
            closePacketFlowBridge()
            YGLog("PacketTunnelProvider startXray \(String(describing: result.error))")
            stabilityLog(
                "core_start_failed",
                reason: "core_process_failed",
                error: result.error
            )
            throw TunnelError.coreStartFailed
        }
        coreRunning = CGoGetXrayState() != 0
        guard coreRunning else {
            closePacketFlowBridge()
            stabilityLog("core_start_failed", reason: "core_not_running_after_start")
            throw TunnelError.coreStartFailed
        }
        let generation = bridge.generation
        tun2socks.start(
            config: Tun2Socks.config(socksPort: socksPort, mtu: TunMtu.intValue, username: user, password: pass),
            fd: bridge.tunFD
        ) { [weak self] result, requested in
            // Expected after stopXray; anything else is a failure the
            // keepalive loop turns into a reconnect.
            guard !requested, let self, self.packetBridgeIsRunning(generation, fd: bridge.swiftFD) else { return }
            self.stabilityLog("tun2socks_exited", reason: "unexpected", metadata: ["result": Int(result)])
        }
        startPacketFlowBridge(swiftFD: bridge.swiftFD, generation: bridge.generation)
        socksUser = user
        socksPass = pass
        probeSocksPort = probePort
        coreInterfaceType = currentPath.interfaceType
        stabilityLog("core_started", reason: "start_xray", metadata: [
            "socksPort": Int(socksPort),
            "pinned": pinnedServer != nil
        ])
        setStabilityState(.connected, reason: "core_started")
    }

    private func stopXray() {
        stabilityLog("core_stopped", reason: "stop_xray")
        coreRunning = false
        probeSocksPort = 0
        // tun2socks first: it closes its SOCKS connections before Xray and
        // the bridge sockets go away underneath it.
        let startedAt = Date()
        if !tun2socks.stop(timeout: 3) {
            stabilityLog("core_stop_failed", reason: "tun2socks_stop_timeout")
        }
        let hevDone = Date()
        // Close the QUIC sessions first: a core stop once took 27 s after the
        // network dropped, with the core's connections waiting on a dead
        // session; closed, they end at once and the stop does not block.
        CGoResetHysteria()
        let res = CGoStopXray()
        let coreDone = Date()
        // Xray keeps its Hysteria2 QUIC clients in a process-wide cache that
        // survives the core: drop anything dialed during the stop too, or the
        // next core reuses a connection that may be dead.
        CGoResetHysteria()
        closePacketFlowBridge()
        let result = CallResponse.fromResponse(res)
        if !result.success {
            stabilityLog("core_stop_failed", reason: "stop_xray_failed", error: result.error)
        }
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if totalMs >= 2000 {
            stabilityLog("core_stop_slow", reason: "stop_xray", metadata: [
                "totalMs": totalMs,
                "hevMs": Int(hevDone.timeIntervalSince(startedAt) * 1000),
                "coreMs": Int(coreDone.timeIntervalSince(hevDone) * 1000)
            ])
        }
    }

    /// Rewrites the core request so Xray listens on a local SOCKS5 inbound
    /// instead of its TUN inbound. The inbound keeps the TUN inbound's tag
    /// and sniffing, so routing rules (DNS hijack, direct/proxy) still match.
    /// A second SOCKS5 inbound serves the health probe; a routing rule ahead
    /// of all others sends it through the proxy outbound, so the probe tests
    /// the path apps depend on whatever the domain rules say.
    /// 32 hex characters: safe inside the core's JSON and hev's YAML as is.
    static func socksCredential() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func socksCoreRequest(
        from base64Text: String,
        socksPort: UInt16,
        probePort: UInt16,
        socksUser: String,
        socksPass: String,
        pinnedServer: PinnedServer? = nil
    ) throws -> String {
        guard let requestData = Data(base64Encoded: base64Text),
              var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let configPath = request["configPath"] as? String else {
            throw Tun2SocksConfigError.invalidRequest
        }
        let configURL = URL(fileURLWithPath: configPath)
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] else {
            throw Tun2SocksConfigError.invalidConfig
        }
        var replaced = false
        let inbounds = (config["inbounds"] as? [[String: Any]] ?? []).map { inbound -> [String: Any] in
            guard (inbound["protocol"] as? String) == "tun" else { return inbound }
            replaced = true
            var socks: [String: Any] = [
                "listen": ProxyHost,
                "port": Int(socksPort),
                "protocol": "socks",
                "settings": [
                    "auth": "password",
                    "accounts": [["user": socksUser, "pass": socksPass]],
                    "udp": true,
                    "ip": ProxyHost
                ] as [String: Any]
            ]
            if let tag = inbound["tag"] { socks["tag"] = tag }
            if let sniffing = inbound["sniffing"] { socks["sniffing"] = sniffing }
            return socks
        }
        guard replaced else { throw Tun2SocksConfigError.noTunInbound }
        // Dial failures, timeouts and TLS errors show up at "warning"; the
        // access log stays off (it would list every site visited).
        config["log"] = [
            "loglevel": "warning",
            "access": "none",
            "error": configURL.deletingLastPathComponent().adaptedAppendPath(path: coreErrorLogName).adaptedPath()
        ] as [String: Any]
        if let outbounds = config["outbounds"] as? [[String: Any]] {
            config["outbounds"] = outbounds.map { outbound in
                let capped = capQuicReceiveWindows(outbound)
                guard let pinnedServer else { return capped }
                return pinServerAddress(capped, to: pinnedServer)
            }
        }
        config["inbounds"] = inbounds + [[
            "listen": ProxyHost,
            "port": Int(probePort),
            "protocol": "socks",
            "settings": [
                "auth": "password",
                "accounts": [["user": socksUser, "pass": socksPass]],
                "udp": false
            ] as [String: Any],
            "tag": probeInboundTag
        ]]
        let outbounds = config["outbounds"] as? [[String: Any]] ?? []
        let proxyOutbound = outbounds.first(where: { outbound in
            !["freedom", "blackhole", "dns"].contains(outbound["protocol"] as? String ?? "") &&
                outbound["tag"] is String
        })
        let proxyTag = proxyOutbound?["tag"] as? String
        if let proxyOutbound, isQuicOutbound(proxyOutbound), let dns = config["dns"] as? [String: Any] {
            config["dns"] = dnsOverStreams(dns)
        }
        if let proxyTag {
            var routing = config["routing"] as? [String: Any] ?? [:]
            let rules = routing["rules"] as? [[String: Any]] ?? []
            let probeRule: [String: Any] = [
                "type": "field",
                "inboundTag": [probeInboundTag],
                "outboundTag": proxyTag
            ]
            routing["rules"] = [probeRule] + rules
            config["routing"] = routing
        }
        let socksConfigURL = configURL.deletingLastPathComponent()
            .adaptedAppendPath(path: "xray-tun2socks.json")
        try JSONSerialization.data(withJSONObject: config).write(to: socksConfigURL, options: .atomic)
        request["configPath"] = socksConfigURL.adaptedPath()
        return try JSONSerialization.data(withJSONObject: request).base64EncodedString()
    }

    static let probeInboundTag = "colituProbe"
    static let coreErrorLogName = "error.log"

    static func isQuicOutbound(_ outbound: [String: Any]) -> Bool {
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        return (outbound["protocol"] as? String) == "hysteria" || (stream["network"] as? String) == "hysteria"
    }

    /// Sends the core's DNS queries as TCP (a QUIC stream) instead of UDP
    /// when the proxy is Hysteria2. Over Hysteria, UDP travels as QUIC
    /// datagrams, which are never retransmitted: one lost query or answer
    /// left the lookup waiting for Xray's 4 s timeout, and every page load
    /// behind it with it. Right after a QUIC reset (a wake) the first
    /// queries can also reach the closing session and be lost. A stream is
    /// retransmitted by QUIC and needs no extra round trip to open.
    /// Plain nameservers ("1.1.1.1" or {"address": "1.1.1.1"}) become
    /// "tcp://1.1.1.1:53"; DoH, localhost, fakedns and others stay as they are.
    static func dnsOverStreams(_ dns: [String: Any]) -> [String: Any] {
        guard let servers = dns["servers"] as? [Any] else { return dns }
        func stream(_ address: String, port: Int?) -> String? {
            let ipv4 = address.split(separator: ".").count == 4 && address.allSatisfy { $0.isNumber || $0 == "." }
            let ipv6 = address.contains(":") && !address.contains("://") && !address.contains("[")
            guard ipv4 || ipv6 else { return nil }
            let host = ipv6 ? "[\(address)]" : address
            return "tcp://\(host):\(port ?? 53)"
        }
        var result = dns
        result["servers"] = servers.map { server -> Any in
            if let address = server as? String {
                return stream(address, port: nil) ?? address
            }
            if var row = server as? [String: Any], let address = row["address"] as? String,
               let converted = stream(address, port: (row["port"] as? NSNumber)?.intValue) {
                row["address"] = converted
                row.removeValue(forKey: "port")
                return row
            }
            return server
        }
        return result
    }

    /// Points a proxy outbound at the pinned IPv4 address instead of the
    /// server's name. TLS keeps the name as its server name (SNI and
    /// certificate check), so the handshake is unchanged.
    static func pinServerAddress(_ outbound: [String: Any], to server: PinnedServer) -> [String: Any] {
        guard !["freedom", "blackhole", "dns"].contains(outbound["protocol"] as? String ?? "") else { return outbound }
        var pinned = false
        func pin(_ row: [String: Any]) -> [String: Any] {
            guard let address = row["address"] as? String,
                  address.caseInsensitiveCompare(server.host) == .orderedSame else { return row }
            pinned = true
            var copy = row
            copy["address"] = server.ipv4
            return copy
        }
        var result = outbound
        if var settings = outbound["settings"] as? [String: Any] {
            settings = pin(settings)
            for key in ["vnext", "servers"] {
                if let rows = settings[key] as? [[String: Any]] {
                    settings[key] = rows.map(pin)
                }
            }
            result["settings"] = settings
        }
        guard pinned else { return outbound }
        var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let security = (stream["security"] as? String) ?? ""
        let network = (stream["network"] as? String) ?? ""
        if security == "tls" || network == "hysteria" || (outbound["protocol"] as? String) == "hysteria" {
            var tls = stream["tlsSettings"] as? [String: Any] ?? [:]
            if ((tls["serverName"] as? String) ?? "").isEmpty {
                tls["serverName"] = server.host
            }
            stream["tlsSettings"] = tls
            result["streamSettings"] = stream
        }
        return result
    }

    /// Receive-window caps for QUIC (Hysteria2) outbounds, in bytes.
    /// Xray's defaults are desktop sized (8 MiB per stream, 20 MiB per
    /// connection) and the server sends at a fixed rate, so whenever the
    /// phone's packet path falls behind, up to 20 MiB of data waits in the
    /// Go heap: the drop logs show the footprint climbing from 29 to 50 MB
    /// in half a minute, all of it live. 4 MiB per connection still allows
    /// several hundred Mbit/s at mobile round-trip times.
    static let quicWindowCaps: [(key: String, bytes: Int)] = [
        ("initStreamReceiveWindow", 256 << 10),
        ("maxStreamReceiveWindow", 1 << 20),
        ("initConnectionReceiveWindow", 512 << 10),
        ("maxConnectionReceiveWindow", 4 << 20)
    ]

    /// Lowers the QUIC receive windows of a Hysteria2 outbound to the mobile
    /// caps, keeping every other finalmask/quicParams setting (congestion,
    /// bandwidth, port hopping) and any window that is already smaller.
    static let quicKeepAliveSeconds = 10

    static func capQuicReceiveWindows(_ outbound: [String: Any]) -> [String: Any] {
        var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let isQuic = (outbound["protocol"] as? String) == "hysteria" ||
            (stream["network"] as? String) == "hysteria"
        guard isQuic else { return outbound }
        var finalmask = stream["finalmask"] as? [String: Any] ?? [:]
        var params = finalmask["quicParams"] as? [String: Any] ?? [:]
        for cap in quicWindowCaps {
            let current = (params[cap.key] as? NSNumber)?.intValue ?? 0
            if current <= 0 || current > cap.bytes {
                params[cap.key] = cap.bytes
            }
        }
        // Xray sends no QUIC keepalive by default, so a session idle for its
        // 30 s timeout dies on the server (and in home NATs) while it still
        // looks alive here. A ping every 10 s keeps it up while the device
        // is awake, and after a short sleep the session is still there.
        if ((params["keepAlivePeriod"] as? NSNumber)?.intValue ?? 0) <= 0 {
            params["keepAlivePeriod"] = Self.quicKeepAliveSeconds
        }
        finalmask["quicParams"] = params
        stream["finalmask"] = finalmask
        var capped = outbound
        capped["streamSettings"] = stream
        return capped
    }

    /// A loopback port that is free for both TCP and UDP (Xray's SOCKS5
    /// inbound relays UDP on the same port).
    static func freeLoopbackPort(excluding excluded: UInt16 = 0) -> UInt16? {
        for _ in 0 ..< 8 {
            let tcp = socket(AF_INET, SOCK_STREAM, 0)
            guard tcp >= 0 else { return nil }
            defer { Darwin.close(tcp) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr(ProxyHost)
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(tcp, raw, length) == 0 && getsockname(tcp, raw, &length) == 0
                }
            }
            guard bound else { continue }
            let udp = socket(AF_INET, SOCK_DGRAM, 0)
            guard udp >= 0 else { return nil }
            defer { Darwin.close(udp) }
            let udpBound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(udp, raw, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            let port = CFSwapInt16BigToHost(address.sin_port)
            if udpBound, port != excluded { return port }
        }
        return nil
    }

    /// NetworkExtension exposes packets through NEPacketTunnelFlow. Feeding
    /// tun2socks through an app-owned socket pair avoids relying on a private
    /// utun descriptor and continues to work when iOS changes the provider's
    /// internal socket layout. It is a datagram pair: every datagram is one
    /// packet behind a four-byte big-endian address family, exactly what
    /// hev-socks5-tunnel reads from and writes to a Darwin utun descriptor.
    private func openPacketFlowBridge() throws -> (tunFD: Int32, swiftFD: Int32, generation: UInt64) {
        closePacketFlowBridge()
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            stabilityLog(
                "core_start_failed",
                reason: "packet_flow_bridge_socketpair_failed",
                error: String(cString: strerror(errno))
            )
            throw TunnelError.packetFlowBridgeFailed
        }
        for fd in descriptors {
            Self.configureBridgeSocket(fd)
        }

        packetBridgeLock.lock()
        packetBridgeGeneration &+= 1
        let generation = packetBridgeGeneration
        packetBridgeTunFD = descriptors[0]
        packetBridgeSwiftFD = descriptors[1]
        packetBridgeRunning = true
        packetBridgeLock.unlock()
        stabilityLog("packet_flow_bridge_started", reason: "socketpair")
        return (descriptors[0], descriptors[1], generation)
    }

    /// Unix datagram sockets start with a 2 KB send limit (the largest
    /// datagram) and a 4 KB receive queue: both far too small for packets
    /// and bursts. Half a megabyte is a few hundred packets, enough for a
    /// burst without holding much. SIGPIPE must never reach the process.
    private static func configureBridgeSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        for option in [SO_SNDBUF, SO_RCVBUF] {
            for size: Int32 in [512 << 10, 256 << 10, 128 << 10] {
                var value = size
                if setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 {
                    break
                }
            }
        }
    }

    private func closePacketFlowBridge() {
        packetBridgeLock.lock()
        let tunFD = packetBridgeTunFD
        let swiftFD = packetBridgeSwiftFD
        let wasRunning = packetBridgeRunning
        packetBridgeRunning = false
        packetBridgeGeneration &+= 1
        packetBridgeTunFD = -1
        packetBridgeSwiftFD = -1
        packetBridgeLock.unlock()

        if tunFD >= 0 {
            _ = Darwin.shutdown(tunFD, SHUT_RDWR)
            _ = Darwin.close(tunFD)
        }
        if swiftFD >= 0 {
            _ = Darwin.shutdown(swiftFD, SHUT_RDWR)
            _ = Darwin.close(swiftFD)
        }
        if wasRunning {
            stabilityLog("packet_flow_bridge_stopped", reason: "closed")
        }
    }

    private func packetBridgeIsRunning(_ generation: UInt64, fd: Int32) -> Bool {
        packetBridgeLock.lock()
        defer { packetBridgeLock.unlock() }
        return packetBridgeRunning &&
            packetBridgeGeneration == generation &&
            packetBridgeSwiftFD == fd
    }

    private func startPacketFlowBridge(swiftFD: Int32, generation: UInt64) {
        readPacketsFromTunnel(fd: swiftFD, generation: generation)
        packetBridgeLock.lock()
        let startReader = !systemPacketReaderStarted
        systemPacketReaderStarted = true
        packetBridgeLock.unlock()
        if startReader {
            forwardPacketsFromSystem()
        }
    }

    /// The bridge socket that packets from iOS go to, if a bridge is up.
    private func currentBridgeFD() -> Int32? {
        packetBridgeLock.lock()
        defer { packetBridgeLock.unlock() }
        return packetBridgeRunning && packetBridgeSwiftFD >= 0 ? packetBridgeSwiftFD : nil
    }

    /// Reads the packets tun2socks produces and hands them back to iOS. Each
    /// datagram is a four-byte big-endian address family and one IPv4 or
    /// IPv6 packet. Datagrams that are already queued are drained into one
    /// writePackets call: one call per burst instead of one per packet is
    /// what keeps download throughput up.
    private func readPacketsFromTunnel(fd: Int32, generation: UInt64) {
        let flow = packetFlow
        let traffic = self.traffic
        Thread.detachNewThread { [weak self] in
            let capacity = 4 + 65_535
            let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { bytes.deallocate() }
            let batchLimit = 32
            var packets: [Data] = []
            var families: [NSNumber] = []
            packets.reserveCapacity(batchLimit)
            families.reserveCapacity(batchLimit)

            while let self, self.packetBridgeIsRunning(generation, fd: fd) {
                let received = Darwin.recv(fd, bytes, capacity, 0)
                if received < 0 && errno == EINTR { continue }
                // 0 is the shutdown from closePacketFlowBridge.
                guard received > 0 else { break }
                guard received > 4 else { continue }
                let rawFamily = UnsafeRawPointer(bytes).loadUnaligned(as: UInt32.self)
                let family = CFSwapInt32BigToHost(rawFamily)
                guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { continue }
                let length = received - 4
                packets.append(Data(bytes: bytes + 4, count: length))
                families.append(NSNumber(value: family))
                traffic.addDown(length)
                if packets.count < batchLimit && Self.hasPendingInput(fd: fd) { continue }
                // writePackets is Objective-C: every call bridges the arrays
                // and their packets into autoreleased objects. This thread
                // never returns to a run loop, so without its own pool none
                // of them was ever released: the extension kept every
                // downloaded packet until iOS killed it (the malloc heap grew
                // with the bytes downloaded, several MB a second on Wi-Fi).
                autoreleasepool {
                    _ = flow.writePackets(packets, withProtocols: families)
                }
                packets.removeAll(keepingCapacity: true)
                families.removeAll(keepingCapacity: true)
            }
            autoreleasepool {
                if !packets.isEmpty {
                    _ = flow.writePackets(packets, withProtocols: families)
                }
                self?.stabilityLog("packet_flow_bridge_read_stopped", reason: "stream_closed")
            }
        }
    }

    /// True when another datagram is already waiting on the bridge socket.
    private static func hasPendingInput(fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) > 0 && (descriptor.revents & Int16(POLLIN)) != 0
    }

    /// Continuously reads packets from iOS and sends each one to tun2socks as
    /// its own datagram. A packet the kernel queue cannot take right now is
    /// dropped, like on a congested link; TCP retransmits it.
    ///
    /// NEPacketTunnelFlow serves one readPackets call at a time, so there is
    /// exactly one chain per provider and it is never ended by a core
    /// restart: each batch goes to whichever bridge is current. It used to be
    /// one chain per bridge that stopped when its bridge went away; after a
    /// restart the old chain's pending call could be the one iOS answered,
    /// it saw a stale bridge and returned without asking again, and no
    /// packet from any app reached the tunnel any more while it still showed
    /// connected (the report: 20 minutes at 0 bytes after a restart).
    private func forwardPacketsFromSystem() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            guard let fd = self.currentBridgeFD() else {
                // Between two bridges (a core restart): drop the batch.
                self.forwardPacketsFromSystem()
                return
            }
            var total = 0
            send: for (packet, proto) in zip(packets, protocols) {
                if Self.isQuicPacket(packet, family: proto.uint32Value) { continue }
                switch Self.sendPacket(fd: fd, packet: packet, family: proto.uint32Value) {
                case .sent:
                    total += packet.count
                case .dropped:
                    continue
                case .closed:
                    if self.currentBridgeFD() == fd {
                        self.stabilityLog("packet_flow_bridge_write_failed", reason: "stream_closed")
                    }
                    break send
                }
            }
            self.traffic.addUp(total)
            self.forwardPacketsFromSystem()
        }
    }

    /// UDP to port 443: QUIC (HTTP/3). It is not passed on. Every QUIC
    /// connection of an app is a UDP session in hev and several goroutines
    /// in the core, carried as unreliable datagrams inside Hysteria's own
    /// QUIC; apps that use it heavily (video, social feeds) are the likely
    /// source of the 2,000+ goroutines that took the extension to its
    /// memory limit even with 256 sessions (hev counts UDP flows too). Apps
    /// race QUIC against TCP and fall back to HTTP/2 over TCP when QUIC gets
    /// no answer; one TCP connection carries many requests, so the tunnel
    /// holds far fewer sessions and those are retransmitted by the transport.
    static func isQuicPacket(_ packet: Data, family: UInt32) -> Bool {
        packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            if family == UInt32(AF_INET) {
                guard bytes.count >= 20, bytes[0] >> 4 == 4, bytes[9] == 17 else { return false }
                // Only the first fragment carries the UDP header.
                let fragmentOffset = (Int(bytes[6] & 0x1F) << 8) | Int(bytes[7])
                guard fragmentOffset == 0 else { return false }
                let headerLength = Int(bytes[0] & 0x0F) * 4
                guard headerLength >= 20, bytes.count >= headerLength + 4 else { return false }
                return bytes[headerLength + 2] == 0x01 && bytes[headerLength + 3] == 0xBB
            }
            if family == UInt32(AF_INET6) {
                guard bytes.count >= 44, bytes[0] >> 4 == 6, bytes[6] == 17 else { return false }
                return bytes[42] == 0x01 && bytes[43] == 0xBB
            }
            return false
        }
    }

    private enum BridgeSendResult {
        case sent
        case dropped
        case closed
    }

    private static func sendPacket(fd: Int32, packet: Data, family: UInt32) -> BridgeSendResult {
        var header = CFSwapInt32HostToBig(family)
        return withUnsafeMutableBytes(of: &header) { (headerBuffer: UnsafeMutableRawBufferPointer) -> BridgeSendResult in
            packet.withUnsafeBytes { (packetBuffer: UnsafeRawBufferPointer) -> BridgeSendResult in
                var vectors = [
                    iovec(iov_base: headerBuffer.baseAddress, iov_len: headerBuffer.count),
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: packetBuffer.baseAddress), iov_len: packetBuffer.count)
                ]
                while true {
                    let sent = Darwin.writev(fd, &vectors, Int32(vectors.count))
                    if sent > 0 { return .sent }
                    switch errno {
                    case EINTR:
                        continue
                    case ENOBUFS, EAGAIN, EMSGSIZE:
                        return .dropped
                    default:
                        return .closed
                    }
                }
            }
        }
    }
}

private extension PacketTunnelProvider {
    // MARK: - Stability layer

    func prepareStability(coreBase64Text: String) {
        currentCoreBase64Text = coreBase64Text
        currentProfile = TunnelProfileInfo.fromCoreRequest(coreBase64Text)
        keepAliveFailCount = 0
        reconnectAttempt = 0
        reconnectStartedUptime = nil
        failedRestarts = 0
        serverProblem = false
        lastSuccessfulProbeAt = Date()
        traffic.reset()
        stabilityLog("connection_state_changed", reason: "profile_loaded")
    }

    func startStabilityLayer() {
        tunnelShouldRun = true
        startPathMonitor()
        startPowerMonitor()
        startKeepAliveLoop()
        startTrafficReporter()
    }

    func stopStabilityLayer() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        trafficReportTask?.cancel()
        trafficReportTask = nil
        writeTrafficSnapshot(coreAlive: false)
        reconnectLock.lock()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectTaskID = nil
        reconnectLock.unlock()
        pathRecoveryTask?.cancel()
        pathRecoveryTask = nil
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let powerObserver = powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
            self.powerObserver = nil
        }
    }

    /// Publishes the bridge byte counters once a second to the shared run
    /// directory so the app can show live upload/download speed.
    func startTrafficReporter() {
        trafficReportTask?.cancel()
        trafficReportTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let footprint = self.writeTrafficSnapshot(coreAlive: self.coreRunning)
                self.trafficTicks += 1
                let nearCap = footprint > Self.memoryTrimThreshold
                if self.trafficTicks % 5 == 1 || nearCap {
                    self.goSysBytes = UInt64(max(0, CGoGoSysBytes()))
                    self.memoryDetail = Self.memoryBreakdown(footprint: footprint)
                    Self.trimStandardErrorIfLarge()
                    Self.trimCoreErrorLogIfLarge()
                }
                self.applyMemoryValve(footprint: footprint)
                // Give freed Go memory back to iOS when the extension gets
                // close to its cap. A trim is a full GC: not more often than
                // every few seconds, and only logged when it freed something.
                if footprint > Self.memoryTrimThreshold,
                   self.trafficTicks - self.lastTrimTick >= Self.memoryTrimInterval {
                    self.lastTrimTick = self.trafficTicks
                    CGoFreeOSMemory()
                    let after = Self.memoryFootprint()
                    if footprint > after + (1 << 20) {
                        self.stabilityLog(
                            "memory_trimmed",
                            reason: "footprint_high",
                            metadata: ["beforeMB": Int(footprint >> 20), "afterMB": Int(after >> 20)]
                        )
                    }
                }
                // Record the footprint trend near the cap: the next drop
                // report then shows what grew before a kill.
                if nearCap, self.trafficTicks % 3 == 0 {
                    self.stabilityLog("memory_high", reason: "footprint", metadata: ["detail": self.memoryDetail])
                }
                // A compact sample every two minutes (traffic, memory,
                // goroutines) so a report shows how the session went, not
                // only its events.
                if self.trafficTicks % Self.sampleIntervalTicks == 0 {
                    let snapshot = self.traffic.snapshot()
                    self.stabilityLog("tunnel_sample", reason: "periodic", metadata: [
                        "upKB": Int((snapshot.up >= self.lastSampleUp ? snapshot.up - self.lastSampleUp : snapshot.up) >> 10),
                        "downKB": Int((snapshot.down >= self.lastSampleDown ? snapshot.down - self.lastSampleDown : snapshot.down) >> 10),
                        "detail": self.memoryDetail
                    ])
                    self.lastSampleUp = snapshot.up
                    self.lastSampleDown = snapshot.down
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Writes the byte counters, the heartbeat time and the memory footprint;
    /// returns the footprint. "core" stays true only while the tunnel runs, so
    /// a file left with core=true means the extension died without stopping.
    @discardableResult
    func writeTrafficSnapshot(coreAlive: Bool) -> UInt64 {
        let footprint = Self.memoryFootprint()
        if footprint > peakFootprint { peakFootprint = footprint }
        guard let runDir = extensionGroupContainerURL()?.adaptedAppendPath(path: "run") else { return footprint }
        let snapshot = traffic.snapshot()
        let payload: [String: Any] = [
            "up": snapshot.up,
            "down": snapshot.down,
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
            "core": coreAlive,
            "serverProblem": serverProblem,
            "mem": footprint,
            "peak": peakFootprint,
            "go": goSysBytes,
            "detail": memoryDetail
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return footprint }
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? data.write(to: runDir.adaptedAppendPath(path: "traffic.json"), options: .atomic)
        return footprint
    }

    // MARK: - Drop records

    /// Where the footprint is, in MB: the iOS ledgers (internal, compressed,
    /// network-tagged), the C/Swift malloc heap (hev, lwIP, Foundation) and
    /// the Go runtime (heap in use, idle, stacks). Their sum is not the
    /// footprint; the point is which part grows before a kill.
    static func memoryBreakdown(footprint: UInt64) -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var parts: [String] = ["fp \(footprint >> 20)"]
        if result == KERN_SUCCESS {
            parts.append("int \(UInt64(info.internal) >> 20)")
            parts.append("cmp \(UInt64(info.compressed) >> 20)")
            parts.append("purg \(UInt64(info.purgeable_volatile_resident) >> 20)")
            let networkOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_tag_network_nonvolatile) ?? Int.max
            if Int(count) * MemoryLayout<natural_t>.size > networkOffset {
                parts.append("net \(UInt64(max(0, info.ledger_tag_network_nonvolatile)) >> 20)")
            }
        }
        var mallocStats = malloc_statistics_t()
        malloc_zone_statistics(nil, &mallocStats)
        parts.append("malloc \(UInt64(mallocStats.size_in_use) >> 20)/\(UInt64(mallocStats.size_allocated) >> 20)")
        let go = goMemStats()
        parts.append("go heap \(go[0] >> 20)/\(go[1] >> 20) idle \(go[2] >> 20) rel \(go[3] >> 20) stack \(go[4] >> 20) sys \(go[5] >> 20) gc \(go[6]) gr \(go[7])")
        return parts.joined(separator: ", ")
    }

    /// Go runtime numbers from CGoGoMemStats: heap alloc, heap in use, heap
    /// idle, heap released, stack in use, sys, GC count, goroutines.
    static func goMemStats() -> [Int64] {
        var go = [Int64](repeating: 0, count: 8)
        go.withUnsafeMutableBufferPointer { CGoGoMemStats($0.baseAddress) }
        return go
    }

    /// Live goroutines in the core, a stand-in for its open connections
    /// (each proxied connection holds a few).
    static func goroutineCount() -> Int {
        Int(goMemStats()[7])
    }

    /// A probe slower than this is logged even when it is routine.
    static let slowProbeMilliseconds = 800

    /// Last resort under iOS's cap (about 45 MB on iOS 26): restart the core,
    /// which costs a second of connectivity instead of the whole tunnel.
    func applyMemoryValve(footprint: UInt64) {
        if footprint > Self.memoryRestartThreshold, coreRunning, !restartingCore,
           trafficTicks - lastMemoryRestartTick >= 45 {
            lastMemoryRestartTick = trafficTicks
            stabilityLog("memory_restart", reason: "footprint_at_cap", metadata: ["mb": Int(footprint >> 20), "detail": memoryDetail])
            restartCoreForNewSituation(reason: .memoryPressure)
        }
    }

    /// The extension's physical memory footprint, the number iOS checks
    /// against the extension's limit.
    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func stopReasonName(_ reason: NEProviderStopReason) -> String {
        switch reason.rawValue {
        case 0: return "none"
        case 1: return "userInitiated"
        case 2: return "providerFailed"
        case 3: return "noNetworkAvailable"
        case 4: return "unrecoverableNetworkChange"
        case 5: return "providerDisabled"
        case 6: return "authenticationCanceled"
        case 7: return "configurationFailed"
        case 8: return "idleTimeout"
        case 9: return "configurationDisabled"
        case 10: return "configurationRemoved"
        case 11: return "superceded"
        case 12: return "userLogout"
        case 13: return "userSwitch"
        case 14: return "connectionFailed"
        case 15: return "sleep"
        case 16: return "appUpdate"
        case 17: return "internalError"
        default: return "reason\(reason.rawValue)"
        }
    }

    /// If the last heartbeat still says the tunnel was running, the previous
    /// extension was killed by iOS (usually for memory) without stopTunnel.
    func recordPreviousExitIfUnclean(onDemand: Bool) {
        guard let runDir = extensionGroupContainerURL()?.adaptedAppendPath(path: "run") else { return }
        let url = runDir.adaptedAppendPath(path: "traffic.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["core"] as? Bool) == true else { return }
        var record: [String: Any] = [
            "ts": (json["ts"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),
            "kind": "killed",
            "mem": (json["mem"] as? NSNumber)?.uint64Value ?? 0,
            "peak": (json["peak"] as? NSNumber)?.uint64Value ?? 0,
            "go": (json["go"] as? NSNumber)?.uint64Value ?? 0,
            "restartedBy": onDemand ? "ios" : "app",
            "memDetail": (json["detail"] as? String) ?? ""
        ]
        // A Go panic or a Swift trap writes its reason to stderr before the
        // process dies; an iOS (jetsam) kill leaves nothing.
        if let crash = Self.crashLine(in: runDir.adaptedAppendPath(path: Self.stderrLogName)) {
            record["kind"] = "crashed"
            record["detail"] = crash
        }
        appendDrop(record)
        // Mark it handled so the next start does not report it again.
        var cleared = json
        cleared["core"] = false
        if let out = try? JSONSerialization.data(withJSONObject: cleared) {
            try? out.write(to: url, options: .atomic)
        }
    }

    static let stderrLogName = "tunnel-stderr.log"
    static let previousStderrLogName = "tunnel-stderr.prev.log"
    static let stderrLogLimit: off_t = 512 << 10

    /// The extension has no console. Go panics, Swift runtime traps and
    /// tun2socks warnings all go to stderr, so stderr goes to a file in the
    /// run directory, started fresh for every run.
    func redirectStandardError() {
        guard let runDir = extensionGroupContainerURL()?.adaptedAppendPath(path: "run") else { return }
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let url = runDir.adaptedAppendPath(path: Self.stderrLogName)
        let previous = runDir.adaptedAppendPath(path: Self.previousStderrLogName)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        let path = url.adaptedPath()
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        if fd != STDERR_FILENO {
            dup2(fd, STDERR_FILENO)
            Darwin.close(fd)
        }
    }

    /// Keeps the stderr log bounded; writes are appends, so they continue at
    /// the new end after the truncation.
    static func trimStandardErrorIfLarge() {
        var info = stat()
        if fstat(STDERR_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > stderrLogLimit {
            _ = ftruncate(STDERR_FILENO, 0)
        }
    }

    /// Xray appends to its error log; cut it back when it gets large.
    static func trimCoreErrorLogIfLarge() {
        guard let runDir = extensionGroupContainerURL()?.adaptedAppendPath(path: "run") else { return }
        let path = runDir.adaptedAppendPath(path: coreErrorLogName).adaptedPath()
        var info = stat()
        if stat(path, &info) == 0, info.st_size > stderrLogLimit {
            _ = truncate(path, 0)
        }
    }

    /// The first line of a crash report in a stderr log, if there is one.
    static func crashLine(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The report is at the end: read at most the last 128 KB.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let markers = [
            "fatal error: ", "panic: ", "Fatal error: ", "runtime: out of memory",
            "SIGSEGV", "SIGBUS", "SIGABRT", "Assertion failed"
        ]
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        for marker in markers {
            if let line = lines.first(where: { $0.contains(marker) }) {
                return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
            }
        }
        return nil
    }

    /// Appends one drop record to run/drops.jsonl, keeping the last 20.
    func appendDrop(_ record: [String: Any]) {
        guard let runDir = extensionGroupContainerURL()?.adaptedAppendPath(path: "run"),
              JSONSerialization.isValidJSONObject(record),
              let line = try? JSONSerialization.data(withJSONObject: record),
              let text = String(data: line, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let url = runDir.adaptedAppendPath(path: "drops.jsonl")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
        lines.append(text)
        let kept = lines.suffix(20).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    func startPathMonitor() {
        pathMonitor?.cancel()
        // The tunnel's own utun interface is of type "other": leave it out,
        // or every restart of the tunnel would look like a network change.
        let monitor: Network.NWPathMonitor
        if #available(iOS 14.0, macOS 11.0, *) {
            monitor = Network.NWPathMonitor(prohibitedInterfaceTypes: [.other])
        } else {
            monitor = Network.NWPathMonitor()
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
    }

    func handlePathUpdate(_ path: Network.NWPath) {
        let next = TunnelPathInfo(path: path)
        let previous = currentPath
        currentPath = next
        stabilityLog("network_path_changed", reason: next.status)

        if next.status != "satisfied" {
            pathRecoveryTask?.cancel()
            reasserting = false
            setStabilityState(.networkUnavailable, reason: "No Internet Connection")
            return
        }

        if state == .networkUnavailable {
            lastPathChangeAt = Date()
            setStabilityState(.connected, reason: "Connection Restored")
            reconnectAttempt = 0
            schedulePathRecovery(reason: .networkRestored, graceSeconds: 1.5, restartCore: false)
            return
        }

        if !previous.signature.isEmpty && previous.signature != next.signature {
            lastPathChangeAt = Date()
            stabilityLog("interface_changed", reason: "path_changed")
            // Moving between Wi-Fi and cellular strands the core's transport
            // (a QUIC session or TCP connection on the old interface): start
            // it again right away instead of waiting for it to time out.
            let interfaceSwitched = previous.interfaceType != "unknown" &&
                previous.interfaceType != next.interfaceType
            schedulePathRecovery(reason: .pathChanged, graceSeconds: 2.0, restartCore: interfaceSwitched)
        }
    }

    func schedulePathRecovery(reason: StabilityReconnectReason, graceSeconds: Double, restartCore: Bool) {
        pathRecoveryTask?.cancel()
        pathRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.tunnelShouldRun else { return }
            if restartCore, self.currentPath.status == "satisfied",
               self.currentPath.interfaceType != self.coreInterfaceType {
                self.stabilityLog("reconnect_scheduled", reason: "interface_switched")
                self.restartCoreForNewSituation(reason: reason)
                return
            }
            let result = await self.confirmTunnelHealth(reason: reason.rawValue)
            if result == .success {
                self.handleSuccessfulProbe()
            } else if result == .failed {
                self.restartCoreForNewSituation(reason: reason)
            }
        }
    }

    func startPowerMonitor() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.stabilityLog("low_power_mode_changed", reason: self.lowPowerMode ? "enabled" : "disabled")
        }
    }

    /// Watches the tunnel without spending traffic when nothing happens.
    /// While apps send through the tunnel, the path is probed end to end at
    /// most every `activeProbeInterval`; while it is idle, every
    /// `idleProbeInterval`. A failed probe (confirmed once) restarts the core
    /// at once: the probe goes through the real outbound, so a failure means
    /// the tunnel is really stuck, for UDP (Hysteria2) transports as well.
    func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            var lastUp = self.traffic.snapshot().up
            while !Task.isCancelled && self.tunnelShouldRun {
                let settings = self.keepAliveSettings()
                if self.state != .networkUnavailable, self.reconnectTask == nil, !self.restartingCore {
                    if !self.coreAppearsAlive() {
                        self.keepAliveFailCount += 1
                        self.setStabilityState(.failed, reason: "core_not_running")
                        self.stabilityLog(
                            "core_crashed",
                            reason: "core_not_running",
                            metadata: self.stabilityMetadata(
                                healthCheckResult: HealthCheckResult.failed.rawValue
                            )
                        )
                        self.scheduleReconnect(reason: .coreProcessFailed, healthCheckFirst: false)
                    } else {
                        let up = self.traffic.snapshot().up
                        let active = up != lastUp
                        lastUp = up
                        let sinceProbe = self.lastSuccessfulProbeAt.map { Date().timeIntervalSince($0) } ?? .infinity
                        let due = sinceProbe >= (active ? settings.activeProbeInterval : settings.idleProbeInterval)
                        // Right after a wake the handler resets the QUIC
                        // session and probes itself; a probe from here would
                        // meet the pre-sleep session and fail for nothing.
                        let justWoke = self.lastWakeAt.map { Date().timeIntervalSince($0) < Self.wakeProbeGraceSeconds } ?? false
                        if due, !justWoke {
                            let reason = active ? "keepalive_active" : "keepalive_idle"
                            let result = await self.confirmTunnelHealth(reason: reason)
                            let aroundWake = self.lastWakeAt.map { Date().timeIntervalSince($0) < 15 } ?? false
                            if self.reconnectTask != nil || self.restartingCore {
                                // A restart began meanwhile; its own
                                // validation decides.
                            } else if result == .failed, aroundWake {
                                // The timer fired as the device woke and the
                                // probe met the pre-sleep session; the wake
                                // handler resets it and probes itself.
                            } else if result == .success {
                                self.handleSuccessfulProbe()
                            } else if result == .failed, self.tunnelShouldRun {
                                self.keepAliveFailCount += 1
                                self.setStabilityState(.unhealthy, reason: "proxied_probe_failed")
                                self.scheduleReconnect(reason: .keepaliveFailed, healthCheckFirst: false)
                            }
                            lastUp = self.traffic.snapshot().up
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(settings.interval * 1_000_000_000))
            }
        }
    }

    func keepAliveSettings() -> KeepAliveSettings {
        if lowPowerMode {
            return KeepAliveSettings(interval: 30, activeProbeInterval: 90, idleProbeInterval: 900)
        }
        return KeepAliveSettings(interval: 10, activeProbeInterval: 30, idleProbeInterval: 300)
    }

    /// After the device sleeps, the core's session to the server is often
    /// gone (the server or a NAT timed it out) while it still looks alive
    /// locally, which leaves the tunnel "connected" but dead or crawling
    /// until the transport times out. The process is frozen while the device
    /// sleeps, so after a long sleep no keepalive has reached the server for
    /// longer than its idle timeout: restart the core at once. After a short
    /// one, probe as soon as the radio is back and restart only on failure.
    func handleProviderWake(sleptSeconds: Int) {
        // While the device sleeps Go's monotonic clock stops: quic-go's
        // idle timer does not advance while the server's (wall clock) does,
        // so after a sleep longer than a few seconds the cached QUIC session
        // is usually gone on the server yet looks alive here, and every new
        // stream would wait on it for ~30 s. Drop it now; the next request
        // opens a fresh session (one round trip).
        if sleptSeconds >= Self.quicResetAfterSleepSeconds, coreRunning, !restartingCore {
            CGoResetHysteria()
            stabilityLog("quic_reset", reason: "after_sleep", metadata: ["sleptSec": sleptSeconds])
        }
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            // Let the radio come back before judging the path.
            try? await Task.sleep(nanoseconds: UInt64(PacketTunnelProvider.wakeSettleSeconds * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.tunnelShouldRun, !self.userInitiatedStop,
                  self.reconnectTask == nil else { return }
            if let last = self.lastSuccessfulProbeAt, Date().timeIntervalSince(last) < 5 {
                self.stabilityLog("health_check_skipped", reason: "probe_just_succeeded_after_wake")
                return
            }
            let result = await self.confirmTunnelHealth(reason: StabilityReconnectReason.appWakeupHealthFailed.rawValue)
            guard !Task.isCancelled, self.tunnelShouldRun, !self.userInitiatedStop else { return }
            if result == .success {
                self.handleSuccessfulProbe()
            } else if result == .failed {
                self.restartCoreForNewSituation(reason: .appWakeupHealthFailed)
            }
        }
    }

    /// Seconds to wait after a wake before probing.
    static let wakeSettleSeconds: Double = 1.5
    /// A sleep at least this long drops the cached QUIC session. The
    /// server's idle timeout is 30 s and the last keepalive went out at most
    /// 10 s before the sleep, so a shorter sleep leaves the session alive:
    /// resetting it then only cut every open connection on each unlock.
    static let quicResetAfterSleepSeconds = 20
    /// The keepalive leaves probing to the wake handler for this long after
    /// a wake.
    static let wakeProbeGraceSeconds: TimeInterval = 3

    /// Seconds the device has been awake since boot. Unlike `Date()` it
    /// stops while the device sleeps, so a deadline measured with it is not
    /// used up by a sleep in the middle of a restart.
    static var awakeClock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A wake-up or a network change is a new situation: the backoff of
    /// earlier failed attempts must not delay this restart.
    func restartCoreForNewSituation(reason: StabilityReconnectReason) {
        guard reconnectTask == nil else { return }
        reconnectAttempt = 0
        reconnectStartedUptime = nil
        scheduleReconnect(reason: reason, healthCheckFirst: false)
    }

    func handleSuccessfulProbe() {
        keepAliveFailCount = 0
        reconnectAttempt = 0
        reconnectStartedUptime = nil
        reasserting = false
        lastSuccessfulProbeAt = Date()
        setStabilityState(.connected, reason: "keepalive_success")
        noteTunnelHealthy(reason: "keepalive_success")
    }

    /// Restarts in a row that may fail validation before the server is
    /// reported as the problem.
    static let serverProblemRestarts = 2

    /// A restarted core still cannot reach the internet. Restarting again
    /// changes nothing when the server or its network is at fault, so after
    /// `serverProblemRestarts` the heartbeat tells the app to offer another
    /// server; the retries themselves go on in case the server recovers.
    func noteRestartFailed() {
        failedRestarts += 1
        guard failedRestarts >= Self.serverProblemRestarts, !serverProblem else { return }
        serverProblem = true
        stabilityLog("server_problem", reason: "restarts_did_not_help", metadata: ["failedRestarts": failedRestarts])
    }

    func noteTunnelHealthy(reason: String) {
        failedRestarts = 0
        guard serverProblem else { return }
        serverProblem = false
        stabilityLog("server_problem_cleared", reason: reason)
    }

    func coreAppearsAlive() -> Bool {
        // Both halves carry the traffic: Xray and tun2socks in front of it.
        let running = CGoGetXrayState() != 0 && tun2socks.isRunning
        coreRunning = running
        return running && currentCoreBase64Text != nil && !restartingCore
    }

    func stabilityMetadata(healthCheckResult: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = [
            "keepAliveFailCount": keepAliveFailCount,
            "networkType": currentPath.interfaceType,
            "pathStatus": currentPath.status,
            "coreAlive": coreAppearsAlive()
        ]
        if let healthCheckResult = healthCheckResult {
            metadata["healthCheckResult"] = healthCheckResult
        }
        if let lastSuccess = lastSuccessfulProbeAt {
            metadata["lastSuccessfulProbeAgoSec"] = max(0, Int(Date().timeIntervalSince(lastSuccess)))
        }
        return metadata
    }

    /// Probes twice before calling the tunnel broken: once quickly, then once
    /// more against a second host with more time, so a single lost packet or
    /// a slow radio wake-up does not restart a healthy core.
    func confirmTunnelHealth(reason: String) async -> HealthCheckResult {
        let downBefore = traffic.snapshot().down
        let first = await runHealthCheck(reason: reason, target: .primary, timeout: 3)
        guard first == .failed, tunnelShouldRun else { return first }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard tunnelShouldRun, !Task.isCancelled else { return .skipped }
        let second = await runHealthCheck(reason: reason, target: .secondary, timeout: 6)
        // Apps kept receiving data meanwhile: the probe is what is failing
        // (a blocked probe host, say), not the tunnel.
        let received = traffic.snapshot().down &- downBefore
        if second == .failed, received >= 64 << 10 {
            stabilityLog("health_check_skipped", reason: "probe_failed_traffic_flowing", metadata: ["receivedKB": Int(received >> 10)])
            return .skipped
        }
        return second
    }

    func runHealthCheck(
        reason: String,
        target: TunnelProbe.Target = .primary,
        timeout: TimeInterval = 5
    ) async -> HealthCheckResult {
        // The periodic keepalive runs every 30 s; logging each one filled the
        // log in an hour and pushed out the events that matter. Those checks
        // are logged only when they fail or are slow.
        let routine = reason == "keepalive_active" || reason == "keepalive_idle"
        if !routine {
            stabilityLog(
                "health_check_started",
                reason: reason,
                metadata: stabilityMetadata(healthCheckResult: HealthCheckResult.started.rawValue)
            )
        }
        guard tunnelShouldRun else { return .failed }
        guard currentPath.status != "unsatisfied" else {
            stabilityLog(
                "health_check_failed",
                reason: "network_unavailable",
                metadata: stabilityMetadata(healthCheckResult: HealthCheckResult.failed.rawValue)
            )
            return .failed
        }
        guard coreAppearsAlive() else {
            stabilityLog(
                "health_check_failed",
                reason: "core_not_running",
                metadata: stabilityMetadata(healthCheckResult: HealthCheckResult.failed.rawValue)
            )
            return .failed
        }
        let port = probeSocksPort
        let user = socksUser
        let pass = socksPass
        guard port != 0 else { return .skipped }

        let startedAt = Date()
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: TunnelProbe.run(socksPort: port, username: user, password: pass, target: target, timeout: timeout))
            }
        }
        var metadata = stabilityMetadata(
            healthCheckResult: success ? HealthCheckResult.success.rawValue : HealthCheckResult.failed.rawValue
        )
        let probeMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        metadata["probeMs"] = probeMs
        if !success || !routine || probeMs >= Self.slowProbeMilliseconds {
            metadata["goroutines"] = Self.goroutineCount()
            stabilityLog(success ? "health_check_success" : "health_check_failed", reason: reason, metadata: metadata)
        }
        return success ? .success : .failed
    }

    /// When the tunnel fails, try a plain TCP connection to the server
    /// outside the tunnel (its address is excluded from the tunnel route).
    /// "ok" with a failing tunnel points at the proxy protocol being blocked
    /// or rejected; "timeout" or "refused" at the network not reaching the
    /// server at all (an operator block, a whitelist-only mobile network).
    /// At most once every two minutes; Hysteria2 runs over UDP and is not
    /// checked this way.
    func checkServerReachability() {
        let now = Date()
        if let last = lastReachabilityCheckAt, now.timeIntervalSince(last) < 120 { return }
        guard let port = currentProfile.port,
              !(currentProfile.proto ?? "").hasPrefix("hysteria") else { return }
        guard let address = pinnedServer?.ipv4 ?? currentProfile.host.flatMap({ isIPv4Address($0) ? $0 : nil }) else {
            stabilityLog("server_reach", reason: "no_ipv4_address")
            return
        }
        lastReachabilityCheckAt = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let startedAt = Date()
            let result = TunnelProbe.tcpConnect(ipv4: address, port: port, timeout: 4)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            self?.stabilityLog("server_reach", reason: result, metadata: ["ms": ms])
        }
    }

    func scheduleReconnect(reason: StabilityReconnectReason, healthCheckFirst: Bool) {
        guard tunnelShouldRun, !userInitiatedStop else { return }
        reconnectLock.lock()
        defer { reconnectLock.unlock() }
        checkServerReachability()
        guard state != .networkUnavailable else {
            stabilityLog("reconnect_scheduled", reason: "paused_network_unavailable")
            return
        }
        guard reconnectTask == nil else {
            stabilityLog("reconnect_scheduled", reason: "already_running")
            return
        }
        if reason != .coreProcessFailed {
            let now = Date()
            automaticRestarts.removeAll { now.timeIntervalSince($0) > Self.restartBudgetWindow }
            guard automaticRestarts.count < Self.restartBudget else {
                // Restarting again would only churn: keep the running core,
                // stop showing "reconnecting" and let the keepalive retry
                // once the window has passed.
                reasserting = false
                stabilityLog(
                    "reconnect_suppressed",
                    reason: reason.rawValue,
                    metadata: ["restartsInWindow": automaticRestarts.count]
                )
                return
            }
            automaticRestarts.append(now)
        }

        let delay = reconnectDelay()
        stabilityLog(
            "reconnect_scheduled",
            reason: reason.rawValue,
            metadata: stabilityMetadata(
                healthCheckResult: reason == .appWakeupHealthFailed ? HealthCheckResult.failed.rawValue : nil
            )
        )
        let taskID = UUID()
        reconnectTaskID = taskID
        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.reconnectLock.lock()
                // Only this task's own slot: a newer task may own it already.
                if self.reconnectTaskID == taskID {
                    self.reconnectTask = nil
                    self.reconnectTaskID = nil
                }
                self.reconnectLock.unlock()
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if healthCheckFirst {
                let result = await self.confirmTunnelHealth(reason: reason.rawValue)
                if result == .success {
                    self.reconnectAttempt = 0
                    self.reasserting = false
                    self.setStabilityState(.connected, reason: "health_recovered")
                    return
                } else if result == .skipped {
                    return
                }
            }
            // One task owns the whole episode: a failed attempt is retried
            // here with backoff instead of scheduling a second task (which
            // the "already running" guard used to refuse, leaving the tunnel
            // unhealthy until the next keepalive).
            while !Task.isCancelled {
                let outcome = await self.performReconnect(reason: reason)
                guard outcome == .failed, self.shouldKeepTrying(), self.tunnelShouldRun, !self.userInitiatedStop else { return }
                let retryDelay = self.reconnectDelay()
                self.stabilityLog("reconnect_retry", reason: reason.rawValue, metadata: ["delaySec": Int(retryDelay)])
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
    }

    /// At most this many automatic restarts per window.
    static let restartBudget = 4
    static let restartBudgetWindow: TimeInterval = 300

    func reconnectDelay() -> Double {
        let steps: [Double] = [1, 2, 5, 10, 20, 30]
        let base = steps[min(reconnectAttempt, steps.count - 1)]
        let jitter = Double(Int.random(in: 0 ... 500)) / 1000.0
        return min(30, base + jitter)
    }

    enum ReconnectOutcome {
        case success
        case failed
        case aborted
    }

    @discardableResult
    func performReconnect(reason: StabilityReconnectReason) async -> ReconnectOutcome {
        guard tunnelShouldRun, !userInitiatedStop else { return .aborted }
        guard currentPath.status != "unsatisfied" else {
            setStabilityState(.networkUnavailable, reason: "No Internet Connection")
            return .aborted
        }
        guard let core = currentCoreBase64Text else {
            setStabilityState(.failed, reason: "missing_core_config")
            stabilityLog("reconnect_failed", reason: reason.rawValue, error: "missing_core_config")
            return .aborted
        }

        reconnectAttempt += 1
        if reconnectStartedUptime == nil { reconnectStartedUptime = Self.awakeClock }
        setStabilityState(.reconnecting, reason: reason.rawValue)
        reasserting = true
        stabilityLog("reconnect_started", reason: reason.rawValue)
        restartingCore = true
        stopXray()
        try? await Task.sleep(nanoseconds: 350_000_000)
        // The user may have pressed Disconnect (or the tunnel was stopped)
        // during the pause: never start the core again after that.
        guard !Task.isCancelled, tunnelShouldRun, !userInitiatedStop else {
            restartingCore = false
            return .aborted
        }
        do {
            try startXray(core)
            // The core is up again: validation must see it as running.
            restartingCore = false
        } catch {
            restartingCore = false
            setStabilityState(.failed, reason: "Connection Failed")
            reasserting = shouldKeepTrying()
            stabilityLog("reconnect_failed", reason: reason.rawValue, error: error.localizedDescription)
            return .failed
        }

        // A fresh core needs a DNS answer and a QUIC/TLS handshake before
        // the first request goes through, and right after a wake the first
        // handshake often hangs until quic-go gives up on it (about 5 s).
        // Probe for up to 20 s before calling the restart failed.
        let validationDeadline = Self.awakeClock + Self.reconnectValidationSeconds
        var attempt = 0
        while tunnelShouldRun, !userInitiatedStop, !Task.isCancelled {
            attempt += 1
            let target: TunnelProbe.Target = attempt % 2 == 1 ? .primary : .secondary
            let result = await runHealthCheck(reason: "reconnect_validation", target: target, timeout: 4)
            if result == .success {
                keepAliveFailCount = 0
                reconnectAttempt = 0
                reconnectStartedUptime = nil
                lastSuccessfulProbeAt = Date()
                reasserting = false
                setStabilityState(.connected, reason: "reconnect_success")
                noteTunnelHealthy(reason: "reconnect_success")
                stabilityLog("reconnect_success", reason: reason.rawValue, metadata: ["validationAttempts": attempt])
                return .success
            }
            if result == .skipped {
                reasserting = false
                setStabilityState(.connected, reason: "reconnect_validation_skipped")
                noteTunnelHealthy(reason: "reconnect_validation_skipped")
                return .success
            }
            guard Self.awakeClock < validationDeadline else { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        guard tunnelShouldRun, !userInitiatedStop, !Task.isCancelled else { return .aborted }
        let transient = shouldTreatValidationFailureAsTransient(reason: reason)
        setStabilityState(transient ? .unhealthy : .failed, reason: "reconnect_validation_failed")
        reasserting = shouldKeepTrying()
        stabilityLog("reconnect_failed", reason: reason.rawValue, error: "health_check_failed", metadata: ["validationAttempts": attempt])
        noteRestartFailed()
        return .failed
    }

    /// How long a restarted core gets to answer its first probe.
    static let reconnectValidationSeconds: TimeInterval = 20

    func shouldKeepTrying() -> Bool {
        guard let started = reconnectStartedUptime else { return true }
        return Self.awakeClock - started < 300
    }

    func shouldTreatValidationFailureAsTransient(reason: StabilityReconnectReason) -> Bool {
        if lowPowerMode { return true }
        if reason == .pathChanged || reason == .networkRestored || reason == .appWakeupHealthFailed {
            return true
        }
        guard let changedAt = lastPathChangeAt else { return false }
        return Date().timeIntervalSince(changedAt) < 30
    }

    func setStabilityState(_ next: TunnelStabilityState, reason: String) {
        guard state != next else { return }
        state = next
        stabilityLog("connection_state_changed", reason: reason)
    }

    func stabilityLog(
        _ event: String,
        reason: String,
        error: String? = nil,
        metadata: [String: Any] = [:]
    ) {
        let log = StabilityLogEntry(
            event: event,
            state: state.rawValue,
            reason: reason,
            path: currentPath,
            profile: currentProfile,
            attempt: reconnectAttempt,
            error: error,
            metadata: metadata
        )
        #if DEBUG
        YGLog(log.description)
        #endif
        // Release builds must not write diagnostics to the shared unified log
        // (readable by a paired Mac / other processes). The sandboxed app-group
        // JSONL file below is the only release sink.
        appendStabilityLog(log)
    }

    /// Serialises writes to stability_log.jsonl. Events come from the packet
    /// bridge threads, the path monitor and the keepalive at the same time;
    /// two unsynchronised "seek to end, write" pairs land at the same offset
    /// and the second line overwrites the first, leaving a torn line.
    private static let stabilityLogLock = NSLock()

    func appendStabilityLog(_ log: StabilityLogEntry) {
        guard let runDir = extensionGroupContainerURL()?.adaptedAppendPath(path: "run"),
              let line = log.jsonLine() else { return }
        Self.stabilityLogLock.lock()
        defer { Self.stabilityLogLock.unlock() }
        let url = runDir.adaptedAppendPath(path: "stability_log.jsonl")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.adaptedPath()),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 262_144 {
            // Keep the newer half (from a line start) instead of deleting
            // the file: a drop right after the rollover would otherwise
            // arrive with no history at all.
            if let data = try? Data(contentsOf: url) {
                let tail = data.suffix(131_072)
                let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
                try? Data(tail[start...]).write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.adaptedPath()),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Byte counters for the packet bridge, updated from the read and write
/// threads and sampled by the traffic reporter.
private final class TrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var up: UInt64 = 0
    private var down: UInt64 = 0

    func addUp(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        up &+= UInt64(count)
        lock.unlock()
    }

    func addDown(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        down &+= UInt64(count)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        up = 0
        down = 0
        lock.unlock()
    }

    func snapshot() -> (up: UInt64, down: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (up, down)
    }
}

/// An end-to-end check of the tunnel: one HTTP request through the core's
/// probe inbound, which routing always sends through the proxy outbound.
/// SOCKS5 carries the host name, so the check does not depend on DNS either.
/// Any HTTP status line proves the whole path (core → server → internet).
enum TunnelProbe {
    enum Target {
        case primary
        case secondary

        var host: String {
            switch self {
            case .primary: return "cp.cloudflare.com"
            case .secondary: return "www.gstatic.com"
            }
        }
    }

    /// Plain TCP connect with a timeout: "ok", "timeout", "refused",
    /// "unreachable" or "error_<errno>". Blocking; call it off the Swift
    /// concurrency pool.
    static func tcpConnect(ipv4: String, port: UInt16, timeout: TimeInterval) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "error_socket" }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(ipv4)
        address.sin_port = CFSwapInt16HostToBig(port)
        func describe(_ code: Int32) -> String {
            switch code {
            case 0: return "ok"
            case ECONNREFUSED: return "refused"
            case ETIMEDOUT: return "timeout"
            case ENETUNREACH, EHOSTUNREACH: return "unreachable"
            default: return "error_\(code)"
            }
        }
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return "ok" }
        guard errno == EINPROGRESS else { return describe(errno) }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, Int32(timeout * 1000))
        guard ready > 0 else { return ready == 0 ? "timeout" : "error_poll" }
        var code: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else { return "error_getsockopt" }
        return describe(code)
    }

    /// Blocking; call it off the Swift concurrency pool.
    static func run(socksPort: UInt16, username: String, password: String, target: Target, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let deadline = Date().addingTimeInterval(timeout)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(ProxyHost)
        address.sin_port = CFSwapInt16HostToBig(socksPort)
        guard setTimeout(fd, until: deadline) else { return false }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return false }

        // Greeting: version 5, one method, username/password (RFC 1929).
        let user = Array(username.utf8)
        let pass = Array(password.utf8)
        guard user.count < 256, pass.count < 256,
              send(fd, [5, 1, 2]), let method = receive(fd, count: 2, until: deadline),
              method == [5, 2] else { return false }
        guard send(fd, [1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass),
              let auth = receive(fd, count: 2, until: deadline),
              auth[1] == 0 else { return false }

        // CONNECT host:80 by name.
        let host = Array(target.host.utf8)
        guard send(fd, [5, 1, 0, 3, UInt8(host.count)] + host + [0, 80]),
              let reply = receive(fd, count: 4, until: deadline),
              reply[0] == 5, reply[1] == 0 else { return false }
        let boundLength: Int
        switch reply[3] {
        case 1: boundLength = 4 + 2
        case 4: boundLength = 16 + 2
        case 3:
            guard let length = receive(fd, count: 1, until: deadline) else { return false }
            boundLength = Int(length[0]) + 2
        default: return false
        }
        guard receive(fd, count: boundLength, until: deadline) != nil else { return false }

        let request = "GET /generate_204 HTTP/1.1\r\nHost: \(target.host)\r\nUser-Agent: Colitu\r\nConnection: close\r\n\r\n"
        guard send(fd, Array(request.utf8)),
              let status = receive(fd, count: 7, until: deadline) else { return false }
        return status == Array("HTTP/1.".utf8)
    }

    private static func setTimeout(_ fd: Int32, until deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var value = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size) == 0
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(fd, base + offset, buffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func receive(_ fd: Int32, count: Int, until deadline: Date) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard setTimeout(fd, until: deadline) else { return nil }
            let received = bytes.withUnsafeMutableBytes { buffer -> Int in
                Darwin.recv(fd, buffer.baseAddress! + offset, count - offset, 0)
            }
            if received > 0 {
                offset += received
            } else if received < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return bytes
    }
}

struct PinnedServer {
    let host: String
    let ipv4: String
}

private enum Tun2SocksConfigError: Error {
    case invalidRequest
    case invalidConfig
    case noTunInbound
}

/// Runs hev-socks5-tunnel on its own thread. hev is a process-wide
/// singleton: at most one instance may run, and a new one may only start
/// after the previous hev_socks5_tunnel_main_from_str call has returned.
private final class Tun2Socks: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var stopRequested = false
    private var exited: DispatchSemaphore?

    /// Sized for the extension's memory cap (hev README, "Low memory
    /// usage"): lwIP keeps at most a 64 KB window per connection, and every
    /// session runs on a small task stack instead of large socket buffers.
    ///
    /// max-session-count is not a soft limit: when a new connection reaches
    /// it, hev terminates the least recently active one. Every DNS query is
    /// a UDP session that lives for udp-read-write-timeout, so at 128 busy
    /// browsing could cut idle-but-open connections (chat sockets,
    /// keep-alive HTTP/2). 512 was too many the other way: each session is
    /// several goroutines in the core, heavy use reached 2,300 goroutines,
    /// the Go GC ran 40 times a second and the memory valve restarted the
    /// core every minute. 256 sessions should stay near 1,100 goroutines (about
    /// 34 MB), and a 30 s UDP timeout frees finished DNS lookups twice as
    /// fast, so the cap is rarely reached by lookups alone.
    static func config(socksPort: UInt16, mtu: Int, username: String, password: String) -> String {
        """
        tunnel:
          mtu: \(mtu)
        socks5:
          port: \(socksPort)
          address: \(ProxyHost)
          udp: 'udp'
          username: '\(username)'
          password: '\(password)'
        misc:
          task-stack-size: 28672
          tcp-buffer-size: 8192
          udp-copy-buffer-nums: 4
          udp-recv-buffer-size: 262144
          max-session-count: 256
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 30000
          log-file: stderr
          log-level: warn

        """
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Starts the tunnel on `fd`. `onExit` runs on the tunnel thread when hev
    /// returns, with its result (0 after a requested stop).
    func start(config: String, fd: Int32, onExit: @escaping (_ result: Int32, _ requested: Bool) -> Void) {
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        running = true
        stopRequested = false
        exited = done
        lock.unlock()

        let bytes = Array(config.utf8)
        let thread = Thread { [weak self] in
            var result: Int32 = 0
            for attempt in 0 ..< 2 {
                let startedAt = Date()
                result = bytes.withUnsafeBufferPointer { buffer in
                    hev_socks5_tunnel_main_from_str(buffer.baseAddress, UInt32(buffer.count), fd)
                }
                // A stop that raced with the end of the previous instance
                // leaves hev's stop flag set, and the next run returns at
                // once. Run again when nobody asked for this stop.
                let returnedAtOnce = Date().timeIntervalSince(startedAt) < 0.2
                guard attempt == 0, result == 0, returnedAtOnce, self?.wasStopRequested() == false else { break }
            }
            let requested = self?.wasStopRequested() ?? true
            self?.markExited()
            done.signal()
            autoreleasepool {
                onExit(result, requested)
            }
        }
        thread.name = "com.colitu.vpn.tun2socks"
        thread.start()
    }

    /// Stops the tunnel and waits for its thread to return. False when it did
    /// not stop in time (it is still running and must not be restarted).
    func stop(timeout: TimeInterval) -> Bool {
        lock.lock()
        let wasRunning = running
        let done = exited
        stopRequested = true
        lock.unlock()
        guard wasRunning, let done else { return true }
        hev_socks5_tunnel_quit()
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func wasStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func markExited() {
        lock.lock()
        running = false
        exited = nil
        lock.unlock()
    }
}

private enum TunnelStabilityState: String {
    case disconnected
    case connecting
    case connected
    case networkUnavailable
    case unhealthy
    case reconnecting
    case failed
}

private enum StabilityReconnectReason: String {
    case keepaliveFailed = "keepalive_failed"
    case networkRestored = "network_restored"
    case pathChanged = "path_changed"
    case tunnelStoppedUnexpectedly = "tunnel_stopped_unexpectedly"
    case coreProcessFailed = "core_process_failed"
    case serverReset = "server_reset"
    case appWakeupHealthFailed = "app_wakeup_health_failed"
    case memoryPressure = "memory_pressure"
}

private enum HealthCheckResult: String {
    case started
    case success
    case failed
    case skipped
}

private struct KeepAliveSettings {
    /// How often the loop looks at the core and the traffic counters.
    let interval: TimeInterval
    /// Probe period while apps send through the tunnel.
    let activeProbeInterval: TimeInterval
    /// Probe period while the tunnel is idle.
    let idleProbeInterval: TimeInterval
}

private struct TunnelPathInfo {
    var status = "unknown"
    var interfaceType = "unknown"
    var isExpensive = false
    var isConstrained = false
    var supportsIPv4 = true
    var supportsIPv6 = false

    init() {}

    init(path: Network.NWPath) {
        switch path.status {
        case Network.NWPath.Status.satisfied:
            status = "satisfied"
        case Network.NWPath.Status.unsatisfied:
            status = "unsatisfied"
        case Network.NWPath.Status.requiresConnection:
            status = "requires_connection"
        @unknown default:
            status = "unknown"
        }

        if path.usesInterfaceType(Network.NWInterface.InterfaceType.wifi) {
            interfaceType = "wifi"
        } else if path.usesInterfaceType(Network.NWInterface.InterfaceType.cellular) {
            interfaceType = "cellular"
        } else if path.usesInterfaceType(Network.NWInterface.InterfaceType.wiredEthernet) {
            interfaceType = "ethernet"
        } else if path.usesInterfaceType(Network.NWInterface.InterfaceType.loopback) {
            interfaceType = "loopback"
        } else {
            interfaceType = "other"
        }
        isExpensive = path.isExpensive
        if #available(iOS 13.0, macOS 10.15, *) {
            isConstrained = path.isConstrained
        }
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
    }

    var signature: String {
        "\(status)|\(interfaceType)|\(isExpensive)|\(isConstrained)"
    }
}

private struct TunnelProfileInfo {
    var host: String?
    var port: UInt16?
    var proto: String?
    var profileName: String?

    static func fromCoreRequest(_ coreBase64Text: String) -> TunnelProfileInfo {
        let fileInfo = fromCurrentXrayJson()
        if fileInfo.host != nil, fileInfo.port != nil {
            return fileInfo
        }
        guard let requestData = Data(base64Encoded: coreBase64Text),
              let requestJson = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let configPath = requestJson["configPath"] as? String,
              let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return fileInfo
        }
        return fromXrayJsonData(configData) ?? fileInfo
    }

    static func fromCurrentXrayJson() -> TunnelProfileInfo {
        guard let group = extensionGroupContainerURL() else { return TunnelProfileInfo() }
        let url = group.adaptedAppendPath(path: "run/xray.json")
        guard let data = try? Data(contentsOf: url) else { return TunnelProfileInfo() }
        return fromXrayJsonData(data) ?? TunnelProfileInfo()
    }

    private static func fromXrayJsonData(_ data: Data) -> TunnelProfileInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let outbounds = json["outbounds"] as? [[String: Any]] ?? []
        for outbound in outbounds {
            let protocolName = outbound["protocol"] as? String
            if ["freedom", "blackhole", "dns"].contains(protocolName ?? "") { continue }
            let settings = outbound["settings"] as? [String: Any] ?? [:]
            let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
            if let vnext = settings["vnext"] as? [[String: Any]],
               let first = vnext.first,
               let info = endpoint(from: first, proto: protocolName, stream: stream, tag: outbound["tag"] as? String) {
                return info
            }
            if let servers = settings["servers"] as? [[String: Any]],
               let first = servers.first,
               let info = endpoint(from: first, proto: protocolName, stream: stream, tag: outbound["tag"] as? String) {
                return info
            }
            // Colitu's mobile writer uses libXray's compact outbound schema,
            // where address and port live directly under settings. The route
            // exclusion must understand this form as well as canonical Xray
            // vnext/servers arrays.
            if let info = endpoint(from: settings, proto: protocolName, stream: stream, tag: outbound["tag"] as? String) {
                return info
            }
        }
        return nil
    }

    private static func endpoint(from row: [String: Any], proto: String?, stream: [String: Any], tag: String?) -> TunnelProfileInfo? {
        guard let address = row["address"] as? String else { return nil }
        let rawPort = row["port"]
        let portNumber: UInt16?
        if let number = rawPort as? NSNumber {
            portNumber = number.uint16Value
        } else if let text = rawPort as? String, let value = UInt16(text) {
            portNumber = value
        } else {
            portNumber = nil
        }
        guard let port = portNumber else { return nil }
        let network = stream["network"] as? String
        let security = stream["security"] as? String
        let profile = [proto, network, security].compactMap { $0 }.joined(separator: "/")
        return TunnelProfileInfo(host: address, port: port, proto: profile.isEmpty ? proto : profile, profileName: tag)
    }
}

private struct StabilityLogEntry: CustomStringConvertible {
    let event: String
    let state: String
    let reason: String
    let path: TunnelPathInfo
    let profile: TunnelProfileInfo
    let attempt: Int
    let error: String?
    let metadata: [String: Any]

    var description: String {
        var parts: [String] = [
            "event=\(event)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
            "state=\(state)",
            "reason=\(sanitize(reason))",
            "interface=\(path.interfaceType)",
            "isExpensive=\(path.isExpensive)",
            "isConstrained=\(path.isConstrained)",
            "serverHost=\(sanitizeHost(profile.host))",
            "serverPort=\(profile.port.map(String.init) ?? "unknown")",
            "profile=\(sanitize(profile.proto ?? profile.profileName ?? "unknown"))",
            "attempt=\(attempt)"
        ]
        if let error = error {
            parts.append("error=\(sanitize(error))")
        }
        for key in metadata.keys.sorted() {
            if let value = metadata[key] {
                parts.append("\(sanitize(key))=\(sanitize("\(value)"))")
            }
        }
        return "[stability] " + parts.joined(separator: " ")
    }

    func jsonLine() -> String? {
        var payload: [String: Any] = [
            "event": event,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "state": state,
            "reason": sanitize(reason),
            "interfaceType": path.interfaceType,
            "isExpensive": path.isExpensive,
            "isConstrained": path.isConstrained,
            "serverHost": sanitizeHost(profile.host),
            "serverPort": profile.port.map(String.init) ?? "unknown",
            "profile": sanitize(profile.proto ?? profile.profileName ?? "unknown"),
            "attempt": attempt,
            "platform": "ios"
        ]
        if event == "network_path_changed" || event == "core_started" {
            // An IPv6-only network (NAT64) cannot reach an IPv4 server
            // address without CLAT; this tells such a network apart.
            payload["ipv4"] = path.supportsIPv4
            payload["ipv6"] = path.supportsIPv6
        }
        if let error = error {
            payload["error"] = sanitize(error)
        }
        for (key, value) in metadata {
            let sanitizedKey = sanitize(key)
            if let text = value as? String {
                payload[sanitizedKey] = sanitize(text)
            } else if let number = value as? NSNumber {
                payload[sanitizedKey] = number
            } else if let bool = value as? Bool {
                payload[sanitizedKey] = bool
            } else if let int = value as? Int {
                payload[sanitizedKey] = int
            } else if let double = value as? Double, double.isFinite {
                payload[sanitizedKey] = double
            }
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text + "\n"
    }

    private func sanitizeHost(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "unknown" }
        if value.count <= 80, !value.contains("@"), !value.contains("/") {
            return sanitize(value)
        }
        return "redacted"
    }

    private func sanitize(_ value: String) -> String {
        let forbidden = ["uuid", "password", "token", "private", "shortId", "short_id", "access"]
        let lower = value.lowercased()
        if forbidden.contains(where: { lower.contains($0.lowercased()) }) {
            return "redacted"
        }
        return value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(160)
            .description
    }
}

import Foundation

enum OnDemandRuleMode: String, Codable {
    case connect
    case disconnect
}

enum OnDemandRuleInterfaceType: String, Codable {
    case any
    case cellular
    case wifi
    case ethernet
}

struct OnDemandRule: Codable {
    var mode: OnDemandRuleMode?
    var interfaceType: OnDemandRuleInterfaceType?
    var ssid: [String]?
}

struct TunJson: Codable {
    var tunDnsIPv4: String?
    var tunDnsIPv6: String?
    var enableDot: Bool?
    var dnsServerName: String?
    var enableIPv6: Bool?
    var tunName: String?
    var tunPriority: Int?
    var interface: String?
    var onDemandEnabled: Bool?
    var disconnectOnSleep: Bool?
    var onDemandRules: [OnDemandRule]?
    var perAppVPNMode: String?
    var allowAppList: [String]?
    var disallowAppList: [String]?
    /// Strict kill switch: the VPN profile captures all traffic
    /// (`includeAllNetworks` + `enforceRoutes`). Absent means off.
    var includeAllNetworks: Bool?
    /// Split tunneling: CIDRs ("203.0.113.0/24", "2001:db8::/32") that leave
    /// the tunnel at the routing table. Ignored while `includeAllNetworks`
    /// is on; the core's own direct rules cover them then.
    var excludedRoutes: [String]?
    /// DNS-over-HTTPS resolvers for the system DNS, in order of preference
    /// (the app's ColituSystemDoh). Absent or empty: the classic tunnel DNS.
    var dohUrls: [String]?
}

struct StartVpnRequest: Codable {
    var tun: TunJson?
    var pingPort: String?
    var coreBase64Text: String?

    private static func fromUrl(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        let request = try JSONDecoder().decode(self, from: data)
        return request
    }

    static var startModel: StartVpnRequest? {
        YGLog("tunnel appGroupId=\(appGroupId())")
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId()) {
            YGLog("tunnel groupURL=\(groupURL)")
            let requestUrl = groupURL.adaptedAppendPath(path: StartModelFile)
            do {
                let request = try fromUrl(requestUrl)
                return request
            } catch {}
        }
        return nil
    }
}


struct CallResponse: Codable, Hashable {
    var success: Bool
    var error: String?
    static func fromResponse(_ res: UnsafeMutablePointer<CChar>?) -> Self {
        if let res = res {
            let text = String(cString: res)
            free(res)

            if let data = Data(base64Encoded: text) {
                do {
                    let decoder = JSONDecoder()
                    let model = try decoder.decode(self, from: data)
                    return model
                } catch {}
            }
        }
        return CallResponse(success: false)
    }
}

// MARK: - System extension XPC protocol (app ↔ tunnel)

enum TunnelRequest: Codable {
    case listDat
    case clearDat
    case putDat(name: String, content: Data, mtimeMs: Int64)
    case commitDat
    case startXray
    /// The app rewrote the core config (a warm-spare swap): restart only
    /// the core; the tunnel interface stays.
    case reloadCore
    /// System extension only: the extension cannot read the app's group
    /// container, so a warm-spare swap sends the rewritten core config first.
    case writeCoreConfig(content: Data)
    /// System extension only: the run files the extension writes (traffic
    /// heartbeat, drops, stability log) live in root's group container; the
    /// app copies them into its own container for the Flutter side.
    case readRunFiles(names: [String])
    /// Pings while the VPN is up: the extension times TCP connects to these
    /// addresses from its own sockets, which never enter the tunnel.
    case measureLatency(targets: [LatencyTarget])
}

/// One ping target: an address the app resolved (a literal) and a probe port.
struct LatencyTarget: Codable {
    let address: String
    let port: Int
}

enum TunnelResponse: Codable {
    case ok
    case datManifest([String: Int64])
    case error(String)
    case runFiles([String: Data])
    /// Milliseconds per target of `measureLatency`, in order; -1 = no answer.
    case latency([Int])
}

enum TunnelMessageCoder {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = PropertyListDecoder()
        return try decoder.decode(type, from: data)
    }
}

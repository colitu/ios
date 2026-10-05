import Foundation

public let ProxyHost = "127.0.0.1"
public let TunMtu: NSNumber = 1360

public let StartModelFile = "run/start.json"

public enum Constants {
    public static var useSystemExtension = false
}

private let teamAppGroupId = "7C74T7SHR5.com.colitu.vpn"
private let groupAppGroupId = "group.com.colitu.vpn"
private let seGroupAppGroupId = "group.com.colitu.vpn.se"

public func appGroupId() -> String {
    #if os(iOS)
        return groupAppGroupId
    #elseif os(macOS)
        if Constants.useSystemExtension {
            return seGroupAppGroupId
        } else {
            return teamAppGroupId
        }
    #endif
}

private let tunId = "com.colitu.vpn.tun"
private let seTunId = "com.colitu.vpn.se.tun"

public func packetTunnelId() -> String {
    #if os(iOS)
        return tunId
    #elseif os(macOS)
        if Constants.useSystemExtension {
            return seTunId
        } else {
            return tunId
        }
    #endif
}

private let serverAddress = "Colitu Secure VPN"
private let seServerAddress = "Colitu Secure VPN SE"

public func vpnServerAddress() -> String {
    #if os(iOS)
        return serverAddress
    #elseif os(macOS)
        if Constants.useSystemExtension {
            return seServerAddress
        } else {
            return serverAddress
        }
    #endif
}

public func extensionGroupContainerURL() -> URL? {
    #if os(macOS)
    if Constants.useSystemExtension {
        return URL(fileURLWithPath: "/private/var/root/Library/Group Containers/\(appGroupId())")
    }
    #endif
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId())
}

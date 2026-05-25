import Foundation
import Darwin

class BonjourDiscovery: NSObject {

    var hostsUpdated: (([DiscoveredHost]) -> Void)?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var resolvedHosts: [DiscoveredHost] = []

    func start() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_airdesk._tcp.", inDomain: "local.")
        browser = b
    }

    func stop() {
        browser?.stop()
        browser = nil
        services.removeAll()
        resolvedHosts.removeAll()
        hostsUpdated?([])
    }
}

extension BonjourDiscovery: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        services.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        resolvedHosts.removeAll { $0.name == service.name }
        hostsUpdated?(resolvedHosts)
    }
}

extension BonjourDiscovery: NetServiceDelegate {

    func netServiceDidResolveAddress(_ sender: NetService) {
        let resolvedHost = preferredHost(for: sender)
        guard let resolvedHost else { return }
        let host = DiscoveredHost(name: sender.name, host: resolvedHost, port: sender.port)
        if let existingIndex = resolvedHosts.firstIndex(where: { $0.name == host.name }) {
            let existingHost = resolvedHosts[existingIndex]
            guard existingHost.host != host.host || existingHost.port != host.port else { return }
            resolvedHosts[existingIndex] = host
        } else {
            resolvedHosts.append(host)
        }

        resolvedHosts.sort { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            if lhs.host != rhs.host { return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending }
            return lhs.port < rhs.port
        }
        AirDeskDiagnostics.shared.record("Discovered host \(host.name) at \(host.host):\(host.port)")
        hostsUpdated?(resolvedHosts)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("BonjourDiscovery: failed to resolve \(sender.name)")
    }

    private func preferredHost(for service: NetService) -> String? {
        if let addresses = service.addresses {
            let ipv4Addresses = addresses.compactMap { ipAddress(from: $0, family: AF_INET) }
            if let preferredIPv4 = preferredIPv4(from: ipv4Addresses) {
                return preferredIPv4
            }

            let ipv6Addresses = addresses.compactMap { ipAddress(from: $0, family: AF_INET6) }
            if let preferredIPv6 = preferredIPv6(from: ipv6Addresses) {
                return preferredIPv6
            }
        }

        return normalizedHostName(for: service)
    }

    private func normalizedHostName(for service: NetService) -> String? {
        guard let hostName = service.hostName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostName.isEmpty else {
            return nil
        }
        return hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
    }

    private func preferredIPv4(from addresses: [String]) -> String? {
        let ranked = addresses
            .map { ($0, scoreIPv4($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0 < rhs.0
            }
        return ranked.first(where: { $0.1 > 0 })?.0 ?? ranked.first?.0
    }

    private func preferredIPv6(from addresses: [String]) -> String? {
        let ranked = addresses
            .map { ($0, scoreIPv6($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0 < rhs.0
            }
        return ranked.first(where: { $0.1 > 0 })?.0 ?? ranked.first?.0
    }

    private func scoreIPv4(_ address: String) -> Int {
        if address.hasPrefix("127.") { return 0 }
        if address.hasPrefix("169.254.") { return 1 }
        if address.hasPrefix("192.168.") { return 5 }
        if address.hasPrefix("10.") { return 5 }
        if address.hasPrefix("172.") {
            let octets = address.split(separator: ".")
            if octets.count > 1, let second = Int(octets[1]), (16...31).contains(second) {
                return 5
            }
        }
        return 4
    }

    private func scoreIPv6(_ address: String) -> Int {
        let lowercased = address.lowercased()
        if lowercased == "::1" || lowercased.hasPrefix("0:0:0:0:0:0:0:1") { return 0 }
        if lowercased.hasPrefix("fe80:") { return 1 }
        return 3
    }

    private func ipAddress(from data: Data, family: Int32) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let sockaddr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                return nil
            }

            switch Int32(sockaddr.pointee.sa_family) {
            case AF_INET where family == AF_INET:
                var addr = rawBuffer.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buffer)

            case AF_INET6 where family == AF_INET6:
                var addr = rawBuffer.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buffer)

            default:
                return nil
            }
        }
    }
}

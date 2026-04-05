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

        if !resolvedHosts.contains(where: { $0.name == host.name }) {
            resolvedHosts.append(host)
            hostsUpdated?(resolvedHosts)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("BonjourDiscovery: failed to resolve \(sender.name)")
    }

    private func preferredHost(for service: NetService) -> String? {
        if let addresses = service.addresses {
            for address in addresses {
                if let ip = ipAddress(from: address, family: AF_INET) {
                    return ip
                }
            }
            for address in addresses {
                if let ip = ipAddress(from: address, family: AF_INET6) {
                    return ip
                }
            }
        }

        if let hostName = service.hostName {
            return hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        }

        return nil
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

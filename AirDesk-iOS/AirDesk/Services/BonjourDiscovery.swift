import Foundation

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
        guard let hostName = sender.hostName else { return }
        let cleanHost = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let host = DiscoveredHost(name: sender.name, host: cleanHost, port: sender.port)

        if !resolvedHosts.contains(where: { $0.name == host.name }) {
            resolvedHosts.append(host)
            hostsUpdated?(resolvedHosts)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("BonjourDiscovery: failed to resolve \(sender.name)")
    }
}

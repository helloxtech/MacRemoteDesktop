import Foundation

class BonjourAdvertiser: NSObject, NetServiceDelegate {

    private var service: NetService?
    private let port: Int

    init(port: Int) {
        self.port = port
        super.init()
    }

    func start() {
        let hostName = Host.current().localizedName ?? "Mac"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
        service = NetService(domain: "local.", type: "_airdesk._tcp.", name: hostName, port: Int32(port))
        service?.delegate = self

        let txtData = NetService.data(fromTXTRecord: [
            "version": appVersion.data(using: .utf8)!,
            "name": hostName.data(using: .utf8)!
        ])
        service?.setTXTRecord(txtData)
        service?.publish()
        print("BonjourAdvertiser: advertising \(hostName) on port \(port)")
    }

    func stop() {
        service?.stop()
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        print("BonjourAdvertiser: published successfully")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("BonjourAdvertiser: failed to publish - \(errorDict)")
    }
}

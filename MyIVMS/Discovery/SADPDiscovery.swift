import Foundation
import Network
import Combine

/// A device found on the LAN via the SADP multicast protocol.
struct DiscoveredDevice: Identifiable, Hashable {
    var id: String { mac.isEmpty ? ipv4 : mac }
    var deviceType: String = ""
    var description_: String = ""
    var serial: String = ""
    var mac: String = ""
    var ipv4: String = ""
    var subnetMask: String = ""
    var gateway: String = ""
    var httpPort: Int = 80
    var commandPort: Int = 8000
    var firmware: String = ""
    var activated: Bool = true
}

/// Hikvision SADP discovery.
///
/// SADP is a multicast protocol on `239.255.255.250:37020`. We broadcast an
/// XML `<Probe>` inquiry; devices reply (also via multicast) with an XML
/// `<ProbeMatch>` describing themselves. This mirrors what the official SADP
/// tool does, using only Apple's Network.framework.
@MainActor
final class SADPDiscovery: ObservableObject {
    @Published private(set) var found: [DiscoveredDevice] = []
    @Published private(set) var isScanning = false

    private var group: NWConnectionGroup?
    private let multicastHost = "239.255.255.250"
    private let multicastPort: NWEndpoint.Port = 37020
    private var repeatTimer: Timer?

    func start() {
        guard !isScanning else { return }
        found.removeAll()

        do {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(multicastHost),
                port: multicastPort)
            let mgroup = try NWMulticastGroup(for: [endpoint])
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let group = NWConnectionGroup(with: mgroup, using: params)

            group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: false) { [weak self] _, content, _ in
                guard let content else { return }
                Task { @MainActor in self?.handle(datagram: content) }
            }

            group.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.sendProbe()
                    case .failed, .cancelled:
                        self?.isScanning = false
                    default:
                        break
                    }
                }
            }

            self.group = group
            isScanning = true
            group.start(queue: .global(qos: .userInitiated))

            // Re-probe a few times to catch devices that missed the first shot.
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sendProbe() }
            }
        } catch {
            isScanning = false
        }
    }

    func stop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        group?.cancel()
        group = nil
        isScanning = false
    }

    private func sendProbe() {
        guard let group else { return }
        let uuid = UUID().uuidString
        let probe = """
        <?xml version="1.0" encoding="utf-8"?>\
        <Probe><Uuid>\(uuid)</Uuid><Types>inquiry</Types></Probe>
        """
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(multicastHost),
            port: multicastPort)
        group.send(content: Data(probe.utf8), to: endpoint) { _ in }
    }

    private func handle(datagram: Data) {
        guard let device = SADPResponseParser.parse(datagram), !device.ipv4.isEmpty else { return }
        if let idx = found.firstIndex(where: { $0.id == device.id }) {
            found[idx] = device
        } else {
            found.append(device)
            found.sort { $0.ipv4 < $1.ipv4 }
        }
    }
}

/// Parses a SADP `<ProbeMatch>` XML datagram.
private final class SADPResponseParser: NSObject, XMLParserDelegate {
    private var device = DiscoveredDevice()
    private var currentElement = ""
    private var buffer = ""

    static func parse(_ data: Data) -> DiscoveredDevice? {
        let parser = SADPResponseParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return nil }
        return parser.device
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        currentElement = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "DeviceType": device.deviceType = value
        case "DeviceDescription": device.description_ = value
        case "DeviceSN": device.serial = value
        case "MAC": device.mac = value
        case "IPv4Address": device.ipv4 = value
        case "IPv4SubnetMask": device.subnetMask = value
        case "IPv4Gateway": device.gateway = value
        case "HttpPort": device.httpPort = Int(value) ?? 80
        case "CommandPort": device.commandPort = Int(value) ?? 8000
        case "DSPVersion", "SoftwareVersion": device.firmware = value
        case "Activated": device.activated = (value.lowercased() == "true")
        default: break
        }
        buffer = ""
    }
}

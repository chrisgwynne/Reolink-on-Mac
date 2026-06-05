import Foundation
import Network

/// Discovers Reolink/ONVIF cameras on the local network.
///
/// Reolink cameras answer ONVIF WS-Discovery probes sent to the multicast
/// group `239.255.255.250:3702`. This service broadcasts a probe and collects
/// `ProbeMatch` responses, extracting the device's IP address.
///
/// WS-Discovery is best-effort: some networks block multicast, and some models
/// disable ONVIF by default. Discovery failures are non-fatal — the user can
/// always add a camera manually.
actor CameraDiscoveryService {

    struct DiscoveredCamera: Identifiable, Hashable {
        var id: String { address }
        let address: String
        let xaddrs: String
    }

    private static let multicastHost = "239.255.255.250"
    private static let multicastPort: UInt16 = 3702

    /// Run a discovery sweep for `timeout` seconds and return unique results.
    func discover(timeout: TimeInterval = 4) async -> [DiscoveredCamera] {
        let probe = Self.makeProbeMessage()

        guard let connection = makeMulticastConnection() else { return [] }

        var results: [String: DiscoveredCamera] = [:]

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            func finish() {
                lock.lock(); defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                continuation.resume(returning: Array(results.values))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: probe, completion: .contentProcessed { _ in
                        Self.receiveLoop(on: connection) { match in
                            lock.lock()
                            results[match.address] = match
                            lock.unlock()
                        }
                    })
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish()
            }
        }
    }

    // MARK: - Private

    private func makeMulticastConnection() -> NWConnection? {
        let host = NWEndpoint.Host(Self.multicastHost)
        guard let port = NWEndpoint.Port(rawValue: Self.multicastPort) else { return nil }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        return NWConnection(host: host, port: port, using: params)
    }

    private static func receiveLoop(
        on connection: NWConnection,
        onMatch: @escaping (DiscoveredCamera) -> Void
    ) {
        connection.receiveMessage { data, _, _, error in
            if let data, let match = parseProbeMatch(data) {
                onMatch(match)
            }
            if error == nil {
                receiveLoop(on: connection, onMatch: onMatch)
            }
        }
    }

    /// Minimal WS-Discovery `Probe` SOAP envelope targeting ONVIF NetworkVideoTransmitter.
    private static func makeProbeMessage() -> Data {
        let messageID = "uuid:\(UUID().uuidString)"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
         xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
         xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
         xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
          <e:Header>
            <w:MessageID>\(messageID)</w:MessageID>
            <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
            <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
          </e:Header>
          <e:Body>
            <d:Probe>
              <d:Types>dn:NetworkVideoTransmitter</d:Types>
            </d:Probe>
          </e:Body>
        </e:Envelope>
        """
        return Data(xml.utf8)
    }

    /// Extract the device service address (`XAddrs`) and IP from a ProbeMatch.
    private static func parseProbeMatch(_ data: Data) -> DiscoveredCamera? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        guard let xaddrs = firstMatch(in: body, tag: "XAddrs") else { return nil }
        // XAddrs is a space-separated list of URLs; take the first host.
        let first = xaddrs.split(separator: " ").first.map(String.init) ?? xaddrs
        guard let url = URL(string: first), let host = url.host else { return nil }
        return DiscoveredCamera(address: host, xaddrs: xaddrs)
    }

    private static func firstMatch(in xml: String, tag: String) -> String? {
        // Handles optional namespace prefixes like <d:XAddrs>.
        guard let openRange = xml.range(of: "\(tag)>"),
              let closeRange = xml.range(of: "</", range: openRange.upperBound..<xml.endIndex) else {
            return nil
        }
        let value = xml[openRange.upperBound..<closeRange.lowerBound]
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

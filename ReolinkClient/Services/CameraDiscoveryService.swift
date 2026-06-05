import Foundation
import Network

/// Discovers Reolink/ONVIF cameras on the local network via UDP WS-Discovery.
///
/// Sends an ONVIF `Probe` to the multicast group `239.255.255.250:3702` and
/// streams `ProbeMatch` responses back as they arrive. Implemented with
/// `NWConnectionGroup` + `NWMulticastGroup`, the canonical Network.framework
/// API for multicast send/receive.
///
/// Discovery is **best-effort and credential-free**: some networks block
/// multicast and some models ship with ONVIF disabled, so the UI always offers
/// manual add as a fallback. This type is intentionally independent of
/// ``ReolinkAPIClient`` — it only finds hosts; verification happens later via
/// the normal login flow.
final class CameraDiscoveryService {

    /// A camera found on the network. Deduplicated by ``host``.
    struct DiscoveredCamera: Identifiable, Hashable {
        let host: String
        let name: String?
        let manufacturer: String?
        let model: String?
        /// The ONVIF device service URL(s) advertised in the ProbeMatch.
        let xaddrs: String

        var id: String { host }

        /// Best human-facing label for the device.
        var displayName: String { name ?? model ?? host }

        /// Secondary line: manufacturer/model, falling back to the service URL.
        var subtitle: String {
            var parts: [String] = []
            if let manufacturer, !manufacturer.isEmpty { parts.append(manufacturer) }
            if let model, !model.isEmpty, model != name { parts.append(model) }
            return parts.isEmpty ? xaddrs : parts.joined(separator: " • ")
        }

        /// Name to prefill into Add Camera.
        var suggestedName: String { model ?? name ?? "Camera \(host)" }

        /// Heuristic: does this look like a Reolink device? Unknown ONVIF
        /// cameras are still shown — this only drives highlighting/ordering.
        var isLikelyReolink: Bool {
            let blob = [manufacturer, model, name, xaddrs]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            if blob.contains("reolink") { return true }
            if let model, model.uppercased().hasPrefix("RL") { return true }
            return false
        }
    }

    private static let multicastHost = "239.255.255.250"
    private static let multicastPort: UInt16 = 3702

    /// Run a discovery sweep, yielding unique devices live until `timeout`.
    func discover(timeout: TimeInterval = 5) -> AsyncStream<DiscoveredCamera> {
        AsyncStream { continuation in
            let seen = SeenHosts()
            let probe = Self.makeProbeMessage()

            let group: NWConnectionGroup
            do {
                guard let port = NWEndpoint.Port(rawValue: Self.multicastPort) else {
                    continuation.finish(); return
                }
                let endpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(Self.multicastHost),
                    port: port
                )
                let multicast = try NWMulticastGroup(for: [endpoint])
                group = NWConnectionGroup(with: multicast, using: .udp)
            } catch {
                // Multicast unavailable (blocked network / missing entitlement).
                continuation.finish()
                return
            }

            group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { _, content, _ in
                guard let content, let device = Self.parseProbeMatch(content) else { return }
                if seen.insert(device.host) {
                    continuation.yield(device)
                }
            }

            group.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    group.send(content: probe) { _ in }
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }

            group.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                group.cancel()
                continuation.finish()
            }

            continuation.onTermination = { _ in group.cancel() }
        }
    }

    // MARK: - Probe construction

    /// Minimal WS-Discovery `Probe` SOAP envelope for ONVIF NetworkVideoTransmitter.
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

    // MARK: - Response parsing

    /// Extract host, ONVIF scopes (name/manufacturer/model), and XAddrs.
    static func parseProbeMatch(_ data: Data) -> DiscoveredCamera? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        guard let xaddrsRaw = firstTagValue(in: body, tag: "XAddrs"), !xaddrsRaw.isEmpty else {
            return nil
        }
        // XAddrs is a space-separated list; take the first service URL's host.
        let firstX = xaddrsRaw.split(separator: " ").first.map(String.init) ?? xaddrsRaw
        guard let url = URL(string: firstX), let host = url.host else { return nil }

        let scopes = parseScopes(firstTagValue(in: body, tag: "Scopes") ?? "")
        let name = scopes["name"]
        return DiscoveredCamera(
            host: host,
            name: name,
            manufacturer: scopes["manufacturer"] ?? scopes["mfr"],
            model: name ?? scopes["hardware"],   // Reolink encodes the model as the name scope
            xaddrs: firstX
        )
    }

    /// Parse ONVIF scope URIs (`onvif://www.onvif.org/<key>/<value>`) into a map.
    static func parseScopes(_ scopes: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in scopes.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let url = URL(string: String(token)), url.scheme == "onvif" else { continue }
            let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].removingPercentEncoding ?? parts[1]
            if result[key] == nil { result[key] = value }
        }
        return result
    }

    /// Read the first `<tag>…</tag>` value, tolerating namespace prefixes.
    private static func firstTagValue(in xml: String, tag: String) -> String? {
        guard let openRange = xml.range(of: "\(tag)>"),
              let closeRange = xml.range(of: "</", range: openRange.upperBound..<xml.endIndex) else {
            return nil
        }
        return xml[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mock results (previews / tests)

    /// Deterministic sample devices for SwiftUI previews and development.
    static let mockResults: [DiscoveredCamera] = [
        DiscoveredCamera(host: "192.168.1.20", name: "RLC-810A", manufacturer: "Reolink",
                         model: "RLC-810A", xaddrs: "http://192.168.1.20:8000/onvif/device_service"),
        DiscoveredCamera(host: "192.168.1.21", name: "RLC-520A", manufacturer: "Reolink",
                         model: "RLC-520A", xaddrs: "http://192.168.1.21:8000/onvif/device_service"),
        DiscoveredCamera(host: "192.168.1.50", name: "Doorbell", manufacturer: "Acme",
                         model: "IPC-Generic", xaddrs: "http://192.168.1.50:80/onvif/device_service")
    ]
}

/// Tiny thread-safe set used to dedupe discovered hosts across the receive queue.
private final class SeenHosts {
    private var hosts = Set<String>()
    private let lock = NSLock()

    /// Returns `true` if `host` was newly inserted.
    func insert(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hosts.insert(host).inserted
    }
}

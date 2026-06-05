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
        /// Raw ONVIF `name` scope. May be a generic label like "Camera".
        let friendlyName: String?
        let manufacturer: String?
        /// Raw ONVIF `hardware` scope (often the real model on Reolink).
        let hardware: String?
        /// Best identifier: the friendly name when meaningful, else the
        /// hardware scope. See ``CameraDiscoveryService/makeDevice``.
        let model: String?
        /// The ONVIF device service URL advertised in the ProbeMatch.
        let xaddrs: String
        /// Whether this looks like a Reolink device. Computed once at parse time;
        /// unknown ONVIF cameras are still surfaced — this only drives highlighting.
        let isLikelyReolink: Bool

        var id: String { host }

        /// Best human-facing label: prefer the resolved model, then the raw
        /// (possibly generic) name, then the host.
        var displayName: String { model ?? friendlyName ?? host }

        /// Secondary line: manufacturer and the raw advertised name when it
        /// differs from the display name; falls back to the service URL.
        var subtitle: String {
            var parts: [String] = []
            if let manufacturer, !manufacturer.isEmpty { parts.append(manufacturer) }
            if let friendlyName, !friendlyName.isEmpty, friendlyName != displayName {
                parts.append("seen as “\(friendlyName)”")
            }
            return parts.isEmpty ? xaddrs : parts.joined(separator: " • ")
        }

        /// Name to prefill into Add Camera.
        var suggestedName: String { model ?? friendlyName ?? "Camera \(host)" }
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

    /// Friendly names that carry no model information and should be treated as
    /// weak labels (we prefer the hardware scope when one of these is the name).
    private static let genericNames: Set<String> = [
        "camera", "network camera", "ip camera", "onvif camera", "device"
    ]

    /// Tokens that mark a device as (likely) Reolink. Distinctive words are
    /// matched as substrings; short model-family codes are matched at token
    /// boundaries to avoid false positives (e.g. "go" inside another word).
    private static let reolinkSubstrings = ["reolink", "argus", "trackmix"]
    private static let reolinkTokenPrefixes = ["rlc", "rln", "rld", "duo", "e1", "cx", "go"]

    /// Extract host, ONVIF scopes, and XAddrs from a ProbeMatch response.
    static func parseProbeMatch(_ data: Data) -> DiscoveredCamera? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        guard let xaddrsRaw = firstTagValue(in: body, tag: "XAddrs"), !xaddrsRaw.isEmpty else {
            return nil
        }
        // XAddrs is a space-separated list; take the first service URL's host.
        let firstX = xaddrsRaw.split(separator: " ").first.map(String.init) ?? xaddrsRaw
        guard let url = URL(string: firstX), let host = url.host else { return nil }

        let scopes = parseScopes(firstTagValue(in: body, tag: "Scopes") ?? "")
        return makeDevice(host: host, xaddrs: firstX, scopes: scopes)
    }

    /// Build a ``DiscoveredCamera`` from parsed scope fields. Pure and
    /// side-effect-free so it can be exercised by the parsing samples below.
    static func makeDevice(host: String, xaddrs: String, scopes: [String: String]) -> DiscoveredCamera {
        let name = scopes["name"]?.trimmingCharacters(in: .whitespaces)
        let hardware = scopes["hardware"]?.trimmingCharacters(in: .whitespaces)
        let manufacturer = (scopes["manufacturer"] ?? scopes["mfr"] ?? scopes["vendor"])?
            .trimmingCharacters(in: .whitespaces)

        let model = preferredModel(name: name, hardware: hardware)
        let likely = isLikelyReolink(name: name, hardware: hardware,
                                     manufacturer: manufacturer, xaddrs: xaddrs)

        return DiscoveredCamera(
            host: host,
            friendlyName: name?.isEmpty == false ? name : nil,
            manufacturer: manufacturer?.isEmpty == false ? manufacturer : nil,
            hardware: hardware?.isEmpty == false ? hardware : nil,
            model: model,
            xaddrs: xaddrs,
            isLikelyReolink: likely
        )
    }

    /// Choose the most useful model/identifier: a meaningful friendly name wins;
    /// when the name is generic, fall back to the hardware scope.
    static func preferredModel(name: String?, hardware: String?) -> String? {
        if let name, !name.isEmpty, !isGenericName(name) {
            return name
        }
        if let hardware, !hardware.isEmpty {
            return hardware
        }
        // Only a generic name (or nothing) available.
        if let name, !name.isEmpty { return name }
        return nil
    }

    static func isGenericName(_ name: String) -> Bool {
        genericNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Heuristic Reolink detection across name/hardware/manufacturer/XAddrs.
    /// Unknown ONVIF cameras simply return `false` (still shown, just not badged).
    static func isLikelyReolink(name: String?, hardware: String?,
                                manufacturer: String?, xaddrs: String) -> Bool {
        let blob = [manufacturer, name, hardware, xaddrs]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if reolinkSubstrings.contains(where: { blob.contains($0) }) {
            return true
        }
        // Token-boundary match for short family codes (rlc, e1, cx, go, …).
        let tokens = tokenize([manufacturer, name, hardware].compactMap { $0 }.joined(separator: " "))
        for token in tokens where reolinkTokenPrefixes.contains(where: { token.hasPrefix($0) }) {
            return true
        }
        return false
    }

    /// Lowercase alphanumeric tokens, split on any non-alphanumeric character.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
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

    // MARK: - Mock results (previews / development)

    /// Deterministic sample devices for SwiftUI previews and development. Built
    /// through ``makeDevice`` so they exercise the real labelling logic.
    static let mockResults: [DiscoveredCamera] = [
        makeDevice(host: "192.168.1.20",
                   xaddrs: "http://192.168.1.20:8000/onvif/device_service",
                   scopes: ["name": "Reolink RLC-810A", "hardware": "IPC_523128M8MP"]),
        makeDevice(host: "192.168.1.21",
                   xaddrs: "http://192.168.1.21:8000/onvif/device_service",
                   scopes: ["name": "Camera", "hardware": "RLC-520A"]),
        makeDevice(host: "192.168.1.50",
                   xaddrs: "http://192.168.1.50/onvif/device_service",
                   scopes: ["name": "ONVIF Camera"])
    ]

    // MARK: - Parsing samples (documented expectations)

    /// Representative ONVIF `Scopes`/`XAddrs` inputs and the expected resolved
    /// display name + Reolink highlighting. Doubles as lightweight, runnable
    /// regression coverage via ``parsingSelfCheck()``.
    struct ParsingSample {
        let label: String
        let scopes: [String: String]
        let xaddrs: String
        let expectedDisplayName: String
        let expectedReolink: Bool
    }

    static let parsingSamples: [ParsingSample] = [
        ParsingSample(
            label: "Reolink model in name scope",
            scopes: ["name": "Reolink RLC-520A"],
            xaddrs: "http://10.0.0.10:8000/onvif/device_service",
            expectedDisplayName: "Reolink RLC-520A",
            expectedReolink: true
        ),
        ParsingSample(
            label: "Generic name, model in hardware scope",
            scopes: ["name": "Camera", "hardware": "RLC-520A"],
            xaddrs: "http://10.0.0.11:8000/onvif/device_service",
            expectedDisplayName: "RLC-520A",
            expectedReolink: true
        ),
        ParsingSample(
            label: "Generic name + opaque hardware (unknown ONVIF)",
            scopes: ["name": "Network Camera", "hardware": "IPC_51516M5M"],
            xaddrs: "http://10.0.0.12/onvif/device_service",
            expectedDisplayName: "IPC_51516M5M",
            expectedReolink: false
        ),
        ParsingSample(
            label: "Only a generic ONVIF name",
            scopes: ["name": "ONVIF Camera"],
            xaddrs: "http://10.0.0.13/onvif/device_service",
            expectedDisplayName: "ONVIF Camera",
            expectedReolink: false
        )
    ]

    /// Run the documented samples through the parser; returns a human-readable
    /// list of mismatches (empty == all pass). Usable from previews or a future
    /// test target without any hardware.
    static func parsingSelfCheck() -> [String] {
        var failures: [String] = []
        for sample in parsingSamples {
            let device = makeDevice(host: "host", xaddrs: sample.xaddrs, scopes: sample.scopes)
            if device.displayName != sample.expectedDisplayName {
                failures.append("[\(sample.label)] displayName = \"\(device.displayName)\", expected \"\(sample.expectedDisplayName)\"")
            }
            if device.isLikelyReolink != sample.expectedReolink {
                failures.append("[\(sample.label)] isLikelyReolink = \(device.isLikelyReolink), expected \(sample.expectedReolink)")
            }
        }
        return failures
    }
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

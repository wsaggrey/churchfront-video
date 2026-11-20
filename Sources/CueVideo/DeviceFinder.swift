import Foundation
import Darwin

/// Finds the switcher and cameras on this Mac's network, so a church's assistant (or a
/// person in Setup) never has to look up an IP address. Three passes, run together:
///
/// - ATEM switchers: the ATEM hello packet (UDP 9910) to every address on each local /24.
///   Every ATEM answers it, whatever its firmware, with no Bonjour needed.
/// - Canon PTZ cameras: Canon's HTTP control page (/-wvhttp-01-/info.cgi) on the same addresses.
/// - Everything that announces itself: Bonjour for NDI sources (PTZOptics, BirdDog and most
///   NDI cameras), Blackmagic devices and web pages, with each one's address.
///
/// Nothing is changed: the result is a list for update_config.
enum DeviceFinder {
    struct Found: Hashable { var kind: String; var name: String; var host: String }

    static func find(seconds: Double = 3, _ done: @escaping ([Found], [String]) -> Void) {
        let nets = localNetworks()
        var found = Set<Found>()
        let lock = NSLock()
        let add: (Found) -> Void = { f in lock.lock(); found.insert(f); lock.unlock() }
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { probeATEM(nets, wait: seconds).forEach(add); group.leave() }

        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = seconds - 0.5; return c }())
        for host in nets.flatMap(hosts(in:)) {
            guard let url = URL(string: "http://\(host)/-wvhttp-01-/info.cgi") else { continue }
            group.enter()
            session.dataTask(with: url) { data, resp, _ in
                defer { group.leave() }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = data.flatMap({ String(data: $0, encoding: .utf8) }),
                      text.contains("c.1.") || text.contains("s.") else { return }
                add(Found(kind: "Canon PTZ camera (proto canonXC)", name: canonName(text) ?? "Canon camera", host: host))
            }.resume()
        }

        group.enter()
        DispatchQueue.main.async {
            let b = Bonjour(types: ["_ndi._tcp.", "_blackmagic._tcp.", "_http._tcp."])
            b.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { b.stop(); b.results.forEach(add); group.leave() }
        }

        group.notify(queue: .main) {
            let order = ["ATEM", "Canon", "NDI", "Blackmagic", "Web"]
            let list = found.sorted { a, b in
                let ia = order.firstIndex { a.kind.hasPrefix($0) } ?? 9, ib = order.firstIndex { b.kind.hasPrefix($0) } ?? 9
                return ia != ib ? ia < ib : a.host.compare(b.host, options: .numeric) == .orderedAscending
            }
            done(list, nets.map { "\($0).0/24" })
        }
    }

    /// The first three octets of each IPv4 network this Mac is on (en*, bridge*, not loopback).
    static func localNetworks() -> [String] {
        var nets: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return [] }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (i.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
                var a = s.pointee.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buf)
            guard !ip.hasPrefix("169.254.") else { continue }
            let net = ip.split(separator: ".").prefix(3).joined(separator: ".")
            if !nets.contains(net) { nets.append(net) }
        }
        return nets
    }

    private static func hosts(in net: String) -> [String] { (1...254).map { "\(net).\($0)" } }

    private static func canonName(_ text: String) -> String? {
        for key in ["c.1.name.utf8=", "s.hardware=", "s.product="] {
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix(key) }) {
                let v = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// Sends the ATEM hello to every address and collects whoever answers within `wait` seconds.
    private static func probeATEM(_ nets: [String], wait: Double) -> [Found] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        let hello: [UInt8] = [0x10, 0x14, 0x53, 0xAB, 0, 0, 0, 0, 0, 0x3A, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0]
        for host in nets.flatMap(hosts(in:)) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9910).bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, hello, hello.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Set<Found>()
        let end = Date().addingTimeInterval(wait)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < end {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n >= 12, (buf[0] & 0xF8) != 0 else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            out.insert(Found(kind: "ATEM switcher (atemHost)", name: "ATEM switcher", host: String(cString: ip)))
        }
        return Array(out)
    }
}

/// Bonjour browsing with each service resolved to its IPv4 address.
private final class Bonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    let types: [String]
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private(set) var results: [DeviceFinder.Found] = []

    init(types: [String]) { self.types = types }

    func start() {
        for t in types {
            let b = NetServiceBrowser(); b.delegate = self
            b.searchForServices(ofType: t, inDomain: "local.")
            browsers.append(b)
        }
    }

    func stop() { browsers.forEach { $0.stop() }; services.forEach { $0.stop() } }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let ip = sender.addresses?.compactMap(Self.ipv4).first else { return }
        let kind: String
        switch sender.type {
        case "_ndi._tcp.": kind = "NDI source (use the name for ndi fields; an NDI HX PTZ camera here, such as a Fomako or PTZOptics, usually takes proto sonyUDP on port 52381, or rawTCP on 5678, and this name as the ndi of its switcher input's source)"
        case "_blackmagic._tcp.": kind = "Blackmagic device"
        default: kind = "Web page (a camera, converter or other device with a control page)"
        }
        results.append(.init(kind: kind, name: sender.name, host: ip))
    }

    private static func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            let s = String(cString: buf)
            return (s.hasPrefix("169.254.") || s.hasPrefix("127.")) ? nil : s
        }
    }
}

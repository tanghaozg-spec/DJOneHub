import Foundation
import Network
import Darwin

/// 模块 HTTP 响应；传输层只保留上层解码和错误处理真正需要的字段。
struct WiredHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

/// 使用 Network.framework 将模块控制请求固定到 USB ECM，避免 Wi-Fi 或 VPN 抢走私网路由。
final class WiredHTTPTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jieden.djonehub.wired-http", qos: .userInitiated)
    private let interfaceLock = NSLock()
    private var preferredInterfaceType: NWInterface.InterfaceType = .wiredEthernet

    static func allowsInterfaceFallback(httpMethod: String?) -> Bool {
        switch httpMethod?.uppercased() ?? "GET" {
        case "GET", "HEAD": return true
        default: return false
        }
    }

    /// 前后台切换后系统可能重新创建 USB ECM 接口；旧的 NWInterface 对象不能继续复用。
    func resetConnectionState() {
        ModuleUSBInterfaceResolver.invalidate()
        setPreferredInterface(.wiredEthernet)
    }

    func send(_ request: URLRequest, uploadFileURL: URL? = nil) async throws -> WiredHTTPResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw WiredHTTPError.invalidRequest
        }

        let body: WiredHTTPBody
        if let uploadFileURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: uploadFileURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw WiredHTTPError.unreadableUpload
            }
            body = .file(uploadFileURL, size.uint64Value)
        } else if let data = request.httpBody, !data.isEmpty {
            body = .data(data)
        } else {
            body = .none
        }

        if let moduleInterface = ModuleUSBInterfaceResolver.resolve() {
            do {
                return try await sendOnce(
                    request,
                    host: NWEndpoint.Host(host),
                    port: port,
                    body: body,
                    route: .exact(moduleInterface)
                )
            } catch {
                guard Self.allowsInterfaceFallback(httpMethod: request.httpMethod),
                      (error as? WiredHTTPError)?.isInterfaceFailure == true else { throw error }
                // 严格绑定失败通常意味着模块刚刚重枚举；下一次请求必须重新解析网卡。
                ModuleUSBInterfaceResolver.invalidate()
            }
        }

        let preferred = lockedPreferredInterface()
        do {
            return try await sendOnce(
                request,
                host: NWEndpoint.Host(host),
                port: port,
                body: body,
                route: .type(preferred)
            )
        } catch {
            guard Self.allowsInterfaceFallback(httpMethod: request.httpMethod),
                  (error as? WiredHTTPError)?.isInterfaceFailure == true else { throw error }
            let fallback: NWInterface.InterfaceType = preferred == .wiredEthernet ? .other : .wiredEthernet
            do {
                let response = try await sendOnce(
                    request,
                    host: NWEndpoint.Host(host),
                    port: port,
                    body: body,
                    route: .type(fallback)
                )
                setPreferredInterface(fallback)
                return response
            } catch {
                guard (error as? WiredHTTPError)?.isInterfaceFailure == true else { throw error }
                // 最后兜底：不绑定任何接口，交给系统按 192.168.225.0/24 的路由表选择。
                // iOS 在蜂窝或 Wi-Fi 为主接口时，可能拒绝把连接显式绑定到 USB 以太网。
                return try await sendOnce(
                    request,
                    host: NWEndpoint.Host(host),
                    port: port,
                    body: body,
                    route: .system
                )
            }
        }
    }

    private func sendOnce(
        _ request: URLRequest,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        body: WiredHTTPBody,
        route: WiredInterfaceRoute
    ) async throws -> WiredHTTPResponse {
        let cancellationGate = WiredRequestCancellationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operation = WiredHTTPRequestOperation(
                    request: request,
                    host: host,
                    port: port,
                    body: body,
                    route: route,
                    queue: queue,
                    continuation: continuation
                )
                // Swift Task 的取消不会自动传递给 NWConnection，必须显式关闭旧 TCP。
                cancellationGate.install { operation.cancel() }
                operation.start()
            }
        } onCancel: {
            cancellationGate.cancel()
        }
    }

    private func lockedPreferredInterface() -> NWInterface.InterfaceType {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        return preferredInterfaceType
    }

    private func setPreferredInterface(_ interfaceType: NWInterface.InterfaceType) {
        interfaceLock.lock()
        preferredInterfaceType = interfaceType
        interfaceLock.unlock()
    }
}

/// 协调 Swift Task 与底层网络操作的取消竞速；无论先取消还是先创建连接都只执行一次。
final class WiredRequestCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationAction: (() -> Void)?
    private var cancellationRequested = false

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        if cancellationRequested {
            lock.unlock()
            action()
            return
        }
        cancellationAction = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let action = cancellationAction
        cancellationAction = nil
        lock.unlock()
        action?()
    }
}

struct NetworkInterfaceAddress: Equatable, Sendable {
    let name: String
    let address: String
}

/// 从本机 192.168.225.x 地址反查模块 USB ECM 接口。通过接口名精确绑定后，
/// 即使 VPN 改写默认路由，发往模块的请求也不会误入 utun 或 Wi-Fi。
enum ModuleUSBInterfaceResolver {
    private static let monitorQueue = DispatchQueue(label: "com.jieden.djonehub.usb-interface")
    private static let cacheLock = NSLock()
    private static var cachedInterface: NWInterface?
    private static var cacheExpiresAt: UInt64 = 0
    // 状态轮询每秒执行一次；短缓存可以避免每个 HTTP 请求都创建 NWPathMonitor。
    private static let cacheLifetimeNanoseconds: UInt64 = 1_000_000_000

    static func moduleInterfaceNames(from addresses: [NetworkInterfaceAddress]) -> Set<String> {
        Set(addresses.filter { isModuleAddress($0.address) }.map(\.name))
    }

    /// 模块 USB 私网地址固定为 192.168.225.2~254；用于识别 USB 网卡是否真的拿到了租约。
    static func isModuleAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets[0] == "192", octets[1] == "168", octets[2] == "225",
              let host = Int(octets[3]), (2...254).contains(host),
              String(host) == octets[3] else { return false }
        return true
    }

    static func resolve(timeout: TimeInterval = 0.35) -> NWInterface? {
        let names = moduleInterfaceNames(from: systemInterfaceAddresses())
        guard !names.isEmpty else {
            invalidate()
            return nil
        }

        let now = DispatchTime.now().uptimeNanoseconds
        cacheLock.lock()
        if now < cacheExpiresAt,
           let cachedInterface,
           names.contains(cachedInterface.name) {
            cacheLock.unlock()
            return cachedInterface
        }
        cacheLock.unlock()

        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resolved: NWInterface?
        monitor.pathUpdateHandler = { path in
            lock.lock()
            resolved = path.availableInterfaces.first { names.contains($0.name) }
            lock.unlock()
            semaphore.signal()
        }
        monitor.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        lock.lock()
        let result = resolved
        lock.unlock()

        cacheLock.lock()
        cachedInterface = result
        cacheExpiresAt = result == nil ? 0 : now + cacheLifetimeNanoseconds
        cacheLock.unlock()
        return result
    }

    /// USB 拔出或严格接口连接失败后立即丢弃缓存，避免下一次请求继续使用旧网卡对象。
    static func invalidate() {
        cacheLock.lock()
        cachedInterface = nil
        cacheExpiresAt = 0
        cacheLock.unlock()
    }

    private static func systemInterfaceAddresses() -> [NetworkInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetworkInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
            var numericAddress = ipv4.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &numericAddress, &buffer, socklen_t(buffer.count)) != nil else { continue }
            result.append(
                NetworkInterfaceAddress(
                    name: String(cString: item.pointee.ifa_name),
                    address: String(cString: buffer)
                )
            )
        }
        return result
    }
}

/// 本机 USB 网卡的地址状态。没有拿到 192.168.225.x 时，问题在 iPhone 的 DHCP，
/// 不在模块或 App；界面据此给出“手动配置以太网 IP”的可执行指引。
enum USBLinkAddressState: Equatable {
    case module(interface: String, address: String)
    case selfAssigned(interface: String, address: String)
    case missing
}

extension ModuleUSBInterfaceResolver {
    static func localLinkState() -> USBLinkAddressState {
        let addresses = systemInterfaceAddresses()
        if let item = addresses.first(where: { isModuleAddress($0.address) }) {
            return .module(interface: item.name, address: item.address)
        }
        // iOS 拿不到 DHCP 时会退回 169.254 自分配地址；以太网接口名通常是 en*。
        if let item = addresses.first(where: { $0.address.hasPrefix("169.254.") && $0.name.hasPrefix("en") }) {
            return .selfAssigned(interface: item.name, address: item.address)
        }
        return .missing
    }
}

private enum WiredInterfaceRoute {
    case exact(NWInterface)
    case type(NWInterface.InterfaceType)
    /// 不约束接口，由系统路由表决定；仅作为幂等请求的最后兜底。
    case system

    var description: String {
        switch self {
        case let .exact(interface): return "\(interface.name):\(interface.type)"
        case let .type(type): return String(describing: type)
        case .system: return "system"
        }
    }

    func matches(_ path: NWPath?) -> Bool {
        guard let path else { return false }
        switch self {
        case let .exact(interface):
            return path.availableInterfaces.contains { $0.name == interface.name }
        case let .type(type):
            return path.usesInterfaceType(type)
        case .system:
            return true
        }
    }
}

private enum WiredHTTPBody {
    case none
    case data(Data)
    case file(URL, UInt64)

    var length: UInt64 {
        switch self {
        case .none: return 0
        case let .data(data): return UInt64(data.count)
        case let .file(_, length): return length
        }
    }
}

/// 单次请求使用独立 TCP 连接和 `Connection: close`，避免熄屏恢复后复用已失效的 Wi-Fi 路径。
private final class WiredHTTPRequestOperation: @unchecked Sendable {
    private static let maximumResponseBytes = 32 * 1_024 * 1_024
    private static let uploadChunkBytes = 64 * 1_024

    private let request: URLRequest
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let body: WiredHTTPBody
    private let route: WiredInterfaceRoute
    private let queue: DispatchQueue
    private let continuation: CheckedContinuation<WiredHTTPResponse, Error>
    private let connection: NWConnection
    private var responseData = Data()
    private var uploadHandle: FileHandle?
    private var keepAlive: WiredHTTPRequestOperation?
    private var requestStarted = false
    private var finished = false

    init(
        request: URLRequest,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        body: WiredHTTPBody,
        route: WiredInterfaceRoute,
        queue: DispatchQueue,
        continuation: CheckedContinuation<WiredHTTPResponse, Error>
    ) {
        self.request = request
        self.host = host
        self.port = port
        self.body = body
        self.route = route
        self.queue = queue
        self.continuation = continuation

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // 优先绑定实际 USB ECM 接口；找不到接口名时才按接口类型约束。
        switch route {
        case let .exact(interface): parameters.requiredInterface = interface
        case let .type(type): parameters.requiredInterfaceType = type
        case .system: break
        }
        connection = NWConnection(host: host, port: port, using: parameters)
    }

    func start() {
        // NWConnection 的回调使用弱引用；请求结束前由操作自持有，避免局部变量离开作用域后提前释放。
        keepAlive = self
#if DEBUG
        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            print("[DJOneHub Network] route=\(self.route.description) status=\(path.status) reason=\(path.unsatisfiedReason) available=\(interfaces)")
        }
#endif
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.requestStarted else { return }
                guard self.route.matches(self.connection.currentPath) else {
                    self.finish(.failure(WiredHTTPError.wiredPathUnavailable))
                    return
                }
                self.requestStarted = true
                self.receiveNextChunk()
                self.sendRequest()
            case let .failed(error):
                self.finish(.failure(WiredHTTPError.connectionFailed(error.localizedDescription)))
#if DEBUG
            case let .waiting(error):
                print("[DJOneHub Network] route=\(self.route.description) waiting=\(error.localizedDescription)")
#endif
            case .cancelled:
                if !self.finished { self.finish(.failure(WiredHTTPError.connectionClosed)) }
            default:
                break
            }
        }
        connection.start(queue: queue)

        // 严格路径不匹配时连接可能一直 waiting；请求尚未发送，可安全交给上层决定是否回退。
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.finished, !self.requestStarted else { return }
            self.finish(.failure(WiredHTTPError.wiredPathUnavailable))
        }

        let timeout = max(1, request.timeoutInterval)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(.failure(WiredHTTPError.timedOut))
        }
    }

    /// 取消可能来自任意 Swift 并发执行器，统一回到连接队列完成清理和 continuation 恢复。
    func cancel() {
        queue.async { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    private func sendRequest() {
        do {
            let header = try makeHeader()
            let hasBody = body.length > 0
            connection.send(
                content: header,
                contentContext: .defaultStream,
                isComplete: !hasBody,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.finish(.failure(WiredHTTPError.sendFailed(error.localizedDescription)))
                    } else if hasBody {
                        self.sendBody()
                    }
                }
            )
        } catch {
            finish(.failure(error))
        }
    }

    private func makeHeader() throws -> Data {
        guard let url = request.url else { throw WiredHTTPError.invalidRequest }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            throw WiredHTTPError.invalidRequest
        }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        guard !path.contains("\r"), !path.contains("\n") else {
            throw WiredHTTPError.invalidRequest
        }

        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = "\(host):\(port.rawValue)"
        headers["Connection"] = "close"
        headers["Accept"] = "application/json"
        headers["Content-Length"] = String(body.length)

        var lines = ["\(method) \(path) HTTP/1.1"]
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
                  !value.contains("\r"), !value.contains("\n") else {
                throw WiredHTTPError.invalidRequest
            }
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")
        guard let data = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw WiredHTTPError.invalidRequest
        }
        return data
    }

    private func sendBody() {
        switch body {
        case .none:
            break
        case let .data(data):
            send(data, isFinal: true)
        case let .file(url, _):
            do {
                uploadHandle = try FileHandle(forReadingFrom: url)
                sendNextFileChunk()
            } catch {
                finish(.failure(WiredHTTPError.unreadableUpload))
            }
        }
    }

    private func sendNextFileChunk() {
        guard let uploadHandle else {
            finish(.failure(WiredHTTPError.unreadableUpload))
            return
        }
        do {
            let data = try uploadHandle.read(upToCount: Self.uploadChunkBytes) ?? Data()
            if data.isEmpty {
                // 文件长度已通过 Content-Length 声明，最后发送空 FIN 完成请求体。
                send(Data(), isFinal: true)
            } else {
                send(data, isFinal: false) { [weak self] in self?.sendNextFileChunk() }
            }
        } catch {
            finish(.failure(WiredHTTPError.unreadableUpload))
        }
    }

    private func send(_ data: Data, isFinal: Bool, completion: (() -> Void)? = nil) {
        connection.send(
            content: data,
            contentContext: .defaultStream,
            isComplete: isFinal,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(WiredHTTPError.sendFailed(error.localizedDescription)))
                } else {
                    completion?()
                }
            }
        )
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard self.responseData.count + data.count <= Self.maximumResponseBytes else {
                    self.finish(.failure(WiredHTTPError.responseTooLarge))
                    return
                }
                self.responseData.append(data)
            }
            if let error {
                // 模块执行 ATD 时偶尔用 RST 结束连接；若完整 HTTP 响应已经到达，应采用响应而非误报失败。
                if let response = try? WiredHTTPResponseParser.parse(self.responseData) {
                    self.finish(.success(response))
                } else {
                    self.finish(.failure(WiredHTTPError.receiveFailed(error.localizedDescription)))
                }
            } else if isComplete {
                do {
                    self.finish(.success(try WiredHTTPResponseParser.parse(self.responseData)))
                } catch {
                    self.finish(.failure(error))
                }
            } else {
                self.receiveNextChunk()
            }
        }
    }

    private func finish(_ result: Result<WiredHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        try? uploadHandle?.close()
        uploadHandle = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
        keepAlive = nil
    }

}

/// 独立解析 HTTP/1.1 响应，便于对 Go Agent 的定长和分块响应做无网络测试。
enum WiredHTTPResponseParser {
    static func parse(_ data: Data) throws -> WiredHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let headerText = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            throw WiredHTTPError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw WiredHTTPError.invalidResponse }
        let statusFields = statusLine.split(separator: " ", maxSplits: 2)
        guard statusFields.count >= 2,
              statusFields[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusFields[1]) else {
            throw WiredHTTPError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let encodedBody = Data(data[range.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(encodedBody)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard length >= 0, encodedBody.count >= length else {
                throw WiredHTTPError.incompleteResponse
            }
            body = Data(encodedBody.prefix(length))
        } else {
            body = encodedBody
        }
        return WiredHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        let lineBreak = Data("\r\n".utf8)
        var cursor = data.startIndex
        var decoded = Data()

        while cursor < data.endIndex {
            guard let sizeRange = data[cursor...].range(of: lineBreak),
                  let sizeLine = String(data: data[cursor..<sizeRange.lowerBound], encoding: .ascii),
                  let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw WiredHTTPError.invalidResponse
            }
            cursor = sizeRange.upperBound
            if size == 0 { return decoded }
            guard size > 0,
                  let chunkEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex),
                  data.distance(from: chunkEnd, to: data.endIndex) >= 2,
                  data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)] == lineBreak else {
                throw WiredHTTPError.incompleteResponse
            }
            decoded.append(data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
        throw WiredHTTPError.incompleteResponse
    }
}

private enum WiredHTTPError: LocalizedError {
    case invalidRequest
    case wiredPathUnavailable
    case connectionFailed(String)
    case connectionClosed
    case sendFailed(String)
    case receiveFailed(String)
    case timedOut
    case responseTooLarge
    case invalidResponse
    case incompleteResponse
    case unreadableUpload

    var isInterfaceFailure: Bool {
        switch self {
        case .wiredPathUnavailable, .connectionFailed, .connectionClosed, .timedOut:
            return true
        case .invalidRequest, .sendFailed, .receiveFailed, .responseTooLarge,
             .invalidResponse, .incompleteResponse, .unreadableUpload:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "模块请求格式无效"
        case .wiredPathUnavailable: return "未找到模块 USB 以太网路径"
        case let .connectionFailed(message): return "模块有线连接失败：\(message)"
        case .connectionClosed: return "模块有线连接已关闭"
        case let .sendFailed(message): return "模块请求发送失败：\(message)"
        case let .receiveFailed(message): return "模块响应接收失败：\(message)"
        case .timedOut: return "模块有线请求超时"
        case .responseTooLarge: return "模块响应超过安全大小限制"
        case .invalidResponse: return "模块代理返回了无效 HTTP 响应"
        case .incompleteResponse: return "模块代理返回的 HTTP 响应不完整"
        case .unreadableUpload: return "无法读取模块更新包"
        }
    }
}

/// 诊断探测的节流规则；独立为纯函数，防止前台生命周期与模块轮询重复触发公网请求。
enum NetworkDiagnosticProbePolicy {
    static let minimumInterval: TimeInterval = 10

    static func shouldStart(now: Date, lastStartedAt: Date?, isRunning: Bool) -> Bool {
        guard !isRunning else { return false }
        guard let lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= minimumInterval
    }
}

private struct NetworkDiagnosticInterfaceSnapshot: Codable, Sendable {
    let name: String
    let type: String
}

private struct NetworkDiagnosticAddressSnapshot: Codable, Sendable {
    let name: String
    let family: String
    let address: String
}

private struct NetworkDiagnosticPathSnapshot: Codable, Sendable {
    let status: String
    let unsatisfiedReason: String
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let usedInterfaceTypes: [String]
    let availableInterfaces: [NetworkDiagnosticInterfaceSnapshot]
    let addresses: [NetworkDiagnosticAddressSnapshot]

    init(path: NWPath) {
        status = String(describing: path.status)
        unsatisfiedReason = String(describing: path.unsatisfiedReason)
        supportsDNS = path.supportsDNS
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        let knownTypes: [NWInterface.InterfaceType] = [.wiredEthernet, .other, .wifi, .cellular, .loopback]
        usedInterfaceTypes = knownTypes
            .filter(path.usesInterfaceType)
            .map(Self.interfaceTypeName)
        availableInterfaces = path.availableInterfaces.map {
            NetworkDiagnosticInterfaceSnapshot(name: $0.name, type: Self.interfaceTypeName($0.type))
        }
        addresses = Self.captureAddresses()
    }

    private static func interfaceTypeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wiredEthernet: return "wiredEthernet"
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    /// 记录接口地址用于确认 USB ECM 是否同时获得 IPv4/IPv6；不读取 SSID、电话号码或 SIM 标识。
    private static func captureAddresses() -> [NetworkDiagnosticAddressSnapshot] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetworkDiagnosticAddressSnapshot] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let addressLength: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                addressLength,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            result.append(
                NetworkDiagnosticAddressSnapshot(
                    name: String(cString: item.pointee.ifa_name),
                    family: family == AF_INET ? "IPv4" : "IPv6",
                    address: String(cString: host)
                )
            )
        }
        return result.sorted {
            ($0.name, $0.family, $0.address) < ($1.name, $1.family, $1.address)
        }
    }
}

private struct NetworkDiagnosticProbeResult: Codable, Sendable {
    let target: String
    let transport: String
    let succeeded: Bool
    let statusCode: Int?
    let finalURL: String?
    let responseBytes: Int?
    let durationMilliseconds: Int
    let errorDomain: String?
    let errorCode: Int?
    let errorDescription: String?
}

private struct NetworkDiagnosticEvent: Codable, Sendable {
    let schemaVersion: Int
    let recordedAt: Date
    let kind: String
    let detail: String?
    let path: NetworkDiagnosticPathSnapshot?
    let probes: [NetworkDiagnosticProbeResult]?
}

/// 将“只用模块上网”期间的系统路径与请求结果保存到 App 沙盒，重连 Mac 后可离线导出。
actor NetworkDiagnosticRecorder {
    static let shared = NetworkDiagnosticRecorder()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.jieden.djonehub.network-diagnostic")
    private var started = false
    private var latestPath: NetworkDiagnosticPathSnapshot?
    private var probeIsRunning = false
    private var lastProbeStartedAt: Date?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let snapshot = NetworkDiagnosticPathSnapshot(path: path)
            Task { await NetworkDiagnosticRecorder.shared.recordPath(snapshot) }
        }
        monitor.start(queue: monitorQueue)
        append(kind: "diagnostic_started", detail: "诊断版本已启动")
    }

    func recordLifecycle(_ state: String) {
        append(kind: "app_lifecycle", detail: state)
    }

    func recordModuleOnline() async {
        append(kind: "module_online", detail: "模块控制接口已响应")
        let now = Date()
        guard NetworkDiagnosticProbePolicy.shouldStart(
            now: now,
            lastStartedAt: lastProbeStartedAt,
            isRunning: probeIsRunning
        ) else { return }

        probeIsRunning = true
        lastProbeStartedAt = now
        append(kind: "probe_started", detail: "开始检查 Apple、米家与系统联网判定")
        let results = await Self.runProbes()
        probeIsRunning = false
        append(kind: "probe_completed", detail: "公网探测完成", probes: results)
    }

    func recordModuleOffline(error: String) {
        append(kind: "module_offline", detail: error)
    }

    private func recordPath(_ path: NetworkDiagnosticPathSnapshot) {
        latestPath = path
        append(kind: "path_changed", detail: nil, path: path)
    }

    private static func runProbes() async -> [NetworkDiagnosticProbeResult] {
        let targets = [
            "https://captive.apple.com/hotspot-detect.html",
            "https://apps.apple.com/",
            "https://bag.itunes.apple.com/",
            "https://api.io.mi.com/",
            "https://home.mi.com/"
        ]

        var results = await withTaskGroup(of: NetworkDiagnosticProbeResult.self) { group in
            for target in targets {
                group.addTask { await probeHTTPS(target) }
            }
            var collected: [NetworkDiagnosticProbeResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        results.append(await probeModuleBoundHTTP())
        return results.sorted { $0.target < $1.target }
    }

    /// 使用系统 URLSession 复现普通 App 的联网路径；HTTP 状态非 2xx 仍表示 DNS、TCP 与 TLS 已完成。
    private static func probeHTTPS(_ target: String) async -> NetworkDiagnosticProbeResult {
        let startedAt = Date()
        guard let url = URL(string: target) else {
            return failureResult(target: target, transport: "URLSession", startedAt: startedAt, error: URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("DJOneHub-Network-Diagnostic/1", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return NetworkDiagnosticProbeResult(
                target: target,
                transport: "URLSession",
                succeeded: http != nil,
                statusCode: http?.statusCode,
                finalURL: response.url?.absoluteString,
                responseBytes: data.count,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                errorDomain: nil,
                errorCode: nil,
                errorDescription: nil
            )
        } catch {
            return failureResult(target: target, transport: "URLSession", startedAt: startedAt, error: error)
        }
    }

    /// 直接绑定模块 USB 接口访问 Apple 的明文探测页，用来区分系统选路失败与模块转发失败。
    private static func probeModuleBoundHTTP() async -> NetworkDiagnosticProbeResult {
        let target = "http://captive.apple.com/hotspot-detect.html"
        let startedAt = Date()
        guard let url = URL(string: target) else {
            return failureResult(target: target, transport: "NWConnection-USB", startedAt: startedAt, error: URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let response = try await WiredHTTPTransport().send(request)
            return NetworkDiagnosticProbeResult(
                target: target,
                transport: "NWConnection-USB",
                succeeded: (200..<400).contains(response.statusCode),
                statusCode: response.statusCode,
                finalURL: target,
                responseBytes: response.body.count,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                errorDomain: nil,
                errorCode: nil,
                errorDescription: nil
            )
        } catch {
            return failureResult(target: target, transport: "NWConnection-USB", startedAt: startedAt, error: error)
        }
    }

    private static func failureResult(
        target: String,
        transport: String,
        startedAt: Date,
        error: Error
    ) -> NetworkDiagnosticProbeResult {
        let diagnosticError = error as NSError
        return NetworkDiagnosticProbeResult(
            target: target,
            transport: transport,
            succeeded: false,
            statusCode: nil,
            finalURL: nil,
            responseBytes: nil,
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            errorDomain: diagnosticError.domain,
            errorCode: diagnosticError.code,
            errorDescription: diagnosticError.localizedDescription
        )
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func append(
        kind: String,
        detail: String?,
        path: NetworkDiagnosticPathSnapshot? = nil,
        probes: [NetworkDiagnosticProbeResult]? = nil
    ) {
        let event = NetworkDiagnosticEvent(
            schemaVersion: 1,
            recordedAt: Date(),
            kind: kind,
            detail: detail,
            path: path ?? latestPath,
            probes: probes
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(event)
            line.append(0x0A)

            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DJOneHubDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("network-diagnostic.jsonl")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
#if DEBUG
            print("[DJOneHub Diagnostic] 写入诊断日志失败：\(error.localizedDescription)")
#endif
        }
    }
}

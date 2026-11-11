import Foundation

/// 统一封装模块代理 HTTP API；接口路径与 DJOneHub Mac 版保持一致。
struct DJOneHubAPI: Sendable {
    let baseURL: URL
    private let transport: WiredHTTPTransport

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // 模块日志与历史记录可能混用带/不带小数秒的 RFC3339 时间。
        // Foundation 的默认 .iso8601 不能稳定同时覆盖这两种格式。
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let regular = ISO8601DateFormatter()
            regular.formatOptions = [.withInternetDateTime]
            if let date = regular.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析 RFC3339 时间：\(raw)"
            )
        }
        return decoder
    }

    init(baseURL: URL = URL(string: "http://192.168.225.1:7575/")!) {
        precondition(Self.isAllowedLocalURL(baseURL), "模块代理地址必须是本地 HTTP 地址")
        self.baseURL = baseURL
        // URLSession 无法公开绑定接口；专用传输器确保 Wi-Fi/VPN 不会截走模块私网请求。
        self.transport = WiredHTTPTransport()
    }

    /// App 从休眠恢复时丢弃旧 USB 接口对象；正在执行的请求由其所属 Task 负责取消。
    func resetLocalConnectionState() {
        transport.resetConnectionState()
    }

    /// 限制高权限控制接口只能指向环回或私有网络，避免误发到公网主机。
    private static func isAllowedLocalURL(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        guard host.hasPrefix("172."), let second = Int(host.split(separator: ".").dropFirst().first ?? "") else {
            return false
        }
        return (16...31).contains(second)
    }

    // MARK: 通话与短信

    func callStatus() async throws -> CallStatus { try await get("api/calls/status") }
    /// 首次不携带修订号以立即取得快照；后续请求在模块状态变化或心跳时返回。
    func waitForCallEvent(after revision: UInt64?) async throws -> CallEventEnvelope {
        var components = URLComponents(
            url: endpoint("api/calls/events"),
            resolvingAgainstBaseURL: false
        )
        if let revision {
            components?.queryItems = [URLQueryItem(name: "after", value: String(revision))]
        }
        guard let url = components?.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 模块最长阻塞 20 秒，额外余量用于 USB 重枚举和 HTTP 收尾。
        request.timeoutInterval = 26
        return try await decoded(request)
    }
    func messages() async throws -> [SMSMessage] { try await get("api/sms") }
    func acknowledgeCallHistory(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await post("api/calls/history/ack", ["ids": ids])
    }
    func acknowledgeMessages(ids: [String]) async throws {
        let validIDs = ids.filter { !$0.isEmpty }
        guard !validIDs.isEmpty else { return }
        try await post("api/sms/ack", ["ids": validIDs])
    }
    func smsStatus() async throws -> SMSStatus { try await get("api/sms/status") }
    func simIdentity() async throws -> SIMIdentity { try await get("api/sim/identity") }

    func dial(number: String) async throws {
        do {
            try await post("api/calls/dial", ["number": number])
        } catch {
            let originalError = error
            // ATD 是非幂等操作：响应连接被模块重置后只能查询状态确认，绝对不能自动重发。
            for delay in [0.25, 0.5, 1.0, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard let status = try? await callStatus(), let call = status.active else { continue }
                let expectedState = ["dialing", "alerting", "active", "held"].contains(call.state)
                let expectedNumber = call.number?.isEmpty != false || call.number == number
                if call.direction == "outgoing", expectedState, expectedNumber { return }
            }
            throw originalError
        }
    }
    func answerCall() async throws { try await post("api/calls/answer", EmptyBody()) }
    func rejectCall() async throws -> RejectResponse { try await postDecoded("api/calls/reject", EmptyBody()) }
    func hangupCall() async throws { try await post("api/calls/hangup", EmptyBody()) }
    func sendDTMF(_ digit: String) async throws { try await post("api/calls/dtmf", ["digit": digit]) }
    func setAudioMuted(_ muted: Bool) async throws { try await post("api/calls/audio/mute", ["muted": muted]) }
    func setCallRecording(_ recording: Bool) async throws -> CallRecordingResponse {
        try await postDecoded("api/calls/audio/record", ["action": recording ? "start" : "stop"])
    }
    func setAudioHostEnabled(_ enabled: Bool) async throws {
        // 启动/停止接口只负责登记状态，不应让控制轮询被长时间阻塞。
        try await post(
            "api/calls/audio/host/register",
            ["enabled": enabled],
            timeout: enabled ? 2 : 8
        )
    }
    func warmAudioHost() async throws {
        try await post("api/calls/audio/host/warmup", EmptyBody())
    }
    func audioHostConfig() async throws -> MaVoAudioHostConfig { try await get("api/calls/audio/host/config") }

    func sendSMS(to phone: String, message: String) async throws -> SMSSendResult {
        try await postDecoded("api/sms/send", ["phone": phone, "message": message], timeout: 12)
    }
    func refreshSMS() async throws { try await post("api/sms/refresh", EmptyBody()) }
    func clearModuleSMS() async throws { try await post("api/sms/clear-module", EmptyBody()) }
    func setSMSAutoCleanup(_ enabled: Bool) async throws {
        try await send("PATCH", "api/sms/settings", ["auto_cleanup_me": enabled])
    }

    // MARK: 状态、网络、定位与调试

    func modemStatus() async throws -> ModemStatus { try await get("api/status") }
    func networkTraffic() async throws -> NetworkTrafficSnapshot { try await get("api/network/traffic") }
    /// 只读取模块公开的系统温度与供电指标；不改变模块运行状态。
    func systemPower() async throws -> SystemPowerStatus { try await get("api/system/power") }
    func cellularPolicy() async throws -> CellularPolicyStatus { try await get("api/network/cellular-policy") }
    func setCellularPolicy(forceOff: Bool) async throws -> CellularPolicyStatus {
        try await postDecoded("api/network/cellular-policy", ["force_off": forceOff])
    }
    /// 读取上网方式（wifi：手机上网走 Wi-Fi；module：手机使用模块 4G）。
    func internetMode() async throws -> InternetModeStatus { try await get("api/network/internet-mode") }
    func setInternetMode(_ mode: String) async throws -> InternetModeStatus {
        try await postDecoded("api/network/internet-mode", ["mode": mode], timeout: 10)
    }
    func check4GRoute() async throws -> NetworkCheckResult { try await postDecoded("api/network/check-4g", EmptyBody()) }
    func checkProxyRoute() async throws -> NetworkCheckResult { try await postDecoded("api/network/check-proxy", EmptyBody()) }
    func rebootModule() async throws { try await post("api/network/reboot-module", EmptyBody()) }
    func networkDiagnostic() async throws -> NetworkDiagnostic { try await get("api/network") }
    func usbProfile() async throws -> USBProfileStatus { try await get("api/usb/profile", timeout: 2) }
    func setUSBProfile(_ mode: String) async throws -> USBProfileStatus {
        try await postDecoded("api/usb/profile", ["mode": mode], timeout: 3)
    }
    func gpsStatus() async throws -> GPSStatus { try await get("api/gps") }
    func gpsStart() async throws -> GPSControlResponse { try await postDecoded("api/gps/start", EmptyBody()) }
    func gpsStop() async throws -> GPSControlResponse { try await postDecoded("api/gps/stop", EmptyBody()) }
    func gpsRefresh() async throws -> GPSFixSummary { try await postDecoded("api/gps/refresh", EmptyBody()) }
    func executeAT(_ command: String) async throws -> ATResult { try await postDecoded("api/at", ["command": command]) }

    // MARK: eSIM、模块初始化与语音运行时

    func esimOverview() async throws -> ESIMOverview { try await get("api/esim") }
    func esimHealth() async throws -> ESIMHealth { try await get("api/esim/health") }
    func esimNotes() async throws -> [String: ESIMNote] {
        let response: ESIMNotesResponse = try await get("api/esim/notes")
        return response.notes
    }
    func switchESIM(iccid: String, aid: String) async throws -> ESIMSwitchResult {
        try await postDecoded("api/esim/switch", ["iccid": iccid, "aid": aid])
    }
    func renameESIMProfile(iccid: String, aid: String, name: String) async throws {
        try await send("PATCH", "api/esim/profile", ["iccid": iccid, "aid": aid, "name": name])
    }
    func deleteESIMProfile(iccid: String, aid: String) async throws {
        try await send("DELETE", "api/esim/profile", ["iccid": iccid, "aid": aid])
    }
    func saveESIMNote(iccid: String, label: String, phone: String, tags: String) async throws {
        try await post("api/esim/notes", ["iccid": iccid, "label": label, "phone": phone, "tags": tags])
    }
    func probeESIMPhonebook() async throws -> ESIMPhonebookProbe {
        try await postDecoded("api/esim/phonebook/probe", EmptyBody())
    }
    func downloadESIMProfile(smdp: String, matchingID: String, confirmationCode: String, imei: String, aid: String) async throws -> ESIMDownloadResult {
        try await postDecoded(
            "api/esim/download",
            ["smdp": smdp, "matching_id": matchingID, "confirmation_code": confirmationCode, "imei": imei, "aid": aid],
            timeout: 180
        )
    }
    func moduleSetupStatus() async throws -> ModuleSetupStatus { try await get("api/module/setup") }
    func initializeModule() async throws -> ModuleSetupStatus {
        try await postDecoded("api/module/setup", ["confirm": true], timeout: 120)
    }
    func voiceRuntimeStatus() async throws -> VoiceRuntimeStatus { try await get("api/voice/status") }
    func provisionVoiceRuntime() async throws -> VoiceRuntimeStatus {
        try await postDecoded("api/voice/provision", ["confirm": true], timeout: 180)
    }
    func moduleUpdateStatus() async throws -> ModuleUpdateStatus {
        try await get("api/system/update")
    }

    /// 上传 App 内置的已签名模块更新包；使用文件流避免把 6 MB 运行时一次性放入内存。
    func uploadModuleUpdate(from fileURL: URL) async throws -> ModuleUpdateResult {
        var request = URLRequest(url: endpoint("api/system/update"))
        request.httpMethod = "POST"
        request.setValue("application/vnd.djonehub.update+gzip", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        let response = try await transport.send(request, uploadFileURL: fileURL)
        try Self.requireSuccess(response)
        return try Self.decode(ModuleUpdateResult.self, from: response.body)
    }

    /// iPad 直连模式下，“完全退出”等价为停止模块内代理；模块重启后由 init 自动恢复。
    func shutdownModuleAgent() async throws {
        try await post("api/service/shutdown", ["confirm": true])
    }

    // MARK: HTTP 公共实现

    private func endpoint(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    private func get<Response: Decodable>(_ path: String, timeout: TimeInterval = 6) async throws -> Response {
        var request = URLRequest(url: endpoint(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        return try await decoded(request)
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body, timeout: TimeInterval = 8) async throws {
        _ = try await raw(method: "POST", path: path, body: body, timeout: timeout)
    }

    private func postDecoded<Response: Decodable, Body: Encodable>(
        _ path: String,
        _ body: Body,
        timeout: TimeInterval = 8
    ) async throws -> Response {
        let data = try await raw(method: "POST", path: path, body: body, timeout: timeout)
        return try Self.decode(Response.self, from: data)
    }

    private func send<Body: Encodable>(_ method: String, _ path: String, _ body: Body) async throws {
        _ = try await raw(method: method, path: path, body: body, timeout: 10)
    }

    private func raw<Body: Encodable>(method: String, path: String, body: Body, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout
        let response = try await transport.send(request)
        try Self.requireSuccess(response)
        return response.body
    }

    private func decoded<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let response = try await transport.send(request)
        try Self.requireSuccess(response)
        return try Self.decode(Response.self, from: response.body)
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            let detail: String
            if let decodingError = error as? DecodingError {
                detail = decodingError.diagnosticDescription
            } else {
                detail = error.localizedDescription
            }
            throw APIError.unreadablePayload("模块代理返回的数据无法识别：\(detail)")
        }
    }

    private static func requireSuccess(_ response: WiredHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? makeDecoder().decode(APIErrorPayload.self, from: response.body))?.error
            throw APIError.http(response.statusCode, message)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case unreadablePayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "模块代理返回了无效响应"
        case let .http(status, message): return message?.isEmpty == false ? message : "请求失败（HTTP \(status)）"
        case let .unreadablePayload(message): return message
        }
    }
}

private struct APIErrorPayload: Decodable { let error: String? }
private struct EmptyBody: Encodable {}

private extension DecodingError {
    /// 把编码路径带给用户，便于判断是模块返回字段变化还是传输内容被截断。
    var diagnosticDescription: String {
        let path: [CodingKey]
        let description: String
        switch self {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            path = context.codingPath
            description = context.debugDescription
        @unknown default:
            return localizedDescription
        }
        let location = path.map(\.stringValue).joined(separator: ".")
        return location.isEmpty ? description : "\(location)：\(description)"
    }
}

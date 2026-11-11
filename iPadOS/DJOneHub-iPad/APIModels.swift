import Foundation

// MARK: - 通话与短信

/// 模块侧返回的单次通话记录。
struct CallRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let index: Int
    let direction: String
    let state: String
    let number: String?
    let startedAt: Date
    let updatedAt: Date
    let endedAt: Date?
    let missed: Bool

    enum CodingKeys: String, CodingKey {
        case id, index, direction, state, number, missed
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
    }
}

/// 通话轮询结果；额外音频诊断字段由专门接口读取。
struct CallStatus: Codable, Sendable {
    let active: CallRecord?
    let history: [CallRecord]?
    let polling: Bool
    let eventDriven: Bool?
    let pollIntervalSeconds: Int
    let lastPollError: String

    enum CodingKeys: String, CodingKey {
        case active, history, polling
        case eventDriven = "event_driven"
        case pollIntervalSeconds = "poll_interval_s"
        case lastPollError = "last_poll_error"
    }
}

/// 模块本地事件桥的单次响应；修订号用于断线续接和去重。
struct CallEventEnvelope: Codable, Sendable {
    let revision: UInt64
    let active: CallRecord?
    let heartbeat: Bool
}

enum SMSDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

struct SMSMessage: Codable, Equatable, Sendable, Identifiable {
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    /// 模块交付队列的确认标识；仅用于清理模块副本，不影响本地短信去重。
    var deliveryID: String?
    /// 模块只上报收到的短信；已发送短信由 App 在发送成功后写入本机历史。
    /// 保持可选以兼容没有 `direction` 字段的旧模块和既有本地记录。
    var direction: SMSDirection?

    var isOutgoing: Bool { direction == .outgoing }

    /// 后端短信没有独立 ID，以稳定字段组合生成列表标识。
    var id: String { "\(sender)\u{0}\(timestamp.timeIntervalSince1970)\u{0}\(content)\u{0}\(direction?.rawValue ?? SMSDirection.incoming.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case sender, content, code, timestamp, direction
        case deliveryID = "delivery_id"
    }
}

struct SMSStatus: Codable, Sendable {
    let autoCleanupME: Bool
    let count: Int?
    let lastPollError: String?

    enum CodingKeys: String, CodingKey {
        case count
        case autoCleanupME = "auto_cleanup_me"
        case lastPollError = "last_poll_error"
    }
}

struct RejectResponse: Codable, Sendable { let rejected: Bool }
struct SMSSendResult: Codable, Sendable { let sent: Bool; let segments: Int? }
struct CallRecordingResponse: Codable, Sendable { let recording: Bool; let path: String? }
struct SIMIdentity: Codable, Sendable {
    let phoneNumber: String
    enum CodingKeys: String, CodingKey { case phoneNumber = "phone_number" }
}

// MARK: - 模块、网络与定位

struct ModemStatus: Codable, Sendable {
    let imei: String?
    let firmware: String?
    let iccid: String?
    let imsi: String?
    let operatorName: String?
    let simInserted: Bool?
    let signalDBM: Int?
    let networkMode: String?
    let radioBand: String?
    let registrationText: String?

    enum CodingKeys: String, CodingKey {
        case imei, firmware, iccid, imsi
        case operatorName = "operator"
        case simInserted = "sim_inserted"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
        case radioBand = "radio_band"
        case registrationText = "reg_status_text"
    }
}

struct NetworkTrafficSnapshot: Codable, Sendable {
    let available: Bool
    let interface: String?
    let rxBytes: UInt64
    let txBytes: UInt64
    let sessionRX: UInt64
    let sessionTX: UInt64
    let sessionTotal: UInt64
    let sampledAtMS: Int64
    let error: String?

    enum CodingKeys: String, CodingKey {
        case available, interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case sessionRX = "session_rx_bytes"
        case sessionTX = "session_tx_bytes"
        case sessionTotal = "session_total_bytes"
        case sampledAtMS = "sampled_at_ms"
    }
}

/// 模块从只读 Linux sysfs 接口采集的电源与温度数据。
/// 不包含任何调频、断电或风扇控制命令，避免监测功能干扰通话。
struct SystemPowerStatus: Codable, Sendable {
    let supported: Bool
    let readings: [SystemPowerReading]
    let sampledAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case supported, readings
        case sampledAtMS = "sampled_at_ms"
    }
}

struct SystemPowerReading: Codable, Sendable, Identifiable {
    let kind: String
    let name: String
    let path: String
    let voltageV: Double?
    let currentA: Double?
    let powerW: Double?
    let temperatureC: Double?
    let capacityPercent: Int?
    let online: Bool?
    let status: String?

    var id: String { "\(kind):\(path)" }

    enum CodingKeys: String, CodingKey {
        case kind, name, path, online, status
        case voltageV = "voltage_v"
        case currentA = "current_a"
        case powerW = "power_w"
        case temperatureC = "temperature_c"
        case capacityPercent = "capacity_percent"
    }
}

struct CellularPolicyStatus: Codable, Sendable {
    let forceOff: Bool
    let services: [String]?
    enum CodingKeys: String, CodingKey { case forceOff = "force_off"; case services }
}

/// 上网方式状态；GET 与 POST 共用。applied=false 表示本次未能立即生效（需重新插拔 USB）。
struct InternetModeStatus: Codable, Sendable {
    let supported: Bool?
    let mode: String
    let options: [String]?
    let previous: String?
    let applied: Bool?
    let message: String?
}

struct USBProfileStatus: Codable, Sendable {
    let mode: String
    let uacEnabled: Bool
    let configuration: String
    let needsReconnect: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case mode, configuration, message
        case uacEnabled = "uac_enabled"
        case needsReconnect = "needs_reconnect"
    }
}

struct NetworkCheckResult: Codable, Sendable {
    let ok: Bool
    let summary: String?
    let detail: String?
}

struct GPSStatus: Codable, Sendable {
    let enabled: Bool
    let lastFix: GPSFixSummary?
    let lastError: String?
    enum CodingKeys: String, CodingKey {
        case enabled
        case lastFix = "last_fix"
        case lastError = "last_error"
    }
}

struct GPSFixSummary: Codable, Sendable {
    let latitude: String?
    let longitude: String?
    let hdop: String
    let satellites: String
}

struct GPSControlResponse: Codable, Sendable {
    let enabled: Bool
    let lastFix: GPSFixSummary?
    enum CodingKeys: String, CodingKey { case enabled; case lastFix = "last_fix" }
}

struct ATResult: Codable, Sendable { let response: String }

// MARK: - eSIM

struct ESIMOverview: Codable, Sendable {
    let cardType: String?
    let message: String?
    let chipInfo: ESIMChipInfo?
    let profiles: [ESIMProfileGroup]?

    enum CodingKeys: String, CodingKey {
        case message, profiles
        case cardType = "card_type"
        case chipInfo = "chip_info"
    }
}

struct ESIMChipInfo: Codable, Sendable {
    let skuName: String?
    let serialNumber: String?
    let firmware: String?
    let eids: [ESIMEID]?

    enum CodingKeys: String, CodingKey {
        case firmware, eids
        case skuName = "sku_name"
        case serialNumber = "serial_number"
    }
}

struct ESIMEID: Codable, Sendable, Identifiable {
    let eid: String?
    let aid: String?
    let freeNvram: String?
    let firmware: String?
    let specGuess: String?

    var id: String { eid ?? aid ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case eid, aid, firmware
        case freeNvram = "free_nvram"
        case specGuess = "spec_guess"
    }
}

struct ESIMProfileGroup: Codable, Sendable {
    let eid: String?
    let aidHex: String?
    let profiles: [ESIMProfile]?
    enum CodingKeys: String, CodingKey { case eid, profiles; case aidHex = "aid_hex" }
}

struct ESIMProfile: Codable, Sendable, Identifiable {
    let iccid: String?
    let name: String?
    let serviceProviderName: String?
    let state: Int?
    let stateText: String?

    var id: String { iccid ?? name ?? UUID().uuidString }
    var enabled: Bool { state == 1 }
    var displayName: String { name ?? serviceProviderName ?? iccid ?? "未命名 Profile" }

    enum CodingKeys: String, CodingKey {
        case iccid, name, state
        case serviceProviderName = "service_provider_name"
        case stateText = "state_text"
    }
}

struct ESIMHealth: Codable, Sendable {
    let ok: Bool?
    let message: String?
    let activeProfile: ESIMProfile?
    let moduleICCID: String?
    let registration: String?
    let registered: Bool?
    let signalDBM: Int?
    let networkMode: String?

    enum CodingKeys: String, CodingKey {
        case ok, message, registration, registered
        case activeProfile = "active_profile"
        case moduleICCID = "module_iccid"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
    }
}

struct ESIMSwitchResult: Codable, Sendable {
    let switchAccepted: Bool?
    let phase: String?
    let targetICCID: String?
    let recoveryPending: Bool?
    let moduleRebootRequested: Bool?
    let reconnectWaitSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case phase
        case switchAccepted = "switch_accepted"
        case targetICCID = "target_iccid"
        case recoveryPending = "recovery_pending"
        case moduleRebootRequested = "module_reboot_requested"
        case reconnectWaitSeconds = "reconnect_wait_seconds"
    }
}

struct ESIMNote: Codable, Sendable { let label: String?; let phone: String?; let tags: String? }
struct ESIMNotesResponse: Codable, Sendable { let notes: [String: ESIMNote] }
struct ESIMDownloadResult: Codable, Sendable { let message: String? }

struct ESIMPhonebookProbe: Codable, Sendable {
    let storageSupported: Bool?
    let storageSelected: Bool?
    let readSupported: Bool?
    let writeSupported: Bool?
    let storageStatus: String?

    enum CodingKeys: String, CodingKey {
        case storageSupported = "storage_supported"
        case storageSelected = "storage_selected"
        case readSupported = "read_supported"
        case writeSupported = "write_supported"
        case storageStatus = "storage_status"
    }
}

// MARK: - 诊断与语音运行时

struct ModuleDebugSnapshot: Codable, Sendable {
    let debug: ModuleDebugBufferStatus
    let agent: ModuleDebugAgentStatus
    let at: ModuleDebugATStatus
    let usb: [String: String]
    let traffic: ModuleDebugTrafficStatus
    let modem: ModemStatus
    let calls: ModuleDebugCallStatus
    let sms: ModuleDebugSMSStatus
    let voice: VoiceRuntimeStatus
    let events: [ModuleDebugEvent]
}

struct ModuleDebugBufferStatus: Codable, Sendable {
    let latestSequence: UInt64
    let returnedEvents: Int
    let storedBytes: Int
    let maxEvents: Int
    let maxStoredBytes: Int

    enum CodingKeys: String, CodingKey {
        case latestSequence = "latest_sequence"
        case returnedEvents = "returned_events"
        case storedBytes = "stored_bytes"
        case maxEvents = "max_events"
        case maxStoredBytes = "max_stored_bytes"
    }
}

struct ModuleDebugAgentStatus: Codable, Sendable {
    let version: String
    let uptimeSeconds: Int
    let goroutines: Int
    let heapBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case version, goroutines
        case uptimeSeconds = "uptime_seconds"
        case heapBytes = "heap_bytes"
    }
}

struct ModuleDebugATStatus: Codable, Sendable {
    let device: String
    let lastSuccessAt: String?
    let consecutiveFailures: Int
    let reopenCount: Int

    enum CodingKeys: String, CodingKey {
        case device
        case lastSuccessAt = "last_success_at"
        case consecutiveFailures = "consecutive_failures"
        case reopenCount = "reopen_count"
    }
}

struct ModuleDebugTrafficStatus: Codable, Sendable {
    let interface: String?
    let rxBytes: UInt64?
    let txBytes: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
    }
}

struct ModuleDebugCallStatus: Codable, Sendable {
    let active: CallRecord?
    let historyCount: Int
    let eventDriven: Bool
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case active
        case historyCount = "history_count"
        case eventDriven = "event_driven"
        case lastError = "last_error"
    }
}

struct ModuleDebugSMSStatus: Codable, Sendable {
    let count: Int
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case count
        case lastError = "last_error"
    }
}

struct ModuleDebugEvent: Codable, Sendable, Identifiable {
    let sequence: UInt64
    let timestamp: String
    let category: String
    let direction: String?
    let summary: String
    let payload: String?
    let fields: [String: String]?

    var id: UInt64 { sequence }
}

struct NetworkDiagnostic: Codable, Sendable {
    let usbnetMode: String?
    let usbcfg: String?
    let pdpContexts: [PDPContext]?
    let activeContexts: [Int]?
    let pdpAddresses: [String]?
    let interfaces: [NetworkInterface]?
    let defaultRoute: NetworkDefaultRoute?
    let usbNetworkPresent: Bool
    let usbDevice: USBDeviceStatus?
    let errors: [String: String]?

    enum CodingKeys: String, CodingKey {
        case usbcfg, errors
        case usbnetMode = "usbnet_mode"
        case pdpContexts = "pdp_contexts"
        case activeContexts = "active_contexts"
        case pdpAddresses = "pdp_addresses"
        // 后端为兼容 Mac 版保留了旧字段名。
        case interfaces = "mac_interfaces"
        case defaultRoute = "default_route"
        case usbNetworkPresent = "usb_network_present"
        case usbDevice = "usb_device"
    }
}

struct PDPContext: Codable, Sendable { let id: Int?; let pdn: String?; let apn: String? }
struct NetworkInterface: Codable, Sendable {
    let name: String?; let status: String?; let ipv4: String?; let mac: String?; let kind: String?
}
struct NetworkDefaultRoute: Codable, Sendable { let interface: String?; let gateway: String? }
struct USBDeviceStatus: Codable, Sendable {
    let vendor: String?; let product: String?; let vendorID: String?; let productID: String?; let mode: String?
    enum CodingKeys: String, CodingKey {
        case vendor, product, mode
        case vendorID = "vendor_id"
        case productID = "product_id"
    }
}

struct ModuleSetupStatus: Codable, Sendable {
    let state: String
    let summary: String
    let detail: String?
    let canInitialize: Bool
    let requiresConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case state, summary, detail
        case canInitialize = "can_initialize"
        case requiresConfirmation = "requires_confirmation"
    }
}

struct VoiceRuntimeStatus: Codable, Sendable {
    let ready: Bool
    let runtimeInstalled: Bool
    let runtimeSource: String?
    let runtimeDetail: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case ready
        case runtimeInstalled = "runtime_installed"
        case runtimeSource = "runtime_source"
        case runtimeDetail = "runtime_detail"
        case lastError = "last_error"
    }
}

struct ModuleUpdateStatus: Codable, Sendable {
    let supported: Bool
    let formatVersion: Int?
    let platform: String?
    let installedVersion: String?
    let publicKeyID: String?

    enum CodingKeys: String, CodingKey {
        case supported, platform
        case formatVersion = "format_version"
        case installedVersion = "installed_version"
        case publicKeyID = "public_key_id"
    }
}

struct ModuleUpdateResult: Codable, Sendable {
    let updated: Bool
    let version: String?
    let restartRequired: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case updated, version, message
        case restartRequired = "restart_required"
    }
}

struct MaVoAudioHostConfig: Codable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    let routeReady: Bool
    let routeSessionReady: Bool?
    let routeError: String?
    let routeRunning: Bool?
    let helperPID: Int?
    let sessionStartedAt: String?
    let statisticsAvailable: Bool?
    let statistics: VoicePCMStatistics?
    let diagnosticLog: String?
    let logTail: [String]?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case locationID = "location_id"
        case routeReady = "route_ready"
        case routeSessionReady = "route_session_ready"
        case routeError = "route_error"
        case routeRunning = "route_running"
        case helperPID = "helper_pid"
        case sessionStartedAt = "session_started_at"
        case statisticsAvailable = "statistics_available"
        case statistics
        case diagnosticLog = "diagnostic_log"
        case logTail = "log_tail"
    }
}

/// 模块语音桥的累计 PCM 统计；峰值为 PCM16 绝对幅度，0 代表纯静音。
struct VoicePCMStatistics: Codable, Sendable {
    let uplinkBytes: UInt64
    let uplinkFrames: UInt64
    let uplinkPeak: UInt64
    let downlinkBytes: UInt64
    let downlinkFrames: UInt64
    let downlinkPeak: UInt64
    let downlinkDroppedFrames: UInt64

    enum CodingKeys: String, CodingKey {
        case uplinkBytes = "uplink_bytes"
        case uplinkFrames = "uplink_frames"
        case uplinkPeak = "uplink_peak"
        case downlinkBytes = "downlink_bytes"
        case downlinkFrames = "downlink_frames"
        case downlinkPeak = "downlink_peak"
        case downlinkDroppedFrames = "downlink_dropped_frames"
    }
}

import SwiftUI

enum GPSRefreshPolicy {
    static func shouldRequest(isEnabled: Bool) -> Bool { isEnabled }
}

/// 设置页只在前台刷新，避免关闭弹层后仍持续请求模块并额外耗电。
enum SettingsRefreshPolicy {
    static func shouldRefresh(appIsActive: Bool) -> Bool { appIsActive }
}

/// 设置页完整承载 Mac 版“状态 / 通用 / 网络 / GPS / eSIM / AT / 服务控制”功能。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("djonehub.background-standby-enabled") private var backgroundStandbyEnabled = true
    @AppStorage("djonehub.low-power-mode-enabled") private var lowPowerModeEnabled = true
    @AppStorage("djonehub.live-activity-enabled") private var liveActivityEnabled = true

    @State private var modem: ModemStatus?
    @State private var traffic: NetworkTrafficSnapshot?
    @State private var previousTraffic: NetworkTrafficSnapshot?
    @State private var downloadRate: Double?
    @State private var uploadRate: Double?
    @State private var systemPower: SystemPowerStatus?
    @State private var showingPowerDetails = false
    @State private var powerDetailsPresented = false
    @State private var powerCardPressed = false
    @State private var powerCardFeedback = UIImpactFeedbackGenerator(style: .medium)
    @State private var cellularAllowed = true
    /// 4G 策略写入期间，禁止轮询回包覆盖用户刚刚选择的状态。
    @State private var isUpdatingCellularPolicy = false
    /// 每次用户修改策略都递增，用于丢弃修改前已发出的旧查询结果。
    @State private var cellularPolicyRevision = 0
    /// 上网方式：wifi（手机上网走 Wi-Fi）或 module（手机使用模块 4G）；nil 表示模块尚不支持。
    @State private var internetMode: String?
    @State private var isUpdatingInternetMode = false
    @State private var internetModeRevision = 0
    @State private var gps: GPSStatus?
    @State private var gpsMessage = ""
    @State private var esim: ESIMOverview?
    @State private var esimHealth: ESIMHealth?
    @State private var voice: VoiceRuntimeStatus?
    @State private var setup: ModuleSetupStatus?
    @State private var usbProfile: USBProfileStatus?
    @State private var actionMessage = ""
    @State private var atCommand = "AT+CSQ"
    @State private var atResponse = ""
    @State private var networkDiagnostic: NetworkDiagnostic?
    @State private var showingDiagnostic = false
    @State private var showingESIMDownload = false
    @State private var showingShutdownConfirmation = false
    @State private var showingMacModeConfirmation = false
    @State private var busy = false
    let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("状态")) {
                    statusCard
                }

                Section(L10n.t("通用")) {
                    generalCard
                    voiceCard
                }

                Section(L10n.t("网络")) {
                    networkCard
                }

                Section("功率与温度") {
                    powerCard
                        // 让监测卡保留独立圆角边界，不再占用整块设置列表的视觉空间。
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                Section(L10n.t("定位")) {
                    gpsCard
                }

                Section(L10n.t("eSIM / 卡片")) {
                    esimCard
                }

                Section(L10n.t("AT 调试")) {
                    atCard
                }

                Section("服务控制") {
                    serviceCard
                }

                if !actionMessage.isEmpty {
                    Section {
                        Text(actionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.t("设置"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("完成")) { closeSettings() }
                        .fontWeight(.semibold)
                }
            }
            .task(id: scenePhase) {
                guard SettingsRefreshPolicy.shouldRefresh(appIsActive: scenePhase == .active) else { return }
                await runStatusLoop()
            }
            .sheet(isPresented: $showingDiagnostic) {
                NetworkDiagnosticView(diagnostic: networkDiagnostic)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingESIMDownload) {
                ESIMDownloadView { smdp, matchingID, confirmationCode, imei, aid in
                    await downloadProfile(smdp, matchingID, confirmationCode, imei, aid)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog("确认完全退出模块服务？", isPresented: $showingShutdownConfirmation, titleVisibility: .visible) {
                Button("完全退出", role: .destructive) {
                    Task { await shutdownAgent() }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text("代理停止后需重新插拔或重启模块才能恢复。")
            }
            .confirmationDialog("切换为 Mac 完整模式？", isPresented: $showingMacModeConfirmation, titleVisibility: .visible) {
                Button("切换并重启模块", role: .destructive) {
                    Task { await switchToMacMode() }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text("只会写入已验证的 USB Audio 配置位。模块重启后，请把它从\(DeviceContext.displayName)拔出并连接到 Mac。")
            }
        }
        // 弹窗放到整个设置页顶层，不能附在 Form 单行上，否则长内容会被列表裁切。
        .overlay {
            if showingPowerDetails {
                ZStack {
                    Color.black.opacity(0.14)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissPowerDetails() }
                        .opacity(powerDetailsPresented ? 1 : 0)

                    PowerDetailsPopover(systemPower: systemPower, onDismiss: dismissPowerDetails)
                        // 吞掉卡片内的普通点击，只有点击遮罩才关闭。
                        .onTapGesture {}
                        // 模拟 iOS 原生弹层：轻微上浮并以弹簧回弹，不硬切显示。
                        .scaleEffect(powerDetailsPresented ? 1 : 0.92)
                        .offset(y: powerDetailsPresented ? 0 : 16)
                        .opacity(powerDetailsPresented ? 1 : 0)
                        .onAppear {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                powerDetailsPresented = true
                            }
                        }
                }
                // 顶部导航栏不进入遮罩范围，用户随时都能点“完成”退出设置。
                .padding(.top, 64)
                .zIndex(10)
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            infoRow(L10n.t("模块代理"), model.isOnline ? L10n.t("在线") : L10n.t("离线"), tint: model.isOnline ? .green : .red)
            Divider()
            infoRow("App 版本", appVersionText)
            Divider()
            infoRow("Agent 版本", model.agentVersion ?? (model.isOnline ? "读取中" : "--"))
            Divider()
            infoRow(L10n.t("运营商"), operatorDisplayName(modem?.operatorName) ?? "--")
            Divider()
            infoRow(L10n.t("SIM 卡"), modem?.simInserted == true ? "已接入" : "未接入")
            Divider()
            infoRow(L10n.t("网络模式"), modem?.networkMode ?? "--")
            Divider()
            infoRow(L10n.t("信号强度"), modem?.signalDBM.map { "\($0) dBm" } ?? "--")
            Divider()
            HStack(spacing: 0) {
                metric(L10n.t("下载速度"), rateText(downloadRate))
                Divider().frame(height: 40)
                metric(L10n.t("上传速度"), rateText(uploadRate))
                Divider().frame(height: 40)
                metric(L10n.t("本次流量"), byteText(traffic?.sessionTotal))
            }
            Divider()
            Button {
                Task { await refreshAll() }
            } label: {
                Label(L10n.t("刷新"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 8)
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "--"
        return "\(version) (\(build))"
    }

    private var generalCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("显示模式"), systemImage: "circle.lefthalf.filled")
                Picker(L10n.t("显示模式"), selection: $appSettings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("语言"), systemImage: "globe")
                Picker(L10n.t("语言"), selection: $appSettings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.vertical, 8)
            Toggle("锁屏收来电", isOn: $backgroundStandbyEnabled)
                .onChange(of: backgroundStandbyEnabled) { enabled in
                    model.setBackgroundStandbyEnabled(enabled)
                }
            Text(backgroundStandbyEnabled
                 ? "可靠来电模式：后台维持必要的连接与音频准备，锁屏来电更及时，但耗电高于普通 App。"
                 : "低耗电模式：iOS 可挂起 App；锁屏来电可能延迟，甚至无法及时显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 8)
            Toggle("省电模式", isOn: $lowPowerModeEnabled)
                .onChange(of: lowPowerModeEnabled) { enabled in
                    model.setLowPowerModeEnabled(enabled)
                }
                .disabled(!backgroundStandbyEnabled)
            Text(lowPowerModeEnabled
                 ? "优先降低空闲状态请求频率；旧模块不支持事件等待时会自动使用兼容轮询。"
                 : "保持较高的后台检测频率，响应更快但耗电更高。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 8)
            Toggle("灵动岛", isOn: $liveActivityEnabled)
                .onChange(of: liveActivityEnabled) { enabled in
                    model.setLiveActivityEnabled(enabled)
                }
            Text("关闭后结束灵动岛和锁屏实时活动；普通来电通知仍然保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 4) {
                Label("连接模式", systemImage: DeviceContext.symbolName)
                Text(usbProfile?.mode == "mac" ? "Mac 完整模式" : "\(DeviceContext.displayName) 直连模式")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("192.168.225.1").font(.caption2).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 8)
            Button {
                showingMacModeConfirmation = true
            } label: {
                Label("切换为 Mac 完整模式", systemImage: "laptopcomputer.and.iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy || !model.isOnline || usbProfile?.mode == "mac")
            Text("快速切换只改 UAC 位，不重刷整套固件；重启和 USB 重新枚举通常只需十几秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 8)
            NavigationLink {
                RingtoneSettingsView()
            } label: {
                Label("来电铃声", systemImage: "bell.fill")
            }
        }
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("通话支持", systemImage: "waveform.circle.fill").font(.headline)
            Text(voice?.ready == true ? "语音运行时已就绪" : (voice?.lastError ?? "等待模块语音运行时"))
                .font(.subheadline)
                .foregroundStyle(voice?.ready == true ? Color.green : Color.secondary)
            if let detail = voice?.runtimeDetail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("刷新") { Task { await refreshVoice() } }
                if voice?.ready != true {
                    Button("安装语音运行时") { Task { await provisionVoice() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var networkCard: some View {
        VStack(spacing: 12) {
            internetModeCard
            Divider()
            Toggle(L10n.t("允许 4G 上网"), isOn: cellularAllowedBinding)
                .disabled(isUpdatingCellularPolicy)
            Text("关闭后禁止\(DeviceContext.displayName)通过模块访问互联网；短信与来电监控不受影响。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            actionGrid([
                (L10n.t("检查 4G 出口"), "antenna.radiowaves.left.and.right", check4G),
                (L10n.t("检查代理出口"), "network", checkProxy),
                (L10n.t("网络诊断"), "stethoscope", showNetworkDiagnostic),
                (L10n.t("重启模块"), "restart", rebootModule),
            ])
        }
    }

    /// 上网方式开关：无论选择哪种方式，通话与短信始终通过 USB 私网，不受影响。
    @ViewBuilder
    private var internetModeCard: some View {
        if internetMode != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("上网方式")).font(.subheadline.weight(.semibold))
                Picker(L10n.t("上网方式"), selection: internetModeBinding) {
                    Text(L10n.t("Wi-Fi 上网")).tag("wifi")
                    Text(L10n.t("模块 4G 上网")).tag("module")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isUpdatingInternetMode || !model.isOnline)
                Text("模块 4G 上网：手机使用模块的 4G 流量上网。\nWi-Fi 上网：手机上网继续走 Wi-Fi，模块只负责通话、短信与控制。\n切换时模块网络会中断约 4 秒，App 会自动重连，通话与短信不受影响。若 20 秒后仍未连上，按拨号页提示到“设置 → 以太网”把 IP 手动设为 192.168.225.2（掩码 255.255.255.0，路由器留空），设好后就不必再开飞行模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("上网方式")).font(.subheadline.weight(.semibold))
                Text("当前模块版本尚未支持上网方式切换；将模块更新到 0.3.22 或更高版本后可用。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 温度与供电仅每次设置页状态刷新时读取一次，不保持额外后台轮询。
    private var powerCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "thermometer.medium")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(.orange.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("模块温度")
                        .font(.subheadline.weight(.semibold))
                    Text(powerCardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(primaryPower.map { String(format: "%.1f W", $0) } ?? "--")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("当前功率")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 0) {
                compactPowerMetric("电压", primaryVoltage.map { String(format: "%.2f V", $0) } ?? "--")
                Divider().frame(height: 28)
                compactPowerMetric("电流", primaryCurrent.map { String(format: "%.2f A", $0) } ?? "--")
                Divider().frame(height: 28)
                compactPowerMetric("状态", modulePowerOnline ? "已连接" : "--", tint: modulePowerOnline ? .green : .secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .scaleEffect(powerCardPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: powerCardPressed)
        // 长按卡片才显示完整传感器列表；轻触仍保持设置页的普通滚动体验。
        .onLongPressGesture(
            minimumDuration: 0.2,
            maximumDistance: 36,
            perform: {
                powerCardFeedback.impactOccurred()
                powerCardFeedback.prepare()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showingPowerDetails = true
                }
            },
            onPressingChanged: { pressing in
                powerCardPressed = pressing
                if pressing { powerCardFeedback.prepare() }
            }
        )
    }

    /// 无论模块是否插入都保留同一张卡，避免读取结果返回时设置页面跳动。
    private var powerCardSubtitle: String {
        guard let systemPower else { return "等待模块连接" }
        guard systemPower.supported, !systemPower.readings.isEmpty else { return "暂不支持读取" }
        return primaryTemperature.map { String(format: "最高 %.0f°C", $0) } ?? "正在读取"
    }

    private func dismissPowerDetails() {
        withAnimation(.easeOut(duration: 0.18)) {
            powerDetailsPresented = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190))
            guard !powerDetailsPresented else { return }
            showingPowerDetails = false
        }
    }

    private func closeSettings() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    /// 卡片只呈现最有用的一组读数；完整传感器列表保留在模块接口中，不塞进设置页。
    private var primaryTemperature: Double? {
        systemPower?.readings.compactMap(\.temperatureC).max()
    }

    private var primaryVoltage: Double? {
        systemPower?.readings.compactMap(\.voltageV).first
    }

    private var primaryCurrent: Double? {
        systemPower?.readings.compactMap(\.currentA).first
    }

    private var primaryPower: Double? {
        systemPower?.readings.compactMap(\.powerW).first
    }

    private var modulePowerOnline: Bool {
        systemPower?.readings.contains(where: { $0.online == true }) == true
    }

    private func compactPowerMetric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var gpsCard: some View {
        VStack(spacing: 10) {
            Toggle(L10n.t("GPS 定位"), isOn: gpsBinding)
            if gps?.enabled == true {
                Divider()
                infoRow(L10n.t("坐标"), coordinateText)
                infoRow(L10n.t("卫星"), gps?.lastFix?.satellites ?? "--")
                infoRow("HDOP", gps?.lastFix?.hdop ?? "--")
                Button("立即刷新") { Task { await refreshGPSFix() } }
                    .buttonStyle(.bordered)
                    .disabled(busy || !GPSRefreshPolicy.shouldRequest(isEnabled: gps?.enabled == true))
                let message = gpsMessage.isEmpty ? (gps?.lastError ?? "") : gpsMessage
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("默认关闭；开启后仅在本机读取模块定位信息。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var esimCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoRow(L10n.t("卡片类型"), cardTypeText)
            if let message = esim?.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let groups = esim?.profiles {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    ForEach(group.profiles ?? []) { profile in
                        Divider()
                        ESIMProfileRow(profile: profile) { action in
                            // 把所属 eUICC AID 一并传给模块，避免双 eUICC 卡跨 SE 误操作。
                            Task { await handleProfile(action, profile: profile, aid: group.aidHex ?? "") }
                        }
                    }
                }
            }
            Divider()
            VStack(spacing: 8) {
                Button(L10n.t("通讯录检测")) { Task { await probePhonebook() } }
                    .frame(maxWidth: .infinity)
                Button(L10n.t("下载新 Profile")) { showingESIMDownload = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            if let healthMessage = esimHealth?.message, !healthMessage.isEmpty {
                Text(healthMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var atCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L10n.t("AT 指令"), text: $atCommand)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button(L10n.t("发送 AT")) { Task { await executeAT() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(atCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !atResponse.isEmpty {
                ScrollView(.horizontal) {
                    Text(atResponse)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("停止模块内 4G 后台、短信守护、通话与控制服务。")
                .font(.caption).foregroundStyle(.secondary)
            Button("完全退出", role: .destructive) {
                showingShutdownConfirmation = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 状态刷新

    private func runStatusLoop() async {
        while !Task.isCancelled,
              SettingsRefreshPolicy.shouldRefresh(appIsActive: scenePhase == .active) {
            await refreshAll()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshAll() async {
        // 轮询开始时记录版本；请求返回时若用户已修改策略，则该回包已过期。
        let policyRevisionAtRequest = cellularPolicyRevision
        let internetModeRevisionAtRequest = internetModeRevision
        let wasUpdatingInternetMode = isUpdatingInternetMode
        async let modemRequest = try? model.api.modemStatus()
        async let trafficRequest = try? model.api.networkTraffic()
        async let powerRequest = try? model.api.systemPower()
        async let policyRequest = try? model.api.cellularPolicy()
        async let gpsRequest = try? model.api.gpsStatus()
        async let esimRequest = try? model.api.esimOverview()
        async let healthRequest = try? model.api.esimHealth()
        async let voiceRequest = try? model.api.voiceRuntimeStatus()
        async let setupRequest = try? model.api.moduleSetupStatus()
        async let usbProfileRequest = try? model.api.usbProfile()
        async let internetModeRequest = try? model.api.internetMode()

        modem = await modemRequest
        if let current = await trafficRequest {
            updateRates(with: current)
            traffic = current
        }
        systemPower = await powerRequest
        if let policy = await policyRequest,
           policyRevisionAtRequest == cellularPolicyRevision,
           !isUpdatingCellularPolicy {
            cellularAllowed = !policy.forceOff
        }
        gps = await gpsRequest
        esim = await esimRequest
        esimHealth = await healthRequest
        voice = await voiceRequest
        setup = await setupRequest
        usbProfile = await usbProfileRequest
        if let modeStatus = await internetModeRequest,
           !modeStatus.mode.isEmpty,
           internetModeRevisionAtRequest == internetModeRevision,
           !wasUpdatingInternetMode {
            internetMode = modeStatus.mode
        }
    }

    private func updateRates(with current: NetworkTrafficSnapshot) {
        defer { previousTraffic = current }
        guard let previousTraffic,
              previousTraffic.interface == current.interface,
              current.sampledAtMS > previousTraffic.sampledAtMS else {
            downloadRate = nil
            uploadRate = nil
            return
        }
        let elapsed = Double(current.sampledAtMS - previousTraffic.sampledAtMS) / 1_000
        downloadRate = Double(current.rxBytes &- previousTraffic.rxBytes) / elapsed
        uploadRate = Double(current.txBytes &- previousTraffic.txBytes) / elapsed
    }

    // MARK: - 操作

    private var cellularAllowedBinding: Binding<Bool> {
        Binding(
            get: { cellularAllowed },
            set: { requestedAllowed in
                guard requestedAllowed != cellularAllowed, !isUpdatingCellularPolicy else { return }
                updateCellularPolicy(allowed: requestedAllowed)
            }
        )
    }

    private var internetModeBinding: Binding<String> {
        Binding(
            get: { internetMode ?? "module" },
            set: { requestedMode in
                guard requestedMode != internetMode, !isUpdatingInternetMode else { return }
                updateInternetMode(requestedMode)
            }
        )
    }

    /// 先立即更新界面，再等待模块确认；切换期间模块网络会短暂中断（Agent 会抖动 ecm0 触发手机重新租约）。
    private func updateInternetMode(_ mode: String) {
        guard model.activeCall == nil else {
            actionMessage = "通话进行中不能切换上网方式，请先挂断"
            return
        }
        let previousMode = internetMode ?? "module"
        internetMode = mode
        internetModeRevision &+= 1
        let requestRevision = internetModeRevision
        isUpdatingInternetMode = true

        Task {
            defer {
                if requestRevision == internetModeRevision {
                    isUpdatingInternetMode = false
                }
            }

            do {
                let result = try await model.api.setInternetMode(mode)
                guard requestRevision == internetModeRevision else { return }
                // 以模块回包为准，避免本地显示与实际模式不一致。
                internetMode = result.mode
                actionMessage = result.message ?? "已切换上网方式"
            } catch {
                guard requestRevision == internetModeRevision else { return }
                internetMode = previousMode
                actionMessage = "切换上网方式失败：\(error.localizedDescription)"
            }
        }
    }

    /// 先立即更新界面，再等待模块确认；失败时恢复原值，避免开关“点了又弹回”的假象。
    private func updateCellularPolicy(allowed: Bool) {
        let previousAllowed = cellularAllowed
        cellularAllowed = allowed
        cellularPolicyRevision &+= 1
        let requestRevision = cellularPolicyRevision
        isUpdatingCellularPolicy = true

        Task {
            defer {
                if requestRevision == cellularPolicyRevision {
                    isUpdatingCellularPolicy = false
                }
            }

            do {
                let policy = try await model.api.setCellularPolicy(forceOff: !allowed)
                guard requestRevision == cellularPolicyRevision else { return }
                // 以模块回包为准，避免本地显示与实际策略不一致。
                cellularAllowed = !policy.forceOff
                actionMessage = cellularAllowed
                    ? "已允许\(DeviceContext.displayName)使用模块 4G"
                    : "已禁止\(DeviceContext.displayName)使用模块 4G"
            } catch {
                guard requestRevision == cellularPolicyRevision else { return }
                cellularAllowed = previousAllowed
                actionMessage = "4G 上网设置失败：\(error.localizedDescription)"
            }
        }
    }

    private func perform(_ operation: () async throws -> String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { actionMessage = try await operation() }
        catch { actionMessage = error.localizedDescription }
    }

    private func check4G() async { await perform { let r = try await model.api.check4GRoute(); return r.summary ?? (r.ok ? "检查通过" : "检查未通过") } }
    private func checkProxy() async { await perform { let r = try await model.api.checkProxyRoute(); return r.summary ?? (r.ok ? "检查通过" : "检查未通过") } }
    private func rebootModule() async { await perform { try await model.api.rebootModule(); return "已发送模块重启指令" } }
    private func showNetworkDiagnostic() async {
        await perform {
            networkDiagnostic = try await model.api.networkDiagnostic()
            showingDiagnostic = true
            return "网络诊断已更新"
        }
    }
    private func refreshVoice() async { voice = try? await model.api.voiceRuntimeStatus() }
    private func provisionVoice() async { await perform { voice = try await model.api.provisionVoiceRuntime(); return "语音运行时已安装" } }
    private func refreshGPSFix() async {
        guard GPSRefreshPolicy.shouldRequest(isEnabled: gps?.enabled == true) else { return }
        gpsMessage = "正在定位；首次定位请在窗边或室外等待 30–120 秒"
        await perform {
            let fix = try await model.api.gpsRefresh()
            gps = GPSStatus(enabled: true, lastFix: fix, lastError: nil)
            return "定位已刷新"
        }
        gpsMessage = actionMessage
    }
    private func probePhonebook() async { await perform { let r = try await model.api.probeESIMPhonebook(); return r.readSupported == true ? "模块支持读取卡内联系人" : "模块未确认读取能力" } }
    private func executeAT() async {
        let command = atCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.uppercased().hasPrefix("AT"), command.count <= 256 else {
            atResponse = "请输入以 AT 开头、长度不超过 256 的指令"
            return
        }
        await perform { let result = try await model.api.executeAT(command); atResponse = result.response; return "AT 指令已执行" }
    }
    private func shutdownAgent() async { await perform { try await model.api.shutdownModuleAgent(); model.stop(); return "模块代理已停止" } }
    private func switchToMacMode() async {
        await perform {
            let result = try await model.api.setUSBProfile("mac")
            usbProfile = result
            return result.message ?? "已切换为 Mac 完整模式，模块正在重启"
        }
    }
    private func downloadProfile(_ smdp: String, _ matchingID: String, _ confirmationCode: String, _ imei: String, _ aid: String) async {
        await perform {
            let result = try await model.api.downloadESIMProfile(smdp: smdp, matchingID: matchingID, confirmationCode: confirmationCode, imei: imei, aid: aid)
            await refreshAll()
            return result.message ?? "Profile 下载完成"
        }
    }
    private func handleProfile(_ action: ESIMProfileAction, profile: ESIMProfile, aid: String) async {
        guard let iccid = profile.iccid else { return }
        switch action {
        case .switchProfile:
            await perform { _ = try await model.api.switchESIM(iccid: iccid, aid: aid); return "已切换 Profile，模块正在重启" }
        case let .rename(name):
            await perform { try await model.api.renameESIMProfile(iccid: iccid, aid: aid, name: name); await refreshAll(); return "Profile 名称已修改" }
        case .delete:
            await perform { try await model.api.deleteESIMProfile(iccid: iccid, aid: aid); await refreshAll(); return "Profile 已删除" }
        }
    }

    private var gpsBinding: Binding<Bool> {
        Binding(
            get: { gps?.enabled == true },
            set: { enabled in
                Task {
                    await perform {
                        if enabled {
                            let result = try await model.api.gpsStart()
                            gps = GPSStatus(enabled: result.enabled, lastFix: result.lastFix, lastError: nil)
                            return "已启动定位"
                        }
                        _ = try await model.api.gpsStop()
                        gps = GPSStatus(enabled: false, lastFix: nil, lastError: nil)
                        return "已停止定位"
                    }
                }
            }
        )
    }

    // MARK: - 展示辅助

    private func infoRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
            .frame(maxWidth: .infinity)
    }
    private func actionGrid(_ actions: [(String, String, () async -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button { Task { await action.2() } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.1)
                        Text(action.0).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
        }
    }
    private var coordinateText: String {
        guard let lat = gps?.lastFix?.latitude, let lng = gps?.lastFix?.longitude else { return L10n.t("等待定位") }
        return "\(lat), \(lng)"
    }
    private var cardTypeText: String {
        switch esim?.cardType { case "physical_sim": return "实体 SIM"; case "esim": return "eSIM"; default: return esim?.cardType ?? "查询中" }
    }
    private func rateText(_ bytes: Double?) -> String {
        guard let bytes else { return "--" }
        return bytes >= 1_048_576 ? String(format: "%.1f MB/s", bytes / 1_048_576) : String(format: "%.1f KB/s", bytes / 1_024)
    }
    private func byteText(_ bytes: UInt64?) -> String {
        guard let bytes else { return "--" }
        return bytes >= 1_073_741_824 ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824) : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
    private func operatorDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let map = ["CHINA TELECOM": "中国电信", "CTCC": "中国电信", "CHINA MOBILE": "中国移动", "CMCC": "中国移动", "CHINA UNICOM": "中国联通", "UNICOM": "中国联通", "CHINA BROADNET": "中国广电"]
        return map[raw.uppercased()] ?? raw
    }
    private func powerKindName(_ kind: String) -> String {
        switch kind {
        case "power_supply": return "电源"
        case "thermal": return "温度"
        case "hwmon": return "硬件监控"
        case "adc": return "电源采样"
        default: return kind
        }
    }
}

private enum ESIMProfileAction { case switchProfile; case rename(String); case delete }

private struct ESIMProfileRow: View {
    let profile: ESIMProfile
    let action: (ESIMProfileAction) -> Void
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading) {
                    Text(profile.displayName).font(.subheadline.weight(.semibold))
                    Text(mask(profile.iccid)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if profile.enabled { Label("使用中", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            }
            HStack {
                if !profile.enabled { Button(L10n.t("切换")) { action(.switchProfile) } }
                Button(L10n.t("重命名")) { name = profile.name ?? ""; showingRename = true }
                Button(L10n.t("删除"), role: .destructive) { showingDelete = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .alert("重命名 Profile", isPresented: $showingRename) {
            TextField("Profile 名称", text: $name)
            Button(L10n.t("保存")) { action(.rename(name.trimmingCharacters(in: .whitespacesAndNewlines))) }
            Button(L10n.t("取消"), role: .cancel) {}
        }
        .confirmationDialog("确认删除 Profile？", isPresented: $showingDelete) {
            Button(L10n.t("删除"), role: .destructive) { action(.delete) }
            Button(L10n.t("取消"), role: .cancel) {}
        }
    }

    private func mask(_ value: String?) -> String {
        guard let value, value.count > 8 else { return value ?? "--" }
        return "\(value.prefix(4)) •••• \(value.suffix(4))"
    }
}

private struct NetworkDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    let diagnostic: NetworkDiagnostic?

    var body: some View {
        NavigationStack {
            List {
                Section("USB") {
                    LabeledContent("USB 网卡", value: diagnostic?.usbNetworkPresent == true ? "已识别" : "未识别")
                    LabeledContent("模式", value: diagnostic?.usbnetMode ?? "--")
                    LabeledContent("设备", value: [diagnostic?.usbDevice?.vendor, diagnostic?.usbDevice?.product].compactMap { $0 }.joined(separator: " · "))
                }
                Section("蜂窝网络") {
                    LabeledContent("蜂窝 IP", value: diagnostic?.pdpAddresses?.joined(separator: ", ") ?? "--")
                    LabeledContent("活动 PDP", value: diagnostic?.activeContexts?.map(String.init).joined(separator: ", ") ?? "--")
                }
                Section("\(DeviceContext.displayName) 路由") {
                    LabeledContent("默认出口", value: diagnostic?.defaultRoute?.interface ?? "--")
                    LabeledContent("网关", value: diagnostic?.defaultRoute?.gateway ?? "--")
                }
                if let interfaces = diagnostic?.interfaces {
                    Section("接口") {
                        ForEach(Array(interfaces.enumerated()), id: \.offset) { _, item in
                            LabeledContent(item.name ?? "--", value: item.ipv4 ?? item.status ?? "--")
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("网络诊断"))
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

/// 设置页功率卡的完整读数面板；卡片保持紧凑，详细传感器只在用户长按时显示。
private struct PowerDetailsPopover: View {
    let systemPower: SystemPowerStatus?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("完整功率与温度", systemImage: "thermometer.medium")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 固定字段模板始终存在，数据回来后原位更新，避免面板突然改变结构。
            detailRow("最高温度", maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--")
            detailRow("电压", voltage.map { String(format: "%.2f V", $0) } ?? "--")
            detailRow("电流", current.map { String(format: "%.2f A", $0) } ?? "--")
            detailRow("功率", power.map { String(format: "%.1f W", $0) } ?? "--")
            detailRow("电量", capacity.map { "\($0)%" } ?? "--")
            detailRow("外部供电", online.map { $0 ? "已连接" : "未连接" } ?? "--")
            detailRow("系统状态", statusText ?? "--")

            Divider()

            Text("传感器明细")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 9) {
                    if readings.isEmpty {
                        detailRow("读取状态", systemPower == nil ? "等待模块连接" : "暂不支持读取")
                    } else {
                        ForEach(readings) { reading in
                            detailRow(reading.name, readingText(reading))
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func readingText(_ reading: SystemPowerReading) -> String {
        var values: [String] = []
        if let value = reading.temperatureC { values.append(String(format: "%.0f°C", value)) }
        if let value = reading.voltageV { values.append(String(format: "%.2fV", value)) }
        if let value = reading.currentA { values.append(String(format: "%.2fA", value)) }
        if let value = reading.powerW { values.append(String(format: "%.1fW", value)) }
        if let value = reading.capacityPercent { values.append("\(value)%") }
        if let value = reading.online { values.append(value ? "在线" : "离线") }
        if let value = reading.status, !value.isEmpty { values.append(value) }
        return values.isEmpty ? "--" : values.joined(separator: " · ")
    }

    private var readings: [SystemPowerReading] {
        guard systemPower?.supported == true else { return [] }
        return systemPower?.readings ?? []
    }

    private var maximumTemperature: Double? { readings.compactMap(\.temperatureC).max() }
    private var voltage: Double? { readings.compactMap(\.voltageV).first }
    private var current: Double? { readings.compactMap(\.currentA).first }
    private var power: Double? { readings.compactMap(\.powerW).first }
    private var capacity: Int? { readings.compactMap(\.capacityPercent).first }
    private var online: Bool? { readings.compactMap(\.online).first }
    private var statusText: String? { readings.compactMap(\.status).first(where: { !$0.isEmpty }) }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ESIMDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    let onDownload: (String, String, String, String, String) async -> Void
    @State private var smdp = ""
    @State private var matchingID = ""
    @State private var confirmationCode = ""
    @State private var imei = ""
    @State private var aid = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("SM-DP+ 地址", text: $smdp).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Matching ID（可选）", text: $matchingID)
                    TextField("确认码（可选）", text: $confirmationCode)
                    TextField("IMEI（必填）", text: $imei).keyboardType(.numberPad)
                    TextField("AID（可选）", text: $aid).textInputAutocapitalization(.characters)
                } footer: {
                    Text("Profile 写入期间不要拔出模块。")
                }
            }
            .navigationTitle(L10n.t("下载新 Profile"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始下载") {
                        busy = true
                        Task { await onDownload(smdp, matchingID, confirmationCode, imei, aid); busy = false; dismiss() }
                    }
                    .disabled(busy || smdp.isEmpty || imei.isEmpty)
                }
            }
        }
    }
}

/// 保存铃声偏好并通过同一套合成器试听，确保实际来电与设置页声音一致。
private struct RingtoneSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("djonehub.ringtone") private var ringtone = "Hero"
    private let tones = ["Hero", "Signal", "Beacon", "系统默认"]

    var body: some View {
        List(tones, id: \.self) { tone in
            Button {
                ringtone = tone
                model.audio.previewRingtone(named: tone)
            } label: {
                HStack {
                    Text(tone)
                    Spacer()
                    if ringtone == tone { Image(systemName: "checkmark") }
                    Image(systemName: "play.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .disabled(model.activeCall != nil)
        }
        .navigationTitle("来电铃声")
        .onDisappear { model.audio.stopRingtonePreview() }
    }
}

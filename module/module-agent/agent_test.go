package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	sgp22 "github.com/damonto/euicc-go/v2"
)

func TestAllowedRemote(t *testing.T) {
	tests := []struct {
		remote string
		want   bool
	}{
		{"192.168.225.2:54321", true},
		{"192.168.225.254:1", true},
		{"127.0.0.1:7575", true},
		{"[::1]:7575", true},
		{"192.168.224.2:7575", false},
		{"8.8.8.8:53", false},
		{"invalid", false},
	}
	for _, test := range tests {
		if got := allowedRemote(test.remote); got != test.want {
			t.Errorf("allowedRemote(%q)=%v，期望 %v", test.remote, got, test.want)
		}
	}
}

func TestCompareModuleVersions(t *testing.T) {
	tests := []struct {
		left, right string
		want        int
	}{
		{"0.3.0", "0.2.8", 1},
		{"0.3.0", "0.3.0", 0},
		{"0.2.9", "0.3.0", -1},
		{"1.0", "1.0.0", 0},
	}
	for _, test := range tests {
		if got := compareModuleVersions(test.left, test.right); got != test.want {
			t.Errorf("compareModuleVersions(%q,%q)=%d，期望 %d", test.left, test.right, got, test.want)
		}
	}
}

func TestModuleUpdateRestartScriptChecksHealthWithoutDeletingBackup(t *testing.T) {
	// 更新完成前保留备份，健康确认只作为是否安全恢复服务的判据。
	for _, required := range []string{
		"djonehub_agent stop",
		"djonehub_agent start",
		"/api/health",
		"update-health-confirmed",
		"update-health-timeout",
	} {
		if !strings.Contains(moduleUpdateRestartScript, required) {
			t.Fatalf("更新重启脚本缺少 %q", required)
		}
	}
	if strings.Contains(moduleUpdateRestartScript, "rm -rf") {
		t.Fatal("更新重启脚本不得自动删除回滚备份")
	}
}

func TestModuleUpdateRestartScriptLetsNewAgentStartBeforeRollback(t *testing.T) {
	// 新版本先移除待回滚标记，避免启动器在首次启动时把它立即恢复为旧版本。
	const clearMarker = "rm -f /data/djonehub/update-pending"
	if !strings.Contains(moduleUpdateRestartScript, clearMarker) {
		t.Fatal("更新重启脚本必须在启动新 Agent 前清除待回滚标记")
	}

	startOffset := strings.Index(moduleUpdateRestartScript, "/etc/init.d/djonehub_agent start")
	clearOffset := strings.Index(moduleUpdateRestartScript, clearMarker)
	if clearOffset < 0 || startOffset < 0 || clearOffset > startOffset {
		t.Fatal("待回滚标记必须在首次启动新 Agent 前清除")
	}

	if !strings.Contains(moduleUpdateRestartScript, "printf '%s\\n' \"$backup\" >/data/djonehub/update-pending") {
		t.Fatal("健康检查失败时必须重新写入回滚标记")
	}
}

func TestPersistentMobileDHCPInternetModeHookIsIncludedInStartupHook(t *testing.T) {
	// 启动钩子必须按 /data/djonehub/dhcp-internet-mode 应用上网方式：
	// wifi = 原厂参数（不下发 Router 选项 3，手机上网走 Wi-Fi）；
	// module（默认）= 追加选项 3，模块作为手机默认网关；未知配置仍拒绝替换。
	data, err := os.ReadFile("deploy-qdc507-agent.py")
	if err != nil {
		t.Fatal(err)
	}
	script := string(data)
	for _, required := range []string{
		"ensure_mobile_dhcp_internet_mode()",
		"/data/djonehub/dhcp-internet-mode",
		"--dhcp-option-force=6,192.168.225.1",
		"--dhcp-option-force=120,abcd.com",
		"ensure_mobile_dhcp_internet_mode || log_startup mobile-dhcp-internet-mode-unchanged",
	} {
		if !strings.Contains(script, required) {
			t.Fatalf("启动器缺少 DHCP 上网方式钩子：%q", required)
		}
	}
	wifiOffset := strings.Index(script, `if test "$internet_mode" = wifi`)
	if wifiOffset < 0 {
		t.Fatal("启动器缺少 wifi 上网模式分支")
	}
	elseOffset := wifiOffset + strings.Index(script[wifiOffset:], "\n    else")
	if elseOffset <= wifiOffset {
		t.Fatal("wifi 分支缺少 else 边界")
	}
	wifiSection := script[wifiOffset:elseOffset]
	if strings.Contains(wifiSection, "--dhcp-option-force=3,") {
		t.Fatal("wifi 模式不得下发 DHCP Router（选项 3），否则会抢占 Wi-Fi 默认路由")
	}
	if !strings.Contains(wifiSection, "--dhcp-option-force=6,192.168.225.1") {
		t.Fatal("wifi 分支必须保留原厂 DNS 参数")
	}
	if strings.Contains(script, "ensure_mobile_dhcp_router(") {
		t.Fatal("旧版 DHCP 网关钩子应被上网方式钩子取代")
	}
}

func TestDHCPInternetModeCommandLines(t *testing.T) {
	wifi := dnsmasqCommandLineForMode(internetModeWiFi)
	module := dnsmasqCommandLineForMode(internetModeModule)
	if strings.Contains(wifi, "--dhcp-option-force=3,") {
		t.Fatal("wifi 模式不得包含默认网关选项")
	}
	for _, option := range []string{
		"--dhcp-option-force=3,192.168.225.1",
		"--dhcp-option-force=6,192.168.225.1",
		"--dhcp-option-force=120,abcd.com",
	} {
		if !strings.Contains(module, option) {
			t.Fatalf("module 模式缺少 %s", option)
		}
	}
	sample := strings.TrimSuffix(module, " ")
	if normalizeProcCmdline([]byte(sample+"\x00")) != module {
		t.Fatal("命令行归一化应把 NUL 参数分隔转为空格并保留末尾空格")
	}
	mode, err := validateKnownDHCPCommandLine(wifi)
	if err != nil || mode != internetModeWiFi {
		t.Fatalf("原厂命令行应识别为 wifi 模式: %v %s", err, mode)
	}
	mode, err = validateKnownDHCPCommandLine(module)
	if err != nil || mode != internetModeModule {
		t.Fatalf("module 命令行应识别为 module 模式: %v %s", err, mode)
	}
	// 启动钩子以 /usr/bin/dnsmasq 重启，原厂以裸名启动；两种前缀都必须识别。
	bareModule := strings.TrimPrefix(module, dnsmasqBinaryPath+" ")
	if mode, err = validateKnownDHCPCommandLine(bareModule); err != nil || mode != internetModeModule {
		t.Fatalf("裸名 module 命令行应被识别: %v %s", err, mode)
	}
	if _, err := validateKnownDHCPCommandLine("dnsmasq -i eth0 "); err == nil {
		t.Fatal("未知 dnsmasq 命令行必须拒绝替换")
	}
}

func TestInternetModeHandlerPersistsAndReports(t *testing.T) {
	tempFile := filepath.Join(t.TempDir(), "dhcp-internet-mode")
	originalFile := internetModeFile
	internetModeFile = tempFile
	t.Cleanup(func() { internetModeFile = originalFile })

	a := &agent{started: time.Now(), smsAuto: true}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/network/internet-mode", strings.NewReader(`{"mode":"wifi"}`))
	a.routes(testLogger()).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("切换 wifi 模式失败: %d %s", response.Code, response.Body.String())
	}
	saved, readErr := os.ReadFile(tempFile)
	if readErr != nil || strings.TrimSpace(string(saved)) != internetModeWiFi {
		t.Fatalf("上网方式未持久化: %v %q", readErr, saved)
	}

	response = httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodGet, "/api/network/internet-mode", nil)
	a.routes(testLogger()).ServeHTTP(response, request)
	var payload map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["mode"] != internetModeWiFi {
		t.Fatalf("GET 应返回 wifi 模式: %v", payload)
	}

	// 通话进行中必须拒绝切换，避免 PCM 桥与 ecm0 抖动争用。
	response = httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodPost, "/api/network/internet-mode", strings.NewReader(`{"mode":"module"}`))
	a.calls.Active = &callRecord{}
	a.routes(testLogger()).ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("通话中切换应返回 409: %d", response.Code)
	}
	a.calls.Active = nil

	response = httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodPost, "/api/network/internet-mode", strings.NewReader(`{"mode":"invalid"}`))
	a.routes(testLogger()).ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("非法模式应返回 400: %d", response.Code)
	}
}

func TestValidateModuleUpdateManifestRejectsIncompleteOrWrongTarget(t *testing.T) {
	validFiles := make([]moduleUpdateFile, 0, len(moduleUpdateTargets))
	for name, target := range moduleUpdateTargets {
		validFiles = append(validFiles, moduleUpdateFile{
			Name: name, Target: target.target, SHA256: strings.Repeat("a", 64), Size: 1, Mode: target.mode,
		})
	}
	manifest := moduleUpdateManifest{
		FormatVersion: moduleUpdateFormat,
		Version:       "0.3.7",
		Platform:      moduleUpdatePlatform,
		Files:         validFiles,
	}
	if err := validateModuleUpdateManifest(manifest); err != nil {
		t.Fatalf("合法更新清单被拒绝: %v", err)
	}
	manifest.Files[0].Target = "bin/unsafe"
	if err := validateModuleUpdateManifest(manifest); err == nil {
		t.Fatal("更新清单中的越界目标未被拒绝")
	}
}

func TestWriteVoiceMediaRoutePreservesCommands(t *testing.T) {
	path := t.TempDir() + "/voc_svr"
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeVoiceMediaRoute(path, "S\n"); err != nil {
		t.Fatalf("写入语音启动命令失败: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "S\n" {
		t.Fatalf("语音启动命令=%q，期望 %q", data, "S\\n")
	}
}

func TestVoiceHelperChecksumMatchesBuiltArtifact(t *testing.T) {
	path := filepath.Join("pcm-bridge", voiceHelperName)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		t.Skip("尚未构建 PCM helper")
	}
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	if actual := hex.EncodeToString(digest[:]); actual != voiceHelperSHA256 {
		t.Fatalf("PCM helper SHA-256=%s，Agent 白名单=%s", actual, voiceHelperSHA256)
	}
}

func TestParseCLCC(t *testing.T) {
	response := "+CLCC: 1,1,4,0,0,\"+8613800138000\",145\r\n" +
		"+CLCC: 2,0,0,1,0,\"data\",129\r\nOK\r\n"
	calls := parseCLCC(response)
	if len(calls) != 1 {
		t.Fatalf("语音通话数量=%d，期望 1", len(calls))
	}
	if calls[0].Direction != "incoming" || calls[0].State != "incoming" || calls[0].Number != "+8613800138000" {
		t.Fatalf("通话解析错误: %#v", calls[0])
	}
}

func TestApplyCallPollRecordsMissedCall(t *testing.T) {
	a := &agent{}
	started := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
	a.applyCallPoll([]parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}}, started)
	a.applyCallPoll(nil, started.Add(3*time.Second))
	if a.calls.Active != nil || len(a.calls.History) != 1 {
		t.Fatalf("通话结束状态错误: active=%#v history=%d", a.calls.Active, len(a.calls.History))
	}
	if !a.calls.History[0].Missed || a.calls.History[0].EndedAt == nil {
		t.Fatalf("未接来电记录错误: %#v", a.calls.History[0])
	}
}

func TestCallEventRevisionChangesOnlyForMaterialState(t *testing.T) {
	a := &agent{}
	started := time.Date(2026, 8, 21, 10, 0, 0, 0, time.UTC)
	call := []parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}}
	a.applyCallPoll(call, started)
	first := a.callEventSnapshot(false)
	if first.Revision != 1 || first.Active == nil || first.Active.Number != "10086" {
		t.Fatalf("首次来电事件错误: %#v", first)
	}

	// 只有 updated_at 随轮询改变时不应唤醒手机，否则事件桥会退化为每秒轮询。
	a.applyCallPoll(call, started.Add(time.Second))
	if current := a.callEventSnapshot(false).Revision; current != first.Revision {
		t.Fatalf("无实质变化时修订号=%d，期望 %d", current, first.Revision)
	}

	call[0].State = "active"
	a.applyCallPoll(call, started.Add(2*time.Second))
	if current := a.callEventSnapshot(false); current.Revision != 2 || current.Active == nil || current.Active.State != "active" {
		t.Fatalf("接通事件错误: %#v", current)
	}
}

func TestCallEventsReturnsImmediatelyAfterIncomingChange(t *testing.T) {
	a := &agent{}
	request := httptest.NewRequest("GET", "/api/calls/events?after=0", nil)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		a.callEvents(response, request)
		close(done)
	}()

	a.applyCallPoll(
		[]parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10010"}},
		time.Date(2026, 8, 21, 10, 0, 0, 0, time.UTC),
	)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("来电变化后事件请求未立即返回")
	}
	if response.Code != 200 {
		t.Fatalf("事件接口状态=%d，响应=%s", response.Code, response.Body.String())
	}
	var event callEventResponse
	if err := json.Unmarshal(response.Body.Bytes(), &event); err != nil {
		t.Fatal(err)
	}
	if event.Revision != 1 || event.Active == nil || event.Active.Number != "10010" || event.Heartbeat {
		t.Fatalf("来电事件响应错误: %#v", event)
	}
}

func TestCallHistoryAckRemovesOnlyConfirmedRecords(t *testing.T) {
	a := &agent{calls: callTracker{History: []callRecord{{ID: "keep"}, {ID: "remove"}}}}
	request := httptest.NewRequest("POST", "/api/calls/history/ack", strings.NewReader(`{"ids":["remove"]}`))
	response := httptest.NewRecorder()
	a.callHistoryAck(response, request)
	if response.Code != 200 {
		t.Fatalf("确认接口状态=%d，响应=%s", response.Code, response.Body.String())
	}
	if len(a.calls.History) != 1 || a.calls.History[0].ID != "keep" {
		t.Fatalf("确认后通话队列错误: %#v", a.calls.History)
	}
}

func TestUCS2RoundTripAndSplit(t *testing.T) {
	value := "验证码 123456，测试🙂"
	encoded := encodeUCS2(value)
	if decoded := decodeMaybeUCS2(encoded); decoded != value {
		t.Fatalf("UCS2 往返=%q，期望 %q", decoded, value)
	}
	segments := splitUCS2("A🙂B", 2)
	if len(segments) != 3 || segments[0] != "A" || segments[1] != "🙂" || segments[2] != "B" {
		t.Fatalf("代理对拆分错误: %#v", segments)
	}
}

func TestParseTextModeSMS(t *testing.T) {
	response := "+CMGL: 7,\"REC READ\",\"002B0038003600310033003800300030003100330038003000300030\",,\"26/08/15,12:34:56+32\"\r\n" +
		"9A8C8BC17801662F003100320033003400350036\r\nOK\r\n"
	items := parseTextModeSMS(response, "ME")
	if len(items) != 1 {
		t.Fatalf("短信数量=%d，期望 1", len(items))
	}
	message := items[0].Message
	if message.Sender != "+8613800138000" || message.Content != "验证码是123456" || message.Code != "123456" {
		t.Fatalf("短信解析错误: %#v", message)
	}
	_, offset := message.Timestamp.Zone()
	if offset != 8*60*60 {
		t.Fatalf("短信时区偏移=%d，期望 28800", offset)
	}
	if message.DeliveryID == "" || !containsStoredSMS(items, items[0]) {
		t.Fatalf("短信交付标识或去重状态错误: %#v", items[0])
	}
}

func TestParseModemFields(t *testing.T) {
	if got := parseSignalDBM("+CSQ: 29,99\r\nOK"); got == nil || *got != -55 {
		t.Fatalf("信号解析=%v，期望 -55", got)
	}
	mode, band := parseNetworkInfo(`+QNWINFO: "FDD LTE","46001","LTE BAND 3",1650`)
	if mode != "FDD LTE" || band != "BAND 3" {
		t.Fatalf("网络解析 mode=%q band=%q", mode, band)
	}
	if got := normalizeOperator("CHN-UNICOM"); got != "中国联通" {
		t.Fatalf("运营商规范化=%q", got)
	}
}

func TestParseUSBConfigurationRefusesMalformedInput(t *testing.T) {
	valid := `+QCFG: "usbcfg",0x2C7C,0x0125,1,1,1,1,1,1,1` + "\r\nOK"
	configuration, err := parseUSBConfiguration(valid)
	if err != nil || !configuration.uacEnabled() {
		t.Fatalf("合法 USBCFG 解析失败: config=%#v err=%v", configuration, err)
	}
	if _, err := parseUSBConfiguration(`+QCFG: "usbcfg",0x2C7C,0x0125,1`); err == nil {
		t.Fatal("畸形 USBCFG 未被拒绝")
	}
}

func TestInferQDC507USBConfigurationFromGadget(t *testing.T) {
	files := map[string]string{
		usbGadgetPath + "/idVendor":  "2c7c\n",
		usbGadgetPath + "/idProduct": "0125\n",
		usbGadgetPath + "/functions": "diag,ecm,ffs\n",
	}
	readFile := func(path string) ([]byte, error) {
		value, ok := files[path]
		if !ok {
			return nil, os.ErrNotExist
		}
		return []byte(value), nil
	}
	configuration, raw, err := inferQDC507USBConfiguration(readFile)
	if err != nil || configuration.uacEnabled() || raw != "gadget functions=diag,ecm,ffs" {
		t.Fatalf("移动模式推断错误: config=%#v raw=%q err=%v", configuration, raw, err)
	}
	if got := configuration.withUAC(true); got != `AT+QCFG="usbcfg",0x2C7C,0x0125,1,1,1,1,1,1,1` {
		t.Fatalf("Mac 模式命令=%q", got)
	}
	files[usbGadgetPath+"/functions"] = "diag,serial,ecm,ffs,audio\n"
	configuration, _, err = inferQDC507USBConfiguration(readFile)
	if err != nil || !configuration.uacEnabled() {
		t.Fatalf("Mac 模式推断错误: config=%#v err=%v", configuration, err)
	}
}

func TestInferQDC507USBConfigurationRejectsUnknownHardware(t *testing.T) {
	readFile := func(path string) ([]byte, error) {
		values := map[string]string{
			usbGadgetPath + "/idVendor":  "ffff",
			usbGadgetPath + "/idProduct": "0125",
			usbGadgetPath + "/functions": "diag,ecm,ffs",
		}
		return []byte(values[path]), nil
	}
	if _, _, err := inferQDC507USBConfiguration(readFile); err == nil {
		t.Fatal("未知硬件不应使用固定 USBCFG 回退")
	}
}

func TestUSBGadgetHasAudio(t *testing.T) {
	read := func(string) ([]byte, error) { return []byte("diag,serial,ecm,audio,ffs\n"), nil }
	if !usbGadgetHasAudio(read) {
		t.Fatal("未识别到 Mac 组合中的 audio function")
	}
	read = func(string) ([]byte, error) { return []byte("diag,ecm,ffs\n"), nil }
	if usbGadgetHasAudio(read) {
		t.Fatal("手机组合被错误识别为含 USB 音频")
	}
}

func TestCellularForwardingPolicyWritesBothProtocols(t *testing.T) {
	for _, test := range []struct {
		name    string
		blocked bool
		want    map[string]string
	}{
		{
			name:    "关闭 4G",
			blocked: true,
			want:    map[string]string{ipv4ForwardingPath: "0\n", ipv6ForwardingPath: "0\n"},
		},
		{
			name:    "开启 4G",
			blocked: false,
			want:    map[string]string{ipv4ForwardingPath: "1\n", ipv6ForwardingPath: "2\n"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			writes := map[string]string{}
			writeFile := func(path string, data []byte, _ os.FileMode) error {
				writes[path] = string(data)
				return nil
			}
			if err := applyCellularForwardingPolicy(test.blocked, writeFile); err != nil {
				t.Fatal(err)
			}
			if len(writes) != len(test.want) {
				t.Fatalf("写入次数=%d，期望 %d", len(writes), len(test.want))
			}
			for path, want := range test.want {
				if got := writes[path]; got != want {
					t.Errorf("%s 写入 %q，期望 %q", path, got, want)
				}
			}
		})
	}
}

func TestCellularForwardingPolicyReturnsWriteError(t *testing.T) {
	writeFile := func(path string, _ []byte, _ os.FileMode) error {
		if path == ipv6ForwardingPath {
			return errors.New("permission denied")
		}
		return nil
	}
	err := applyCellularForwardingPolicy(true, writeFile)
	if err == nil || !strings.Contains(err.Error(), ipv6ForwardingPath) {
		t.Fatalf("错误=%v，期望包含失败路径", err)
	}
}

func TestRoutesRejectPublicRemote(t *testing.T) {
	a := &agent{started: time.Now()}
	request := httptest.NewRequest("GET", "/api/health", nil)
	request.RemoteAddr = "203.0.113.9:54321"
	recorder := httptest.NewRecorder()
	a.routes(testLogger()).ServeHTTP(recorder, request)
	if recorder.Code != 403 {
		t.Fatalf("公网访问状态码=%d，期望 403", recorder.Code)
	}
}

func testLogger() *log.Logger {
	return log.New(io.Discard, "", 0)
}

func TestNormalizeKnownEUICCAID(t *testing.T) {
	got, err := normalizeKnownEUICCAID("a06573746b6d65ffff4953442d522031")
	if err != nil || got != "A06573746B6D65FFFF4953442D522031" {
		t.Fatalf("eUICC 2 AID 规范化失败: got=%q err=%v", got, err)
	}
	if _, err := normalizeKnownEUICCAID("A000000001"); err == nil {
		t.Fatal("未验证的 AID 未被拒绝")
	}
}

func TestCGLAResponsePattern(t *testing.T) {
	response := `AT+CGLA=1,10,"80E2910000"` + "\r\n+CGLA: 4,\"9000\"\r\nOK"
	match := cglaResponsePattern.FindStringSubmatch(response)
	if len(match) != 2 || match[1] != "9000" {
		t.Fatalf("CGLA 响应解析错误: %#v", match)
	}
}

func TestPhysicalSIMESIMProbeError(t *testing.T) {
	err := errors.New("未发现任何 eUICC: 打开 eUICC logical channel 失败: AT 指令失败: ERROR")
	if !isPhysicalSIMESIMProbeError(err) {
		t.Fatal("实体 SIM 的 CCHO ERROR 应识别为卡片类型结果")
	}
	if isPhysicalSIMESIMProbeError(errors.New("读取 eUICC 超时")) {
		t.Fatal("普通通信错误不得误识别为实体 SIM")
	}
}

func TestProfilePayloadKeepsEUICCState(t *testing.T) {
	iccid, err := sgp22.NewICCID("8944305293607172968")
	if err != nil {
		t.Fatal(err)
	}
	payload := profilePayload(&sgp22.ProfileInfo{
		ICCID:               iccid,
		ProfileState:        sgp22.ProfileEnabled,
		ProfileNickname:     "CTExcel eSIM",
		ServiceProviderName: "CTExcel",
		ProfileClass:        sgp22.ProfileClassOperational,
	})
	if payload.ICCID != "8944305293607172968" || payload.State != 1 || payload.StateText != "已启用" {
		t.Fatalf("Profile 映射错误: %#v", payload)
	}
}

func TestParseVoicePCMStatsUsesLatestCompleteLine(t *testing.T) {
	logData := []byte(
		"mavo-pcm-bridge[stats]: uplink_bytes=320 uplink_frames=1 uplink_peak=12 downlink_bytes=640 downlink_frames=2 downlink_peak=34 downlink_dropped_frames=0\n" +
			"qdc507-agent[event]: time=2026-08-16T00:00:00Z still-running\n" +
			"mavo-pcm-bridge[stats]: uplink_bytes=960 uplink_frames=3 uplink_peak=1234 downlink_bytes=1280 downlink_frames=4 downlink_peak=2345 downlink_dropped_frames=2\n",
	)
	stats, ok := parseVoicePCMStats(logData)
	if !ok {
		t.Fatal("未解析到语音 PCM 统计")
	}
	if stats.UplinkBytes != 960 || stats.UplinkFrames != 3 || stats.UplinkPeak != 1234 {
		t.Fatalf("上行统计解析错误: %#v", stats)
	}
	if stats.DownlinkBytes != 1280 || stats.DownlinkFrames != 4 ||
		stats.DownlinkPeak != 2345 || stats.DownlinkDroppedFrame != 2 {
		t.Fatalf("下行统计解析错误: %#v", stats)
	}
}

func TestVoiceRouteMarkersRequireD4AndNetworkBridge(t *testing.T) {
	data := []byte("mavo-pcm-bridge[info]: network PCM client connected\n" +
		"mavo-pcm-bridge[info]: bridge active on 192.168.225.1:7580\n")
	if voiceRouteLogReady(data) {
		t.Fatal("缺少 D4 route session 的日志不应被判定为完整路由")
	}
	data = append(data, []byte("mavo-pcm-bridge[info]: VoLTE route session active on hw:0,4\n")...)
	if !voiceRouteLogReady(data) {
		t.Fatal("D4 route session 与网络桥标记齐全时应判定为完整路由")
	}
}

func TestVoiceClientConnectTimeoutAllowsSlowFirstAudioStartup(t *testing.T) {
	// iOS 首次授权会暂停 App，等待窗口不能退回到容易误杀新设备启动流程的短值。
	if voiceClientConnectTimeout < 15*time.Second {
		t.Fatalf("网络 PCM 客户端等待时间=%s，至少需要 15s", voiceClientConnectTimeout)
	}
}

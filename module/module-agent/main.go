package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	// 0.3.22：新增上网方式切换（DHCP 默认网关），支持模块上网与 Wi-Fi 上网互切。
	agentVersion = "0.3.22"
	// 监听所有本机接口以容忍 ECM 地址晚于 init 服务出现；请求层仍只放行 USB 私网与环回。
	listenAddress = "0.0.0.0:7575"
	// DATA11 桥与原厂 DATA1 完全分离，禁止重新使用 ql_manager_server 占用的 /dev/smd7。
	atDevice           = "/dev/djonehub_data11"
	cellularPolicyFile = "/data/djonehub/cellular-force-off"
)

type agent struct {
	at          *atPort
	controlOnly bool
	started     time.Time
	mu          sync.RWMutex
	modem       modemStatus
	calls       callTracker
	// 事件桥使用独立锁，阻塞等待不能占用通话状态锁。
	callEventMu       sync.Mutex
	callEventRevision uint64
	callEventChanged  chan struct{}
	messages          []storedSMS
	smsAuto           bool
	smsError          string
	gps               gpsTracker
	muted             bool
	isRecording       bool
	force4GOff        bool
	// 已应用的内核转发策略；避免后台轮询重复写入 procfs。
	cellularPolicyApplied bool
	lastApplied4GOff      bool
	voice                 voiceTracker
	esimMu                sync.Mutex
	internetMode          string
	rxStart               uint64
	txStart               uint64
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--startup-probe" {
		// 使用最早可见标记，区分包初始化崩溃与 main 内部崩溃。
		fmt.Println("启动探针标记: main-entry")
	}
	logger := log.New(os.Stdout, "qdc507-agent: ", log.LstdFlags|log.LUTC)
	probed, err := runStartupProbe(logger)
	if err != nil {
		logger.Fatalf("启动探针失败: %v", err)
	}
	if probed {
		return
	}

	controlOnly := len(os.Args) == 2 && os.Args[1] == "--control-only"
	service := &agent{started: time.Now(), smsAuto: true, controlOnly: controlOnly}
	service.force4GOff = loadCellularPolicy(cellularPolicyFile)
	if !controlOnly {
		service.at = newATPort(atDevice)
		if err := service.at.open(); err != nil {
			logger.Fatalf("无法打开基带 AT 端口: %v", err)
		}
		defer service.at.close()
	}

	service.rxStart, service.txStart, _ = readInterfaceCounters("ecm0")
	service.internetMode = loadInternetMode(internetModeFile)
	// 原厂服务刚释放 SMD 端口时，首轮 AT 查询可能需要几十秒。
	// 先启动 HTTP 服务，再由轮询协程刷新状态，避免 iPad 把慢启动误判成代理离线。
	if !controlOnly {
		go service.pollLoop()
		// 旧启动钩子不认识上网方式持久化文件；Agent 启动后自行纠正 dnsmasq。
		go service.applyStartupDHCPMode(logger)
	}

	server := &http.Server{
		Addr:              listenAddress,
		Handler:           service.routes(logger),
		ReadHeaderTimeout: 3 * time.Second,
		// 更新包约 3 MB，iOS USB ECM 慢速链路超过 15 秒并不异常。
		ReadTimeout:  190 * time.Second,
		WriteTimeout: 190 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		// 给正在返回结果的控制请求留出短暂完成时间。
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	logger.Printf("监听 %s，版本 %s control_only=%t", listenAddress, agentVersion, controlOnly)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("HTTP 服务退出: %v", err)
	}
}

// runStartupProbe 分阶段验证启动路径，不发送 AT 指令，也不改变模块网络状态。
func runStartupProbe(logger *log.Logger) (bool, error) {
	if len(os.Args) == 1 || os.Args[1] != "--startup-probe" {
		return false, nil
	}
	if len(os.Args) != 3 {
		return true, errors.New("用法: --startup-probe runtime|routes|listen|at-open|esim-read")
	}

	fmt.Println("启动探针标记: stage-entry")
	service := &agent{at: newATPort(atDevice), started: time.Now(), smsAuto: true}
	fmt.Println("启动探针标记: service-created")
	switch os.Args[2] {
	case "runtime":
		// 部署器据此核对 Agent 内嵌白名单与同批 helper，阻止错配产物提交。
		fmt.Printf("__VOICE_HELPER_SHA256__%s\n", voiceHelperSHA256)
		logger.Printf("启动探针通过: runtime")
	case "routes":
		_ = service.routes(logger)
		logger.Printf("启动探针通过: routes")
	case "listen":
		listener, err := net.Listen("tcp", listenAddress)
		if err != nil {
			return true, fmt.Errorf("监听 %s 失败: %w", listenAddress, err)
		}
		if err := listener.Close(); err != nil {
			return true, fmt.Errorf("关闭探针监听失败: %w", err)
		}
		logger.Printf("启动探针通过: listen")
	case "at-open":
		if err := service.at.open(); err != nil {
			return true, err
		}
		if err := service.at.close(); err != nil {
			return true, err
		}
		logger.Printf("启动探针通过: at-open")
	case "esim-read":
		// 直接读取 LPA，避免 HTTP 服务的通话/短信轮询与 eUICC APDU 争用同一 AT 端口。
		if err := service.at.open(); err != nil {
			return true, err
		}
		defer service.at.close()
		overview, err := service.readESIMOverview()
		if err != nil {
			return true, err
		}
		encoded, err := json.Marshal(overview)
		if err != nil {
			return true, fmt.Errorf("编码 eSIM 总览失败: %w", err)
		}
		fmt.Printf("__ESIM_OVERVIEW__%s\n", encoded)
		logger.Printf("启动探针通过: esim-read")
	default:
		return true, fmt.Errorf("未知启动探针阶段: %s", os.Args[2])
	}
	return true, nil
}

func (a *agent) routes(logger *log.Logger) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", a.health)
	mux.HandleFunc("/api/platform", a.platform)
	mux.HandleFunc("/api/status", a.status)
	mux.HandleFunc("/api/calls/status", a.callStatus)
	mux.HandleFunc("/api/calls/events", a.callEvents)
	mux.HandleFunc("/api/calls/history/ack", a.callHistoryAck)
	mux.HandleFunc("/api/calls/dial", a.dial)
	mux.HandleFunc("/api/calls/answer", a.answer)
	mux.HandleFunc("/api/calls/reject", a.reject)
	mux.HandleFunc("/api/calls/hangup", a.hangup)
	mux.HandleFunc("/api/calls/dtmf", a.dtmf)
	mux.HandleFunc("/api/calls/audio/mute", a.mute)
	mux.HandleFunc("/api/calls/audio/record", a.recording)
	mux.HandleFunc("/api/calls/audio/host/warmup", a.audioHostWarmup)
	mux.HandleFunc("/api/calls/audio/host/register", a.audioHostRegister)
	mux.HandleFunc("/api/calls/audio/host/config", a.audioHostConfig)
	mux.HandleFunc("/api/sms", a.smsList)
	mux.HandleFunc("/api/sms/status", a.smsStatus)
	mux.HandleFunc("/api/sms/send", a.smsSend)
	mux.HandleFunc("/api/sms/refresh", a.smsRefresh)
	mux.HandleFunc("/api/sms/ack", a.smsAck)
	mux.HandleFunc("/api/sms/settings", a.smsSettings)
	mux.HandleFunc("/api/sms/clear-module", a.smsClear)
	mux.HandleFunc("/api/sim/identity", a.simIdentity)
	mux.HandleFunc("/api/network/traffic", a.networkTraffic)
	mux.HandleFunc("/api/network/cellular-policy", a.cellularPolicy)
	mux.HandleFunc("/api/network/check-4g", a.check4G)
	mux.HandleFunc("/api/network/check-proxy", a.checkProxy)
	mux.HandleFunc("/api/network/internet-mode", a.internetModeHandler)
	mux.HandleFunc("/api/network/reboot-module", a.rebootModule)
	mux.HandleFunc("/api/network", a.networkDiagnostic)
	mux.HandleFunc("/api/system/power", a.systemPower)
	mux.HandleFunc("/api/usb/profile", a.usbProfile)
	mux.HandleFunc("/api/gps", a.gpsStatus)
	mux.HandleFunc("/api/gps/start", a.gpsStart)
	mux.HandleFunc("/api/gps/stop", a.gpsStop)
	mux.HandleFunc("/api/gps/refresh", a.gpsRefresh)
	mux.HandleFunc("/api/at", a.executeAT)
	mux.HandleFunc("/api/esim", a.esimOverview)
	mux.HandleFunc("/api/esim/health", a.esimHealth)
	mux.HandleFunc("/api/esim/notes", a.esimNotes)
	mux.HandleFunc("/api/esim/phonebook/probe", a.esimPhonebookProbe)
	mux.HandleFunc("/api/esim/switch", a.esimSwitch)
	mux.HandleFunc("/api/esim/profile", a.esimProfile)
	mux.HandleFunc("/api/esim/download", a.esimDownload)
	mux.HandleFunc("/api/module/setup", a.moduleSetup)
	mux.HandleFunc("/api/voice/status", a.voiceStatus)
	mux.HandleFunc("/api/voice/provision", a.voiceProvision)
	mux.HandleFunc("/api/system/update", a.systemUpdate)
	mux.HandleFunc("/api/service/shutdown", a.shutdown)

	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		started := time.Now()
		response.Header().Set("Content-Type", "application/json; charset=utf-8")
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")
		response.Header().Set("X-Frame-Options", "DENY")
		response.Header().Set("Referrer-Policy", "no-referrer")
		if !allowedRemote(request.RemoteAddr) {
			writeError(response, http.StatusForbidden, "只允许 USB 本地网络访问")
			return
		}
		if a.controlOnly && request.URL.Path != "/api/health" &&
			request.URL.Path != "/api/platform" &&
			request.URL.Path != "/api/calls/status" &&
			request.URL.Path != "/api/calls/events" &&
			request.URL.Path != "/api/usb/profile" {
			writeError(response, http.StatusServiceUnavailable, "模块正在等待切换为手机直连模式")
			return
		}
		mux.ServeHTTP(response, request)
		logger.Printf("%s %s %s", request.Method, request.URL.Path, time.Since(started).Round(time.Millisecond))
	})
}

// allowedRemote 把控制面限制在模块自身和 CDC ECM 子网。
func allowedRemote(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	v4 := ip.To4()
	return v4 != nil && v4[0] == 192 && v4[1] == 168 && v4[2] == 225
}

func (a *agent) pollLoop() {
	// Agent 重启后恢复用户选择的关闭数据策略，但保留 IMS 与语音注册。
	a.enforceCellularPolicy()
	callTicker := time.NewTicker(time.Second)
	modemTicker := time.NewTicker(5 * time.Second)
	smsTicker := time.NewTicker(8 * time.Second)
	defer callTicker.Stop()
	defer modemTicker.Stop()
	defer smsTicker.Stop()
	for {
		select {
		case <-callTicker.C:
			a.refreshCalls()
			// 通话过程中语音桥可能因内核设备短暂不可用而退出；只要通话仍在，下一轮主动恢复媒体链路。
			a.maintainVoiceRoute()
		case <-modemTicker.C:
			a.refreshModem()
			a.enforceCellularPolicy()
		case <-smsTicker.C:
			a.refreshSMS()
		}
	}
}

func (a *agent) health(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	lastError := a.modem.LastError
	a.mu.RUnlock()
	writeJSON(response, http.StatusOK, map[string]any{
		"ok":              lastError == "",
		"version":         agentVersion,
		"platform":        "qdc507-armv7",
		"at_device":       atDevice,
		"uptime_seconds":  int(time.Since(a.started).Seconds()),
		"last_poll_error": lastError,
	})
}

func (a *agent) platform(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"os": "linux", "version": agentVersion, "direct_module": true,
		"call_audio": true, "direct_usb_at": false, "native_contacts": true,
		"network_policy_native": true, "esim_full": false,
	})
}

func (a *agent) status(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	status := a.modem
	a.mu.RUnlock()
	writeJSON(response, http.StatusOK, status)
}

func (a *agent) networkTraffic(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	rx, tx, err := readInterfaceCounters("ecm0")
	if err != nil {
		writeJSON(response, http.StatusOK, map[string]any{"available": false, "error": err.Error()})
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"available": true, "interface": "ecm0", "rx_bytes": rx, "tx_bytes": tx,
		"session_rx_bytes": rx - min(rx, a.rxStart), "session_tx_bytes": tx - min(tx, a.txStart),
		"session_total_bytes": rx - min(rx, a.rxStart) + tx - min(tx, a.txStart),
		"sampled_at_ms":       time.Now().UnixMilli(),
	})
}

func readInterfaceCounters(name string) (uint64, uint64, error) {
	read := func(counter string) (uint64, error) {
		data, err := os.ReadFile(filepath.Join("/sys/class/net", name, "statistics", counter))
		if err != nil {
			return 0, err
		}
		return strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
	}
	rx, err := read("rx_bytes")
	if err != nil {
		return 0, 0, err
	}
	tx, err := read("tx_bytes")
	return rx, tx, err
}

func min(a, b uint64) uint64 {
	if a < b {
		return a
	}
	return b
}

func requireMethod(response http.ResponseWriter, request *http.Request, methods ...string) bool {
	for _, method := range methods {
		if request.Method == method {
			return true
		}
	}
	writeError(response, http.StatusMethodNotAllowed, "请求方法不受支持")
	return false
}

func decodeJSON(response http.ResponseWriter, request *http.Request, target any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeError(response, http.StatusBadRequest, "JSON 请求无效: "+err.Error())
		return false
	}
	return true
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func writeError(response http.ResponseWriter, status int, message string) {
	writeJSON(response, status, map[string]string{"error": message})
}

func (a *agent) unsupported(response http.ResponseWriter, message string) {
	writeError(response, http.StatusNotImplemented, message)
}

func commandValue(response string, prefix string) string {
	for _, line := range strings.Split(response, "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

func parseInt(value string) int {
	number, _ := strconv.Atoi(strings.TrimSpace(value))
	return number
}

func splitCSV(value string) []string {
	var fields []string
	var current strings.Builder
	quoted := false
	for _, character := range value {
		switch character {
		case '"':
			quoted = !quoted
		case ',':
			if !quoted {
				fields = append(fields, strings.TrimSpace(current.String()))
				current.Reset()
				continue
			}
			current.WriteRune(character)
		default:
			current.WriteRune(character)
		}
	}
	fields = append(fields, strings.TrimSpace(current.String()))
	return fields
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func firstLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && line != "OK" && !strings.HasPrefix(line, "AT") {
			return line
		}
	}
	return ""
}

func formatError(operation string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", operation, err)
}

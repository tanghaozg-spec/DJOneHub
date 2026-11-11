package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// 上网方式切换：通过 dnsmasq 是否强制下发 DHCP Router（选项 3）决定
// 手机插着模块时，默认上网出口走模块 4G 还是保留给 Wi-Fi。
// 通话、短信与控制面始终通过 192.168.225.0/24 USB 私网，与该模式无关。
const (
	internetModeModule = "module" // 现有默认行为：模块作为手机默认网关，手机使用模块 4G 流量上网。
	internetModeWiFi   = "wifi"   // 不下发默认网关：手机上网继续走 Wi-Fi，模块只承载通话/短信/控制。
)

var internetModeFile = "/data/djonehub/dhcp-internet-mode"

const (
	dnsmasqBinaryPath = "/usr/bin/dnsmasq"
	// 与启动钩子完全一致的原厂参数；wifi 模式 = 原厂参数，module 模式仅追加选项 3。
	dhcpRangeOption  = "--dhcp-range=bridge0,192.168.225.20,192.168.225.30,255.255.255.0,43200"
	dhcpDNSOption    = "--dhcp-option-force=6,192.168.225.1"
	dhcpSIPOption    = "--dhcp-option-force=120,abcd.com"
	dhcpRouterOption = "--dhcp-option-force=3,192.168.225.1"
)

// dhcpArgsForMode 返回 dnsmasq 二进制之后的完整参数；独立为纯函数便于单元测试。
func dhcpArgsForMode(mode string) []string {
	args := []string{"-i", "bridge0", "-I", "lo", "-z", dhcpRangeOption}
	if mode == internetModeModule {
		args = append(args, dhcpRouterOption)
	}
	args = append(args, dhcpDNSOption, dhcpSIPOption)
	return args
}

// dnsmasqCommandLineForMode 返回与 /proc/<pid>/cmdline 归一化结果可比较的完整命令行。
// 与启动钩子一致：参数间以单空格连接，末尾保留一个空格。
func dnsmasqCommandLineForMode(mode string) string {
	return dnsmasqBinaryPath + " " + strings.Join(dhcpArgsForMode(mode), " ") + " "
}

// normalizeProcCmdline 把 /proc/<pid>/cmdline 的 NUL 分隔参数归一化为单空格字符串。
func normalizeProcCmdline(data []byte) string {
	return strings.ReplaceAll(string(data), "\x00", " ")
}

// canonicalDHCPCommandLine 去掉可选的 /usr/bin/ 绝对路径前缀。
// 原厂以裸名 dnsmasq 启动，启动钩子以 /usr/bin/dnsmasq 启动，/proc 命令行两者都可能出现。
func canonicalDHCPCommandLine(commandLine string) string {
	trimmed := strings.TrimSpace(commandLine)
	return strings.TrimPrefix(trimmed, dnsmasqBinaryPath+" ")
}

// validateKnownDHCPCommandLine 只允许替换已验证的两种 dnsmasq 配置，
// 未知固件或用户自定义 DHCP 服务一律拒绝，避免破坏模块网络。
// canonical 已去掉二进制前缀，因此与“仅参数序列”比较。
func validateKnownDHCPCommandLine(commandLine string) (mode string, err error) {
	canonical := canonicalDHCPCommandLine(commandLine)
	switch canonical {
	case strings.Join(dhcpArgsForMode(internetModeWiFi), " "):
		return internetModeWiFi, nil
	case strings.Join(dhcpArgsForMode(internetModeModule), " "):
		return internetModeModule, nil
	default:
		return "", fmt.Errorf("dnsmasq 命令行不是已验证的 QDC507 配置，拒绝替换")
	}
}

// currentDHCPCommandLine 读取正在运行的 dnsmasq 命令行；要求单实例。
func currentDHCPCommandLine() (string, error) {
	out, err := exec.Command("pidof", "dnsmasq").Output()
	if err != nil || len(strings.Fields(string(out))) != 1 {
		return "", fmt.Errorf("dnsmasq 未运行或存在多个实例")
	}
	pid := strings.TrimSpace(string(out))
	data, err := os.ReadFile("/proc/" + pid + "/cmdline")
	if err != nil {
		return "", fmt.Errorf("读取 dnsmasq 命令行失败: %w", err)
	}
	return normalizeProcCmdline(data), nil
}

// restartDHCPForMode 把运行中的 dnsmasq 切换为目标模式；已在目标模式时返回 applied=false。
func restartDHCPForMode(mode string) (bool, error) {
	commandLine, err := currentDHCPCommandLine()
	if err != nil {
		return false, err
	}
	currentMode, err := validateKnownDHCPCommandLine(commandLine)
	if err != nil {
		return false, err
	}
	if currentMode == mode {
		return false, nil
	}
	// 先持久化再杀进程；杀掉旧实例后立即启动新实例，间隙内手机续租请求会失败并自动重试。
	if out, err := exec.Command("pidof", "dnsmasq").Output(); err == nil {
		if pid := strings.TrimSpace(string(out)); pid != "" {
			_ = exec.Command("kill", "-TERM", pid).Run()
		}
	}
	waited := 0
	for waited < 30 {
		if out, err := exec.Command("pidof", "dnsmasq").Output(); err != nil || strings.TrimSpace(string(out)) == "" {
			break
		}
		time.Sleep(100 * time.Millisecond)
		waited++
	}
	command := exec.Command(dnsmasqBinaryPath, dhcpArgsForMode(mode)...)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return false, fmt.Errorf("启动 dnsmasq 失败: %w", err)
	}
	// 无论 dnsmasq 自行守护进程化还是前台运行，都由后台协程回收子进程。
	go func() { _ = command.Wait() }()
	return true, nil
}

// bounceECM 让 ecm0 短暂 down/up，触发手机立即重新发起 DHCP，从而拿到新的网关选项。
// 响应已先返回给 App，这里失败仅记录日志；重新插拔 USB 总能让新模式生效。
func bounceECM() {
	script := "ifconfig ecm0 down >/dev/null 2>&1; sleep 1; ifconfig ecm0 up >/dev/null 2>&1"
	command := exec.Command("/bin/sh", "-c", script)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		log.Printf("触发 ecm0 重新协商失败: %v", err)
		return
	}
	go func() {
		if err := command.Wait(); err != nil {
			log.Printf("ecm0 重新协商退出异常: %v", err)
		}
	}()
}

func loadInternetMode(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return internetModeModule
	}
	mode := strings.TrimSpace(string(data))
	if mode != internetModeWiFi && mode != internetModeModule {
		return internetModeModule
	}
	return mode
}

func saveInternetMode(path string, mode string) error {
	temporary := path + ".new"
	if err := os.WriteFile(temporary, []byte(mode+"\n"), 0o600); err != nil {
		return fmt.Errorf("保存上网方式失败: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("提交上网方式失败: %w", err)
	}
	return nil
}

// applyStartupDHCPMode 在 Agent 启动后按持久化模式纠正 dnsmasq。
// 更新包只替换 Agent 二进制，旧启动钩子仍会强制下发网关；这里兜底保证 Wi-Fi 模式立即生效。
func (a *agent) applyStartupDHCPMode(logger *log.Logger) {
	// 启动钩子此刻可能还在等待原厂 dnsmasq 出现；轮询最多 10 秒。
	mode := loadInternetMode(internetModeFile)
	for attempt := 0; attempt < 100; attempt++ {
		commandLine, err := currentDHCPCommandLine()
		if err == nil {
			currentMode, matchErr := validateKnownDHCPCommandLine(commandLine)
			if matchErr == nil {
				if currentMode != mode {
					applied, restartErr := restartDHCPForMode(mode)
					if restartErr != nil {
						logger.Printf("按持久化配置切换上网方式失败: %v", restartErr)
						return
					}
					logger.Printf("已按持久化配置应用上网方式 mode=%s applied=%t", mode, applied)
					if applied {
						// 手机可能已经拿到带默认网关的旧租约；抖动 ecm0 促使其立即重新租约。
						bounceECM()
					}
				}
				return
			}
			// 未知 dnsmasq 配置交由启动钩子处理，Agent 不越权替换。
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (a *agent) internetModeHandler(response http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		a.mu.RLock()
		mode := a.internetMode
		a.mu.RUnlock()
		writeJSON(response, http.StatusOK, map[string]any{
			"supported": true, "mode": mode,
			"options": []string{internetModeWiFi, internetModeModule},
		})
	case http.MethodPost:
		a.mu.RLock()
		callActive := a.calls.Active != nil
		current := a.internetMode
		a.mu.RUnlock()
		if callActive {
			writeError(response, http.StatusConflict, "通话进行中不能切换上网方式，请先挂断")
			return
		}
		var body struct {
			Mode string `json:"mode"`
		}
		if !decodeJSON(response, request, &body) {
			return
		}
		mode := strings.ToLower(strings.TrimSpace(body.Mode))
		if mode != internetModeWiFi && mode != internetModeModule {
			writeError(response, http.StatusBadRequest, "mode 必须是 wifi 或 module")
			return
		}
		if err := saveInternetMode(internetModeFile, mode); err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		a.mu.Lock()
		a.internetMode = mode
		a.mu.Unlock()

		applied := false
		note := ""
		if appliedAny, err := restartDHCPForMode(mode); err == nil {
			applied = appliedAny
		} else {
			note = err.Error()
		}
		message := "已切换为模块上网：手机使用模块 4G 流量；通话与短信不受影响"
		if mode == internetModeWiFi {
			message = "已切换为 Wi-Fi 上网：手机继续使用 Wi-Fi；通话与短信仍通过模块"
		}
		if !applied {
			if note != "" {
				message += "；本次未能立即生效（" + note + "），重新插拔 USB 后生效"
			} else {
				message += "；重新插拔 USB 后生效"
			}
		} else {
			// 先把响应发回 App，再短暂抖动 ecm0 促使手机立刻重新租约；期间控制面会中断 1-2 秒。
			message += "；模块网络将短暂中断"
			go func() {
				time.Sleep(400 * time.Millisecond)
				bounceECM()
			}()
		}
		writeJSON(response, http.StatusOK, map[string]any{
			"mode": mode, "previous": current, "applied": applied, "message": message,
		})
	default:
		requireMethod(response, request, http.MethodGet, http.MethodPost)
	}
}

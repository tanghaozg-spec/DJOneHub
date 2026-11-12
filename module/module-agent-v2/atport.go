package main

// AT 传输层：二代模块（DJI Cellular Dongle 2 / Fibocom NL668T-GL）内部串口设备名
// 未经实机验证，因此运行时自动探测候选设备，也可用环境变量 DJONEHUB2_AT_DEV 强制指定。
// 协议采用标准 3GPP TS 27.007 / 27.005，避免绑定某厂商私有命令。

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type ATPort struct {
	mu   sync.Mutex
	file *os.File
	dev  string

	pending *pendingCommand

	urcMu   sync.Mutex
	urcBuf  []string
	urcCond *sync.Cond

	lastError string
}

type pendingCommand struct {
	lines   []string
	done    chan struct{}
	err     error
	timeout time.Duration
}

// 已知 URC 前缀：即使命令在途也归入 URC 通道，不污染命令应答。
var urcPrefixes = []string{
	"+CMTI:", "+CMT:", "+CBM:", "+CDS:", "+CLIP:", "+COLP:", "RING", "NO CARRIER",
	"+CRING:", "+CLCC:", "^ORIG:", "^CONF:", "^CEND:", "+CEREG:", "+CREG:", "+CGREG:",
}

func isURCLine(line string) bool {
	for _, prefix := range urcPrefixes {
		if strings.HasPrefix(line, prefix) {
			return true
		}
	}
	return false
}

var cmeErrorPattern = regexp.MustCompile(`^\+(CME|CMS) ERROR: (.+)$`)

// candidateSerialDevices 列出可能的 AT 串口设备。
// Fibocom/UNISOC 平台常见 ttyUSB/ttyHS/ttyACM；保留 smd 以兼容混用场景。
func candidateSerialDevices() []string {
	patterns := []string{
		"/dev/ttyUSB*",
		"/dev/ttyHS*",
		"/dev/ttyACM*",
		"/dev/ttyXRUSB*",
	}
	var devices []string
	for _, pattern := range patterns {
		matches, _ := filepath.Glob(pattern)
		devices = append(devices, matches...)
	}
	return devices
}

// DetectATPort 在候选串口里找到响应 "AT" 的端口。
func DetectATPort(forced string) (*ATPort, error) {
	var devices []string
	if forced != "" {
		devices = []string{forced}
	} else {
		devices = candidateSerialDevices()
	}
	var lastErr error
	for _, dev := range devices {
		port, err := OpenATPort(dev)
		if err != nil {
			lastErr = err
			continue
		}
		lines, err := port.Command("AT", 2*time.Second)
		if err == nil {
			return port, nil
		}
		port.Close()
		if err.Error() == "timeout" {
			// 能打开但无应答的端口（如纯诊断口）记录后继续。
			lastErr = fmt.Errorf("%s: 无 AT 应答", dev)
		} else {
			lastErr = err
		}
	}
	return nil, fmt.Errorf("未找到 AT 端口（候选 %v）: %w", devices, lastErr)
}

func OpenATPort(dev string) (*ATPort, error) {
	file, err := os.OpenFile(dev, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("打开 %s 失败: %w", dev, err)
	}
	port := &ATPort{file: file, dev: dev}
	port.urcCond = sync.NewCond(&port.urcMu)
	go port.readerLoop()
	// 关回显并使用数字化错误码增强可解析性；失败不致命。
	_, _ = port.Command("ATE0", 2*time.Second)
	_, _ = port.Command("AT+CMEE=1", 2*time.Second)
	return port, nil
}

func (p *ATPort) readerLoop() {
	scanner := bufio.NewScanner(p.file)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r\n")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		p.deliver(line)
	}
	err := scanner.Err()
	p.mu.Lock()
	p.lastError = fmt.Sprintf("串口读取结束: %v", err)
	pending := p.pending
	if pending != nil {
		pending.err = errors.New("串口已关闭")
		close(pending.done)
		p.pending = nil
	}
	p.mu.Unlock()
}

func (p *ATPort) deliver(line string) {
	p.mu.Lock()
	if p.pending != nil && !isURCLine(line) {
		switch {
		case line == "OK":
			close(p.pending.done)
			p.pending = nil
			p.mu.Unlock()
			return
		case line == "ERROR":
			p.pending.err = errors.New("ERROR")
			close(p.pending.done)
			p.pending = nil
			p.mu.Unlock()
			return
		}
		if match := cmeErrorPattern.FindStringSubmatch(line); match != nil {
			p.pending.err = errors.New(match[2])
			close(p.pending.done)
			p.pending = nil
			p.mu.Unlock()
			return
		}
		p.pending.lines = append(p.pending.lines, line)
		p.mu.Unlock()
		return
	}
	p.mu.Unlock()

	if isURCLine(line) {
		p.urcMu.Lock()
		p.urcBuf = append(p.urcBuf, line)
		if len(p.urcBuf) > 256 {
			p.urcBuf = p.urcBuf[len(p.urcBuf)-256:]
		}
		p.urcCond.Broadcast()
		p.urcMu.Unlock()
	}
	// 其余非 URC 行（命令回显等）在 ATE0 后应消失；如出现则丢弃。
}

// Command 发送一条 AT 命令并收集应答行（不含 OK/ERROR）。
func (p *ATPort) Command(command string, timeout time.Duration) ([]string, error) {
	p.mu.Lock()
	if p.pending != nil {
		p.mu.Unlock()
		return nil, errors.New("上一条 AT 命令仍在处理中")
	}
	pending := &pendingCommand{done: make(chan struct{}), timeout: timeout}
	p.pending = pending
	if _, err := p.file.WriteString(command + "\r\n"); err != nil {
		p.pending = nil
		p.mu.Unlock()
		return nil, fmt.Errorf("写入 %s 失败: %w", p.dev, err)
	}
	p.mu.Unlock()

	select {
	case <-pending.done:
		return pending.lines, pending.err
	case <-time.After(timeout):
		p.mu.Lock()
		if p.pending == pending {
			p.pending = nil
		}
		p.mu.Unlock()
		return pending.lines, errors.New("timeout")
	}
}

// WaitURC 阻塞等待出现匹配前缀的 URC（或超时），返回最近匹配行。
func (p *ATPort) WaitURC(prefix string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	p.urcMu.Lock()
	defer p.urcMu.Unlock()
	for {
		for i := len(p.urcBuf) - 1; i >= 0; i-- {
			if strings.HasPrefix(p.urcBuf[i], prefix) {
				line := p.urcBuf[i]
				p.urcBuf = append(p.urcBuf[:i], p.urcBuf[i+1:]...)
				return line, nil
			}
		}
		if time.Now().After(deadline) {
			return "", errors.New("等待 URC 超时: " + prefix)
		}
		go func() { time.Sleep(200 * time.Millisecond); p.urcCond.Broadcast() }()
		p.urcCond.Wait()
	}
}

func (p *ATPort) DrainURCs() []string {
	p.urcMu.Lock()
	defer p.urcMu.Unlock()
	lines := append([]string(nil), p.urcBuf...)
	p.urcBuf = nil
	return lines
}

func (p *ATPort) Device() string { return p.dev }

func (p *ATPort) Close() error {
	return p.file.Close()
}

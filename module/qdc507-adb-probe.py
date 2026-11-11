#!/usr/bin/env python3
"""通过 QDC507 的 USB ADB 接口执行固定的只读能力探测。"""

from __future__ import annotations

import base64
import ctypes
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


# 默认使用 DJOneHub 已安装的 libusb；Windows/Linux 等环境可用
# DJONEHUB_LIBUSB 指定本地 libusb-1.0.dll / .so / .dylib 路径。
LIBUSB_PATH = Path(
    os.environ.get(
        "DJONEHUB_LIBUSB",
        "/Users/jieden/Library/Application Support/DJOneHub/runtime/lib/libusb-1.0.0.dylib",
    )
)
USB_VENDOR_ID = 0x2C7C
USB_PRODUCT_ID = 0x0125
USB_TIMEOUT_MS = 10_000


class LibusbEndpointDescriptor(ctypes.Structure):
    """对应 libusb_endpoint_descriptor，只声明探测所需的标准字段。"""

    _fields_ = [
        ("bLength", ctypes.c_uint8),
        ("bDescriptorType", ctypes.c_uint8),
        ("bEndpointAddress", ctypes.c_uint8),
        ("bmAttributes", ctypes.c_uint8),
        ("wMaxPacketSize", ctypes.c_uint16),
        ("bInterval", ctypes.c_uint8),
        ("bRefresh", ctypes.c_uint8),
        ("bSynchAddress", ctypes.c_uint8),
        ("extra", ctypes.POINTER(ctypes.c_ubyte)),
        ("extra_length", ctypes.c_int),
    ]


class LibusbInterfaceDescriptor(ctypes.Structure):
    """对应 libusb_interface_descriptor，用于识别标准 ADB FF/42/01 接口。"""

    _fields_ = [
        ("bLength", ctypes.c_uint8),
        ("bDescriptorType", ctypes.c_uint8),
        ("bInterfaceNumber", ctypes.c_uint8),
        ("bAlternateSetting", ctypes.c_uint8),
        ("bNumEndpoints", ctypes.c_uint8),
        ("bInterfaceClass", ctypes.c_uint8),
        ("bInterfaceSubClass", ctypes.c_uint8),
        ("bInterfaceProtocol", ctypes.c_uint8),
        ("iInterface", ctypes.c_uint8),
        ("endpoint", ctypes.POINTER(LibusbEndpointDescriptor)),
        ("extra", ctypes.POINTER(ctypes.c_ubyte)),
        ("extra_length", ctypes.c_int),
    ]


class LibusbInterface(ctypes.Structure):
    """对应 libusb_interface，接口可包含多个 alternate setting。"""

    _fields_ = [
        ("altsetting", ctypes.POINTER(LibusbInterfaceDescriptor)),
        ("num_altsetting", ctypes.c_int),
    ]


class LibusbConfigDescriptor(ctypes.Structure):
    """对应 libusb_config_descriptor，用于遍历当前 USB 组合的所有接口。"""

    _fields_ = [
        ("bLength", ctypes.c_uint8),
        ("bDescriptorType", ctypes.c_uint8),
        ("wTotalLength", ctypes.c_uint16),
        ("bNumInterfaces", ctypes.c_uint8),
        ("bConfigurationValue", ctypes.c_uint8),
        ("iConfiguration", ctypes.c_uint8),
        ("bmAttributes", ctypes.c_uint8),
        ("MaxPower", ctypes.c_uint8),
        ("interface", ctypes.POINTER(LibusbInterface)),
        ("extra", ctypes.POINTER(ctypes.c_ubyte)),
        ("extra_length", ctypes.c_int),
    ]

# 固定命令只读取系统、网络和启动能力，不写文件、不修改属性、不重启模块。
PROBE_COMMAND = r"""
echo '=== identity ==='
id
uname -a
getprop ro.product.model 2>/dev/null
getprop ro.build.version.release 2>/dev/null
getprop ro.product.cpu.abi 2>/dev/null
echo '=== network interfaces ==='
ls -l /sys/class/net 2>/dev/null
ip address 2>/dev/null || ifconfig -a 2>/dev/null
echo '=== wireless capability ==='
ls -l /sys/class/ieee80211 2>/dev/null
command -v hostapd 2>/dev/null
command -v iw 2>/dev/null
echo '=== modem and audio devices ==='
ls -l /dev 2>/dev/null | grep -E 'smd|tty|diag|apr|audio|pcm|voice' | head -n 120
echo '=== smd kernel metadata ==='
for smd_device in /sys/class/tty/smd*; do
    [ -e "$smd_device" ] || continue
    echo "--- $smd_device ---"
    readlink -f "$smd_device" 2>/dev/null
    cat "$smd_device/device/uevent" 2>/dev/null
    cat "$smd_device/device/name" 2>/dev/null
done
find /sys/kernel/debug -maxdepth 3 -type f 2>/dev/null \
    | grep -E '/smd|ipc_router' | head -n 120
echo '=== smd owners ==='
for process_dir in /proc/[0-9]*; do
    process_id=${process_dir##*/}
    process_name=$(cat "$process_dir/comm" 2>/dev/null)
    for descriptor in "$process_dir"/fd/*; do
        descriptor_target=$(readlink "$descriptor" 2>/dev/null)
        case "$descriptor_target" in
            /dev/smd*|/dev/ttyHS*|/dev/ttyGS*)
                echo "pid=$process_id process=$process_name fd=${descriptor##*/} target=$descriptor_target"
                ;;
        esac
    done
done
echo '=== service tools ==='
command -v busybox 2>/dev/null
command -v toybox 2>/dev/null
command -v start-stop-daemon 2>/dev/null
busybox --list 2>/dev/null | grep -E '^(base64|httpd|nc|strings|timeout|telnet|telnetd)$'
ls -ld /etc/init.d /system/etc/init /vendor/etc/init /data/local/tmp 2>/dev/null
echo '=== running processes ==='
ps w 2>/dev/null | head -n 160
echo '=== init scripts ==='
ls -l /etc/init.d 2>/dev/null
grep -R -n -E 'smd[0-9]|AT\+|at_port|atport|qmux|ril' /etc/init.d /etc 2>/dev/null | head -n 200
for probe_file in \
  /etc/inittab \
  /etc/init.d/start_at_cmux_le \
  /etc/init.d/start_atfwd_daemon \
  /etc/init.d/start_ql_manager_server_le \
  /etc/init.d/port_bridge \
  /etc/init.d/data-init \
  /etc/init.d/usb; do
    if [ -f "$probe_file" ]; then
        echo "--- $probe_file ---"
        sed -n '1,240p' "$probe_file"
    fi
done
echo '=== runlevel links ==='
ls -l /etc/rc5.d /etc/rcS.d 2>/dev/null | head -n 240
echo '=== vendor tools and libraries ==='
find /bin /sbin /usr/bin /usr/sbin -maxdepth 1 -type f 2>/dev/null \
    | grep -E -i '/(at|ql|qmi|ril|sms|voice|call|cmux|port)' | sort | head -n 240
find /lib /usr/lib -maxdepth 1 -type f 2>/dev/null \
    | grep -E -i '(ql|qmi|ril|at|voice|audio)' | sort | head -n 240
echo '=== vendor ipc and symbols ==='
cat /proc/net/unix 2>/dev/null | head -n 240
for binary_path in \
  /usr/bin/ql_manager_cli \
  /usr/bin/ql_manager_server \
  /usr/bin/qmi_simple_ril_test \
  /usr/lib/libql_mgmt_client.so.1.0.0; do
    echo "--- $binary_path ---"
    busybox strings "$binary_path" 2>/dev/null \
      | grep -E -i 'socket|/tmp|/var|smd7|ttyGS|manager|client|server|data_call|sms|call|voice|dial|answer|hang|qmi|ril' \
      | head -n 240
done
echo '=== vendor cli help ==='
timeout -t 3 /usr/bin/ql_manager_cli --help </dev/null 2>&1
timeout -t 3 /usr/bin/ql_manager_cli -h </dev/null 2>&1
timeout -t 3 /usr/bin/ql_manager_cli </dev/null 2>&1
timeout -t 3 /usr/bin/ql_manager_cli help </dev/null 2>&1
timeout -t 3 /usr/bin/ql_manager_cli data_call </dev/null 2>&1
timeout -t 3 /usr/bin/ql_manager_cli usb </dev/null 2>&1
(sleep 2; printf 'call_state\n'; sleep 2; printf 'quit\n') \
    | timeout -t 8 /usr/bin/qmi_simple_ril_test 2>&1
echo '=== listening sockets ==='
netstat -lntup 2>/dev/null | head -n 160
echo '=== writable storage ==='
df -h /data /usrdata /cache 2>/dev/null
echo '=== mounts ==='
cat /proc/mounts 2>/dev/null | head -n 120
""".strip()


def adb_command(value: bytes) -> int:
    """把四字节 ADB 命令转换为协议使用的小端整数。"""
    if len(value) != 4:
        raise ValueError("ADB 命令必须正好为四字节")
    return struct.unpack("<I", value)[0]


ADB_CNXN = adb_command(b"CNXN")
ADB_AUTH = adb_command(b"AUTH")
ADB_OPEN = adb_command(b"OPEN")
ADB_OKAY = adb_command(b"OKAY")
ADB_CLSE = adb_command(b"CLSE")
ADB_WRTE = adb_command(b"WRTE")


@dataclass(frozen=True)
class AdbMessage:
    command: int
    arg0: int
    arg1: int
    payload: bytes


class UsbAdbTransport:
    """只实现本次探测所需的最小 libusb 与 ADB 协议子集。"""

    def __init__(self) -> None:
        if not LIBUSB_PATH.is_file():
            raise RuntimeError(f"未找到 DJOneHub libusb：{LIBUSB_PATH}")

        self._usb = ctypes.CDLL(str(LIBUSB_PATH))
        self._context = ctypes.c_void_p()
        self._handle = ctypes.c_void_p()
        self._interface_number: int | None = None
        self._endpoint_out: int | None = None
        self._endpoint_in: int | None = None
        self._configure_libusb_signatures()

    def _configure_libusb_signatures(self) -> None:
        """声明本脚本调用到的 libusb C 函数签名。"""
        self._usb.libusb_init.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        self._usb.libusb_init.restype = ctypes.c_int
        self._usb.libusb_exit.argtypes = [ctypes.c_void_p]
        self._usb.libusb_exit.restype = None
        self._usb.libusb_open_device_with_vid_pid.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint16,
            ctypes.c_uint16,
        ]
        self._usb.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
        self._usb.libusb_get_device.argtypes = [ctypes.c_void_p]
        self._usb.libusb_get_device.restype = ctypes.c_void_p
        self._usb.libusb_get_active_config_descriptor.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.POINTER(LibusbConfigDescriptor)),
        ]
        self._usb.libusb_get_active_config_descriptor.restype = ctypes.c_int
        self._usb.libusb_free_config_descriptor.argtypes = [
            ctypes.POINTER(LibusbConfigDescriptor)
        ]
        self._usb.libusb_free_config_descriptor.restype = None
        self._usb.libusb_claim_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self._usb.libusb_claim_interface.restype = ctypes.c_int
        self._usb.libusb_release_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self._usb.libusb_release_interface.restype = ctypes.c_int
        self._usb.libusb_close.argtypes = [ctypes.c_void_p]
        self._usb.libusb_close.restype = None
        self._usb.libusb_bulk_transfer.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ubyte,
            ctypes.POINTER(ctypes.c_ubyte),
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int),
            ctypes.c_uint,
        ]
        self._usb.libusb_bulk_transfer.restype = ctypes.c_int
        self._usb.libusb_error_name.argtypes = [ctypes.c_int]
        self._usb.libusb_error_name.restype = ctypes.c_char_p

    def _error_name(self, result: int) -> str:
        """把 libusb 错误码转换为稳定的英文错误名。"""
        raw_name = self._usb.libusb_error_name(result)
        return raw_name.decode("ascii", errors="replace") if raw_name else str(result)

    def _discover_adb_interface(self) -> tuple[int, int, int]:
        """从活动配置动态寻找 ADB 接口，兼容 Mac 与移动 USB 组合的编号变化。"""
        device = self._usb.libusb_get_device(self._handle)
        if not device:
            raise RuntimeError("无法读取 QDC507 的 libusb 设备句柄")

        config = ctypes.POINTER(LibusbConfigDescriptor)()
        result = self._usb.libusb_get_active_config_descriptor(device, ctypes.byref(config))
        if result != 0:
            raise RuntimeError(f"读取 USB 活动配置失败：{self._error_name(result)}")

        seen: list[str] = []
        try:
            descriptor = config.contents
            for interface_index in range(descriptor.bNumInterfaces):
                interface = descriptor.interface[interface_index]
                for alternate_index in range(interface.num_altsetting):
                    alternate = interface.altsetting[alternate_index]
                    seen.append(
                        f"{alternate.bInterfaceNumber}:"
                        f"{alternate.bInterfaceClass:02x}/"
                        f"{alternate.bInterfaceSubClass:02x}/"
                        f"{alternate.bInterfaceProtocol:02x}"
                    )
                    if (
                        alternate.bInterfaceClass,
                        alternate.bInterfaceSubClass,
                        alternate.bInterfaceProtocol,
                    ) != (0xFF, 0x42, 0x01):
                        continue

                    endpoint_out: int | None = None
                    endpoint_in: int | None = None
                    for endpoint_index in range(alternate.bNumEndpoints):
                        endpoint = alternate.endpoint[endpoint_index]
                        # ADB 只使用 Bulk 端点；方向位 0x80 用于区分 IN 与 OUT。
                        if endpoint.bmAttributes & 0x03 != 0x02:
                            continue
                        if endpoint.bEndpointAddress & 0x80:
                            endpoint_in = endpoint.bEndpointAddress
                        else:
                            endpoint_out = endpoint.bEndpointAddress
                    if endpoint_out is not None and endpoint_in is not None:
                        return alternate.bInterfaceNumber, endpoint_out, endpoint_in
        finally:
            self._usb.libusb_free_config_descriptor(config)

        interfaces = ", ".join(seen) if seen else "无接口"
        raise RuntimeError(f"当前 USB 组合没有 ADB FF/42/01 接口；已枚举：{interfaces}")

    def open(self) -> None:
        """打开目标设备，并按描述符声明当前组合里的 ADB 接口。"""
        result = self._usb.libusb_init(ctypes.byref(self._context))
        if result != 0:
            raise RuntimeError(f"libusb_init 失败：{self._error_name(result)}")

        raw_handle = self._usb.libusb_open_device_with_vid_pid(
            self._context, USB_VENDOR_ID, USB_PRODUCT_ID
        )
        if not raw_handle:
            raise RuntimeError("未发现 QDC507 USB 设备 2c7c:0125")
        self._handle = ctypes.c_void_p(raw_handle)

        (
            self._interface_number,
            self._endpoint_out,
            self._endpoint_in,
        ) = self._discover_adb_interface()
        result = self._usb.libusb_claim_interface(self._handle, self._interface_number)
        if result != 0:
            raise RuntimeError(
                f"无法声明 ADB interface {self._interface_number}："
                f"{self._error_name(result)}；请先停止占用 USB 的 DJOneHub 后台"
            )

    def close(self) -> None:
        """释放接口与 libusb 上下文，避免影响 DJOneHub 后续重新连接。"""
        if self._handle.value:
            if self._interface_number is not None:
                self._usb.libusb_release_interface(self._handle, self._interface_number)
            self._usb.libusb_close(self._handle)
            self._handle = ctypes.c_void_p()
            self._interface_number = None
            self._endpoint_out = None
            self._endpoint_in = None
        if self._context.value:
            self._usb.libusb_exit(self._context)
            self._context = ctypes.c_void_p()

    def _bulk_write(self, payload: bytes) -> None:
        """完整写入一个 ADB 头或数据块。"""
        if self._endpoint_out is None:
            raise RuntimeError("ADB OUT 端点尚未初始化")
        offset = 0
        while offset < len(payload):
            chunk = payload[offset:]
            buffer = (ctypes.c_ubyte * len(chunk)).from_buffer_copy(chunk)
            transferred = ctypes.c_int()
            result = self._usb.libusb_bulk_transfer(
                self._handle,
                self._endpoint_out,
                buffer,
                len(chunk),
                ctypes.byref(transferred),
                USB_TIMEOUT_MS,
            )
            if result != 0:
                raise RuntimeError(f"ADB USB 写入失败：{self._error_name(result)}")
            if transferred.value <= 0:
                raise RuntimeError("ADB USB 写入没有产生进度")
            offset += transferred.value

    def _bulk_read_exact(self, size: int) -> bytes:
        """读取指定字节数，正确处理 USB 短包。"""
        if self._endpoint_in is None:
            raise RuntimeError("ADB IN 端点尚未初始化")
        output = bytearray()
        while len(output) < size:
            remaining = size - len(output)
            buffer = (ctypes.c_ubyte * remaining)()
            transferred = ctypes.c_int()
            result = self._usb.libusb_bulk_transfer(
                self._handle,
                self._endpoint_in,
                buffer,
                remaining,
                ctypes.byref(transferred),
                USB_TIMEOUT_MS,
            )
            if result != 0:
                raise RuntimeError(f"ADB USB 读取失败：{self._error_name(result)}")
            if transferred.value <= 0:
                raise RuntimeError("ADB USB 读取没有产生进度")
            output.extend(bytes(buffer[: transferred.value]))
        return bytes(output)

    def send_message(self, command: int, arg0: int, arg1: int, payload: bytes = b"") -> None:
        """编码并发送一个 ADB 协议消息。"""
        checksum = sum(payload) & 0xFFFFFFFF
        header = struct.pack(
            "<6I",
            command,
            arg0,
            arg1,
            len(payload),
            checksum,
            command ^ 0xFFFFFFFF,
        )
        self._bulk_write(header)
        if payload:
            self._bulk_write(payload)

    def read_message(self) -> AdbMessage:
        """读取并严格校验一个 ADB 协议消息。"""
        raw_header = self._bulk_read_exact(24)
        command, arg0, arg1, length, checksum, magic = struct.unpack("<6I", raw_header)
        if magic != (command ^ 0xFFFFFFFF):
            raise RuntimeError("ADB 消息 magic 校验失败")
        if length > 1024 * 1024:
            raise RuntimeError(f"ADB 消息长度异常：{length}")
        payload = self._bulk_read_exact(length) if length else b""
        if (sum(payload) & 0xFFFFFFFF) != checksum:
            raise RuntimeError("ADB 消息 checksum 校验失败")
        return AdbMessage(command=command, arg0=arg0, arg1=arg1, payload=payload)

    def connect(self) -> None:
        """建立无认证 ADB 会话；认证开启时明确停止而不猜测密钥。"""
        self.send_message(ADB_CNXN, 0x01000000, 4096, b"host::\x00")
        response = self.read_message()
        if response.command == ADB_AUTH:
            raise RuntimeError("模块启用了 ADB RSA 认证，最小只读探针不会绕过认证")
        if response.command != ADB_CNXN:
            raise RuntimeError(f"ADB 握手返回未知命令：0x{response.command:08x}")

    def run_shell(self, command: str) -> bytes:
        """执行内部固定命令并收集 legacy shell 的原始输出。"""
        local_id = 1
        service = f"shell:{command}".encode("utf-8") + b"\x00"
        self.send_message(ADB_OPEN, local_id, 0, service)

        remote_id: int | None = None
        output = bytearray()
        while True:
            message = self.read_message()
            if message.command == ADB_OKAY:
                if remote_id is None:
                    remote_id = message.arg0
                continue
            if message.command == ADB_WRTE:
                remote_id = message.arg0
                output.extend(message.payload)
                self.send_message(ADB_OKAY, local_id, remote_id)
                continue
            if message.command == ADB_CLSE:
                if remote_id is not None:
                    self.send_message(ADB_CLSE, local_id, remote_id)
                break
            raise RuntimeError(f"ADB shell 返回未知命令：0x{message.command:08x}")
        return bytes(output)

    def run_probe(self) -> str:
        """执行固定只读探测命令并转换为可显示文本。"""
        return self.run_shell(PROBE_COMMAND).decode("utf-8", errors="replace")

    def pull_ril_analysis_binary(self) -> Path:
        """仅拉取预定义 RIL 测试程序到临时目录供静态分析。"""
        encoded = self.run_shell("busybox base64 /usr/bin/qmi_simple_ril_test")
        binary = base64.b64decode(encoded, validate=False)
        if not binary.startswith(b"\x7fELF"):
            raise RuntimeError("拉取结果不是有效 ELF 文件")

        output_directory = Path("/private/tmp/qdc507-firmware-analysis")
        output_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        output_path = output_directory / "qmi_simple_ril_test"
        output_path.write_bytes(binary)
        output_path.chmod(0o600)
        return output_path


def main() -> int:
    """打开传输、执行固定探测，并保证退出时释放 USB 接口。"""
    action = sys.argv[1:]
    if action not in ([], ["--pull-ril-analysis"]):
        print(f"用法：{sys.argv[0]} [--pull-ril-analysis]", file=sys.stderr)
        return 64

    transport = UsbAdbTransport()
    try:
        transport.open()
        transport.connect()
        if action == ["--pull-ril-analysis"]:
            print(transport.pull_ril_analysis_binary())
        else:
            print(transport.run_probe(), end="")
        return 0
    except Exception as error:  # 统一转成适合分享排查的中文错误。
        print(f"探测失败：{error}", file=sys.stderr)
        return 1
    finally:
        transport.close()


if __name__ == "__main__":
    raise SystemExit(main())

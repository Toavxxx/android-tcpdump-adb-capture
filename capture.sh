#!/bin/bash
# ==========================================================
# Android tcpdump 抓包脚本
#
# 用法:
#   ./capture.sh                          # 默认抓 wlan0 全部流量
#   ./capture.sh wlan0                    # 同上，显式指定接口
#   ./capture.sh wlan0 "host 1.2.3.4"     # 只抓和指定 IP 通信的流量
#   ./capture.sh any "port 443"           # 抓所有接口上 443 端口流量
#
# 按 Ctrl+C 停止抓包，脚本会自动：
#   1. 给手机端的 tcpdump 发 SIGINT，让它正常结束并把 pcap 文件写完整
#   2. 把文件拉取到本地当前文件夹/captures/ 目录
#   3. 删除手机上的临时文件
# ==========================================================

set -u

# 只排除手机端路径（/data、/sdcard）不被自动转换成 Windows 路径
# 本地保存路径（如 /c/Users/.../captures/xxx.pcap）仍会被正常转换成 Windows 格式
# 注意：多个前缀之间必须用分号 ; 分隔，不能用冒号
export MSYS2_ARG_CONV_EXCL="/data;/sdcard"

# 始终以脚本文件自身所在目录为基准保存文件，不受调用时所在目录影响
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IFACE="${1:-wlan0}"
FILTER="${2:-}"
TCPDUMP_PATH="/data/local/tmp/tcpdump"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REMOTE_PCAP="/sdcard/capture_${TIMESTAMP}.pcap"
LOCAL_DIR="${SCRIPT_DIR}/captures"
LOCAL_PCAP="${LOCAL_DIR}/capture_${TIMESTAMP}.pcap"

mkdir -p "$LOCAL_DIR"

echo "=========================================="
echo " Android tcpdump 抓包"
echo " 接口      : $IFACE"
echo " 过滤条件  : ${FILTER:-(无，抓全部流量)}"
echo " 手机文件  : $REMOTE_PCAP"
echo " 本地保存到: $LOCAL_PCAP"
echo " 按 Ctrl+C 停止抓包"
echo "=========================================="

# 检查设备连接
if ! adb get-state >/dev/null 2>&1; then
    echo "错误：未检测到已连接的设备，请检查 adb devices"
    exit 1
fi

# 检查手机上 tcpdump 是否存在
if ! adb shell "[ -f $TCPDUMP_PATH ]" 2>/dev/null; then
    echo "错误：手机上找不到 $TCPDUMP_PATH，请先确认已推送 tcpdump"
    exit 1
fi

cleanup() {
    echo ""
    echo ">> 正在停止手机端 tcpdump 进程..."
    adb shell su -c "killall -2 tcpdump" >/dev/null 2>&1
    sleep 1

    echo ">> 正在拉取抓包文件到本地..."
    adb pull "$REMOTE_PCAP" "$LOCAL_PCAP"

    if [ -f "$LOCAL_PCAP" ]; then
        echo ">> 完成！文件已保存到: $LOCAL_PCAP"
        adb shell su -c "rm -f $REMOTE_PCAP" >/dev/null 2>&1
    else
        echo ">> 拉取失败，手机上的文件可能还在: $REMOTE_PCAP"
    fi

    exit 0
}

trap cleanup INT

adb shell su -c "$TCPDUMP_PATH -i $IFACE -w $REMOTE_PCAP $FILTER"

# Android tcpdump 自编译 + adb 离线抓包工具

在 Android 14（已 root）设备上，通过 NDK 交叉编译 tcpdump，配合 adb 实现稳定的离线抓包，绕开 Wireshark 在 Windows 上通过 androiddump 实时抓包时的已知 bug。

## 背景

Wireshark 自带的 `androiddump` extcap 可以通过 adb 调用手机端 tcpdump 实时抓包，但：

1. 很多手机系统自带的 tcpdump 残缺或不可用（仅返回错误码，无任何功能）。
2. Windows 平台的 Wireshark（截至 4.6.6 仍存在）有一个已知 bug：如果某个 Android 接口连续 **2 秒没有新数据包**，会直接报 `Broken socket connection` 并断开抓包。详见 [wireshark/wireshark#20386](https://gitlab.com/wireshark/wireshark/-/issues/20386)。

解决思路：自己交叉编译一份 tcpdump 推到手机上，**放弃实时抓包，改用离线抓包（写文件 + adb pull）**，完全绕开这个 Windows 限制。

## 环境

- Windows 10/11
- [MSYS2](https://www.msys2.org/)（提供 bash 环境 + 编译工具链）
- [Android NDK r29](https://developer.android.com/ndk/downloads)
- 已 root 的 Android 14 设备（本例使用 KernelSU / SukiSU Ultra）
- adb（platform-tools）

## 一、准备 MSYS2 编译环境

打开 **MSYS2 UCRT64** 终端（开始菜单搜索 MSYS2，选 UCRT64 或 MINGW64）：

```bash
pacman -Syu
# 如提示重启终端，关闭重新打开后再执行一次
pacman -S make autoconf automake libtool
```

## 二、设置交叉编译环境变量

```bash
export NDK="/d/android-ndk-r29"   # 换成你自己的 NDK 解压路径，注意盘符写法 D:\ -> /d/
export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/windows-x86_64
export TARGET=aarch64-linux-android
export API=34                     # 对应 Android 14
export CC=$TOOLCHAIN/bin/$TARGET$API-clang
export AR=$TOOLCHAIN/bin/llvm-ar
export RANLIB=$TOOLCHAIN/bin/llvm-ranlib
export STRIP=$TOOLCHAIN/bin/llvm-strip
export LDFLAGS="-Wl,-z,max-page-size=4096"   # NDK r28+ 默认 16KB 页对齐，加这个保证兼容性
```

> 这些变量只在当前终端会话有效，关闭终端后需要重新执行。

## 三、下载并编译 libpcap

```bash
git clone https://github.com/the-tcpdump-group/libpcap.git
cd libpcap
./autogen.sh   # git clone 下来的源码没有 configure，需要先生成
./configure --host=$TARGET --with-pcap=linux --disable-shared
make
cd ..
```

成功后会在目录下生成 `libpcap.a`。

## 四、下载并编译 tcpdump

```bash
git clone https://github.com/the-tcpdump-group/tcpdump.git
cd tcpdump
./autogen.sh
./configure --host=$TARGET \
  CPPFLAGS="-I../libpcap" \
  LDFLAGS="-L../libpcap $LDFLAGS" \
  --without-crypto
make
cd ..
```

成功后 `tcpdump/tcpdump` 就是编译好的 ARM64 可执行文件，用 `file tcpdump` 可以确认架构。

## 五、推送到手机并验证

```bash
adb push tcpdump/tcpdump /data/local/tmp/tcpdump
adb shell chmod 755 /data/local/tmp/tcpdump
adb shell su -c "chown root:root /data/local/tmp/tcpdump"

# 验证
adb shell su -c "/data/local/tmp/tcpdump --version"
```

正常应输出类似：
```
tcpdump version 5.0.0-PRE-GIT
libpcap version 1.11.0-PRE-GIT (64-bit time_t, with TPACKET_V3)
64-bit build, 64-bit time_t
```

### 常见报错

| 报错 | 原因 / 解决 |
|---|---|
| `su: inaccessible or not found` | Root 管理器没有给 adb shell（Shell 身份）授予 root 权限，需要在 KernelSU / SukiSU / Magisk 管理界面里手动开启 |
| `/data/local/tmp/tcpdump: Permission denied` | 部分 ROM 把 `/data/local/tmp` 设为 noexec，执行 `adb shell su -c "mount -o remount,exec /data/local/tmp"` |

## 六、一键抓包脚本 `capture.sh`

把下面内容保存为 `capture.sh`，放在任意目录下。

```bash
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
#   2. 把文件拉取到本地 ./captures/ 目录（始终相对脚本自身所在位置）
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
```

赋予执行权限后运行：

```bash
chmod +x capture.sh
./capture.sh wlan0
```

按 `Ctrl+C` 停止，文件会自动出现在 `capture.sh` 同级目录下的 `captures/` 文件夹里，可直接用 Wireshark 打开。

## 七、按 App 过滤流量（可选）

tcpdump 不识别"应用"概念，但可以先找到目标 App 的 UID，再反查它正在通信的远程 IP，针对性抓包：

```bash
# 1. 确认包名对应的 UID
adb shell pm list packages -U | grep <包名>

# 2. 查看该 UID 当前的 TCP 连接（远程 IP:端口，十六进制小端序）
adb shell su -c "cat /proc/net/tcp" | awk '$8 == "<UID>" {print $2, $3}'

# 3. 拿到远程 IP 后，针对性抓包
./capture.sh wlan0 "host <远程IP>"
```

> 如果该 App 走的是会变化的 CDN IP，建议直接关闭其他 App、单独运行目标 App 后抓全量流量，再用 Wireshark 的显示过滤器按域名 / SNI 筛选，比按固定 IP 过滤更全面。

## 踩坑记录（MSYS2 / Windows 特有问题）

1. **路径自动转换坑**：MSYS2/Git Bash 会把以 `/` 开头的参数自动转换成 Windows 路径再传给原生 exe（比如 `adb.exe`）。导致 `/data/local/tmp/tcpdump` 被错误转换成 `C:/msys64/data/local/tmp/tcpdump`。
   解决：设置 `MSYS2_ARG_CONV_EXCL` 排除指定前缀，**注意多个前缀之间用分号 `;` 分隔，不是冒号 `:`**。
   ```bash
   export MSYS2_ARG_CONV_EXCL="/data;/sdcard"
   ```

2. **Wireshark Windows 版 2 秒断流 bug**：见上文背景说明，目前（4.6.6）仍未修复，建议直接用本仓库的离线抓包方案规避。

3. **PowerShell 无法运行 .sh 脚本**：必须在 MSYS2 / Git Bash 终端里执行 `./capture.sh`，CMD/PowerShell 只能跑 `adb` 单条命令。

## License

MIT

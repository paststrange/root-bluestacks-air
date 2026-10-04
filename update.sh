#!/bin/bash
# BlueStacks 更新后一键重新 root：打补丁 → 刷新 .bak → 部署 → 启动并验证 su
# 打补丁及其前置校验全部交给 repatch.sh，本脚本只负责它之后的部署与验证。
#
# 用法：
#   1. 完全退出 BlueStacks（含 multi-instance manager）
#   2. ./update.sh            （中途会要求输入一次 sudo 密码）
#
# 可选环境变量：
#   ADB_SERIAL   实例的 adb 地址，默认 127.0.0.1:5565
#   BOOT_TIMEOUT 等待实例开机的秒数，默认 240

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG=/Applications/BlueStacks.app/Contents/img/initrd_hvf.img
ORIG="$DIR/initrd_original.img"
OUT="$DIR/initrd_patched.img"
SERIAL="${ADB_SERIAL:-127.0.0.1:5565}"
TIMEOUT="${BOOT_TIMEOUT:-240}"

die() { echo "❌ $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

[ -f "$IMG" ] || die "找不到 $IMG"

if cpio -itv < "$IMG" 2>/dev/null | grep -q "boot/magisk"; then
  echo "[*] 当前 initrd 已含 Magisk，跳过打补丁与部署，直接验证"
else
  "$DIR/repatch.sh" > /dev/null || die "repatch.sh 失败，见上方输出（可单独运行 ./repatch.sh 查看完整日志）"
  echo "[*] 补丁已生成（BlueStacks $(defaults read /Applications/BlueStacks.app/Contents/Info.plist CFBundleVersion)）"

  echo "[*] 需要 sudo 权限写入 /Applications"
  sudo -v

  # .bak 取自 repatch.sh 刚确认过「未含 Magisk」的 initrd_original.img，而非 App 内的镜像；
  # 且必须先于部署执行。BlueStacks 更新会连带替换 kernel_hvf 与 initrd 内的 .ko，
  # 旧版 .bak 与新内核不配套，不刷新的话日后回滚会开不了机。
  echo "[*] 用新版纯净镜像刷新 ${IMG}.bak"
  sudo cp "$ORIG" "${IMG}.bak"

  echo "[*] 部署补丁"
  sudo cp "$OUT" "$IMG"
  sudo chmod 644 "$IMG"

  [ "$(sha "$IMG")" = "$(sha "$OUT")" ] || die "部署后哈希不一致"
  [ "$(sha "${IMG}.bak")" = "$(sha "$ORIG")" ] || die ".bak 哈希不一致"
  echo "    initrd_hvf.img     $(sha "$IMG")"
  echo "    initrd_hvf.img.bak $(sha "${IMG}.bak")"
fi

command -v adb > /dev/null || die "未找到 adb，请手动启动实例后执行：adb connect $SERIAL && adb -s $SERIAL shell 'su -c id'"

echo "[*] 启动 BlueStacks，等待 $SERIAL 开机（最多 ${TIMEOUT}s）"
open -a /Applications/BlueStacks.app

deadline=$((SECONDS + TIMEOUT))
until adb connect "$SERIAL" 2>/dev/null | grep -q "connected" \
   && [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  [ $SECONDS -lt $deadline ] || die "等待开机超时。若实例端口不是 $SERIAL，用 ADB_SERIAL=... 重新运行"
  sleep 3
done

# 刚开机时 magiskd 可能还在执行 --boot-complete，给 su 几次重试机会
for _ in 1 2 3 4 5; do
  ID=$(adb -s "$SERIAL" shell 'su -c id' 2>/dev/null | tr -d '\r' || true)
  case "$ID" in uid=0\(root\)*) break ;; esac
  sleep 3
done

case "$ID" in
  uid=0\(root\)*)
    echo "    $ID"
    echo "    Magisk $(adb -s "$SERIAL" shell 'su -c "magisk -v"' | tr -d '\r')"
    echo
    echo "✅ root 已恢复" ;;
  *)
    cat << EOF >&2

❌ su 验证失败（输出：${ID:-空}）

可能原因：
  - 全新实例需先打开 Kitsune Mask 完成「修复运行环境」，重启后再运行本脚本（已打补丁会自动跳过部署）
  - 注入失败：grep -a magisk "/Users/Shared/Library/Application Support/BlueStacks/Engine/<实例名>/qvirt.log"
    重点看 --setup-sbin 那行退出码是否为 0

回滚：sudo cp "$ORIG" "$IMG"
EOF
    exit 1 ;;
esac

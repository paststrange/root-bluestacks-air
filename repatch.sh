#!/bin/bash
# BlueStacks Air 重新注入 Magisk（Kitsune）
# 用途：BlueStacks 更新后会覆盖 initrd_hvf.img，导致 root 失效，跑本脚本重新打补丁。
#
# 用法：
#   1. 完全退出 BlueStacks
#   2. ./repatch.sh
#   3. 按提示执行末尾输出的 sudo 命令
#   4. 启动实例，打开 Kitsune Mask 完成「修复运行环境」

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG=/Applications/BlueStacks.app/Contents/img/initrd_hvf.img
OUT="$DIR/initrd_patched.img"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "❌ $*" >&2; exit 1; }

[ -f "$IMG" ] || die "找不到 $IMG"

# 进程名用子串匹配。实测 multi-instance manager 的进程名是
# "BlueStacks Air multi-instance manager"，精确匹配（-x BlueStacks）根本命中不了，
# 会让这道检查静默通过 —— 而带着运行中的 BlueStacks 改 initrd 正是本脚本最该拦的事。
# 注意不要加 -f：那会匹配完整命令行，而本仓库路径自身含 "bluestacks"，
# 脚本会匹配到自己，从而永远无法运行。
if RUNNING=$(pgrep -il bluestacks); then
  die "BlueStacks 仍在运行，请先完全退出（含 multi-instance manager）：
$(echo "$RUNNING" | sed 's/^/      /')"
fi

VER=$(defaults read /Applications/BlueStacks.app/Contents/Info.plist CFBundleVersion 2>/dev/null || echo "未知")
echo "[*] BlueStacks 版本: $VER"

# 检查当前 initrd 是否已经打过补丁
if cpio -itv < "$IMG" 2>/dev/null | grep -q "boot/magisk"; then
  die "当前 initrd 已含 Magisk，无需重复打补丁。如需从头再来，先用 initrd_original.img（或自备的 .bak）还原。"
fi

echo "[*] 备份当前（未打补丁的）initrd"
cp "$IMG" "$DIR/initrd_original.img"
shasum -a 256 "$DIR/initrd_original.img" | sed 's/^/    /'

echo "[*] 解包"
mkdir -p "$WORK/initrd" && cd "$WORK/initrd"
cpio -id < "$IMG" 2>/dev/null

# 校验新版本的 stage2.sh 是否仍符合注入前提
grep -q "^exec /init$" boot/stage2.sh \
  || die "boot/stage2.sh 中找不到独立的 'exec /init' 行，BlueStacks 可能改了启动流程，需人工检查"
grep -q "die_if_error()" boot/stage2.sh \
  || die "boot/stage2.sh 缺少 die_if_error()，需人工检查"

echo "[*] 注入 Magisk 二进制"
cp -r "$DIR/magisk-bin" boot/magisk
chmod 700 boot/magisk/*
cp "$DIR/magisk.rc" boot/magisk.rc

echo "[*] 改造 stage2.sh"
/usr/bin/sed -i '' -e 's|^exec /init$||' boot/stage2.sh
cat >> boot/stage2.sh << 'EOF'
log_echo "Installing magisk.rc"
cat /boot/magisk.rc >> /init.bst.rc
die_if_error "Cannot install magisk.rc"

exec /init
EOF
[ "$(grep -c '^exec /init$' boot/stage2.sh)" -eq 1 ] || die "stage2.sh 改造异常：exec /init 数量不为 1"

echo "[*] 重新打包"
find . | cpio -R 0:0 -H newc -o 2>/dev/null | gzip -9 > "$OUT"
shasum -a 256 "$OUT" | sed 's/^/    /'

cat << EOF

✅ 补丁已生成: $OUT

下一步（需要提权，因为目标文件属主是 root:wheel）：

  sudo cp "$OUT" "$IMG" && sudo chmod 644 "$IMG"

然后启动实例，打开 Kitsune Mask 完成「修复运行环境」。

回滚（还原到未打补丁状态）：

  sudo cp "$DIR/initrd_original.img" "$IMG"
EOF

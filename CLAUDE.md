# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这是什么

不是常规软件项目，而是一套**虚拟机镜像补丁工具链**：修改 BlueStacks Air (macOS / Apple Silicon) 的 initrd，注入 Magisk 以获得 root。没有构建系统、测试框架或依赖管理，"运行"即打补丁，"测试"即启动实例后 `adb shell su -c id`。

详细背景（失败方案对照表、Kitsune 与官方 Magisk 的差异证据、排查手法）见 `README.md`，本文件只保留操作与架构要点。

## 常用命令

```bash
# 打补丁（前提：BlueStacks 完全退出，含 multi-instance manager）
./repatch.sh
# 脚本只生成 initrd_patched.img，不会自行部署；末尾会打印需手动执行的 sudo 命令：
sudo cp initrd_patched.img /Applications/BlueStacks.app/Contents/img/initrd_hvf.img
sudo chmod 644 /Applications/BlueStacks.app/Contents/img/initrd_hvf.img

# 验证 root（启动实例并在 Kitsune Mask 里完成「修复运行环境」之后）
adb connect 127.0.0.1:5565
adb -s 127.0.0.1:5565 shell 'su -c id'      # 期望 uid=0(root)

# 回滚
sudo cp initrd_original.img /Applications/BlueStacks.app/Contents/img/initrd_hvf.img

# 快速验证 Magisk 二进制兼容性（不必走完整启动流程，省几分钟）
adb push magisk-bin/magisk64 /data/local/tmp/magisk64
adb shell 'chmod 755 /data/local/tmp/magisk64; /data/local/tmp/magisk64 -c'
adb shell '/data/local/tmp/magisk64 --auto-selinux --setup-sbin /boot/magisk /sbin'
```

排查日志分散三处，其中虚拟机控制台最有用（含 init 各服务退出码）：

```bash
grep -a magisk "/Users/Shared/Library/Application Support/BlueStacks/Engine/<实例名>/qvirt.log"
adb shell dmesg | grep -i magisk
grep -i magisk "/Users/Shared/Library/Application Support/BlueStacks/Logs/Player.log"
```

关键判据：`magisk64 --auto-selinux --setup-sbin` 那行退出码必须为 **0**；为 1 则 `/sbin/magisk` 不会被创建，后续全部失败。

## 架构

注入链路（`repatch.sh` → initrd 内部 → Android init）：

1. `repatch.sh` 用 cpio 解包 `initrd_hvf.img`（BSD cpio 会透明解 gzip，脚本里没有显式 `gunzip`）
2. `magisk-bin/` 整个目录复制为 initrd 内的 `boot/magisk/`，权限 700
3. `magisk.rc` 复制为 `boot/magisk.rc`
4. 改造 `boot/stage2.sh`：删掉原有的 `exec /init`，在末尾追加 `cat /boot/magisk.rc >> /init.bst.rc` 再 `exec /init`
5. `find . | cpio -R 0:0 -H newc -o | gzip -9` 重新打包（`-R 0:0` 保留 root 属主，不可省）

于是 Android init 解析 `/init.bst.rc` 时把 `magiskd` 当系统自带服务拉起 —— 在 BlueStacks 任何代码运行前 root 已成既成事实。选 initrd 是因为此时 SELinux 策略未加载、`/system` 尚未只读挂载。

### 跨文件的隐式契约（改动时最容易踩的地方）

- **路径与文件名三方耦合**：`repatch.sh:47` 把 `magisk-bin` 复制成 `boot/magisk`，而 `magisk.rc` 里硬编码 `/boot/magisk/magisk64` 与 `/boot/magisk/magiskpolicy`。改目录名或二进制名必须两边同步。
- **Magisk 是 busybox 式多调用二进制，按 `argv[0]` 分派 applet**。文件名和二进制期望不符时返回 `applet not found` 并 exit 1，日志里只体现为一行 `exited with status 1`，极易误判成"参数不支持"。
- **必须用 Kitsune 而非官方 Magisk**。官方 v30.7 起移除了 `--auto-selinux` 和 `--setup-sbin`，并把 sbin 初始化改由 `magiskinit` 以 PID 1 接管 —— 本方案恰好绕开那条路径。这是契约变更，不是改名能解决的。当前使用 `Jordan231111/KitsuneMagisk` v31.0（原 `1q23lyc45/KitsuneMagisk` 已下架），`kitsune.apk` SHA256 记录在 README 中。第三方 fork，未经审计。
- **`repatch.sh` 的前置校验是刻意的防线**，不要为图省事删除：检测 BlueStacks 是否在运行、initrd 是否已打过补丁、`stage2.sh` 是否仍含独立的 `exec /init` 行与 `die_if_error()`。BlueStacks 升级后若启动流程变了，这些校验能让脚本明确失败，而不是静默产出一个开不了机的镜像。

## 约束与注意

- **`initrd_original.img` / `initrd_patched.img` 已被 gitignore**，它们是版本特定产物，每次 `repatch.sh` 会重新提取与生成；仍保留在工作目录作回滚备份。不要把它们加回版本控制。
- `repatch.sh` 会用当前 App 里的镜像**覆盖** `initrd_original.img`，所以脚本靠"已打过补丁"检测来防止把已污染的镜像存成"原始"备份。
- **补丁是 App 级而非实例级**，对所有实例生效。有完整性检测的应用建议配 Magisk DenyList。
- 修改 App Bundle 内部会破坏代码签名；BlueStacks 每次更新覆盖 initrd 后需重跑 `repatch.sh`。
- 已验证环境：BlueStacks Air 5.21.782.7501、5.21.790.7505 / Android 13 (API 33) / arm64-v8a。升级时 initrd 与 `kernel_hvf` 配套更新，旧版 `.bak` 不能用于新版回滚。改动涉及版本敏感行为时，在提交信息或 README 中记下实测版本。

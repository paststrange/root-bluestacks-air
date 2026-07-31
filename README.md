# root-bluestacks-air

给 **BlueStacks Air (macOS / Apple Silicon)** 注入 Magisk 以获得 root。

BlueStacks Air 官方不提供 root：`bst.feature.rooting` 由服务端下发强制为 `0`，且引擎二进制里根本没有 root 实现。本项目绕开整个应用层，直接 patch 虚拟机的 initrd。

原始思路来自 [hanreev/root-bluestacks-air](https://github.com/hanreev/root-bluestacks-air)，本项目做了两处适配：换用可获取的 Magisk 分支、增加多处前置校验避免静默产出坏补丁。

---

## 快速使用

```bash
# 1. 完全退出 BlueStacks（含 multi-instance manager）
# 2. 生成补丁
./repatch.sh
# 3. 按脚本末尾提示执行 sudo cp
# 4. 启动实例 → 打开 Kitsune Mask → 「修复运行环境」→ 自动重启
```

验证：

```bash
adb connect 127.0.0.1:5565
adb -s 127.0.0.1:5565 shell 'su -c id'   # 期望 uid=0(root)
```

**BlueStacks 每次更新都会覆盖 initrd，root 失效，重跑 `repatch.sh` 即可。**

---

## 原理

修改 `/Applications/BlueStacks.app/Contents/img/initrd_hvf.img`（虚拟机初始内存盘，`hvf` = Apple Hypervisor.framework）：

1. `gzip + cpio` 解包
2. 把 `magisk64` / `magiskinit` / `magiskpolicy` 放进 `boot/magisk/`（700 权限）
3. 放入 `boot/magisk.rc`（Magisk 的 init 服务定义）
4. 改造 `boot/stage2.sh` —— **关键的一刀**：

```sh
# 在移交控制权给 Android init 之前插入
cat /boot/magisk.rc >> /init.bst.rc
exec /init
```

5. 重新打包（`cpio -R 0:0` 保留 root 属主）

于是 Android init 解析 `/init.bst.rc` 时，会把 `magiskd` 当作系统自带服务拉起。**在 BlueStacks 任何代码运行之前，root 已是既成事实。**

initrd 是最早能插手的位置 —— 此时 SELinux 策略未加载、`/system` 尚未只读挂载。

---

## 为什么不用应用层方案（已验证全部无效）

| 尝试 | 结果 |
|---|---|
| 改 `bst.instance.<name>.enable_root_access="1"` | 启动时被服务端 `get_conf_updates` 覆盖 |
| 屏蔽 `cloud.bluestacks.com` 让配置存活 | flag 成功存活为 `1`，但引擎**零响应**（启动日志无任何 root 相关条目、无 `su`、`/system` 仍 `ro`） |
| UI 里的「启用Root权限」开关 | 空壳。取消勾选后完全退出，配置文件 **mtime 都不变** —— 处理器不存在 |
| `pm enable <component>`（shell 身份） | `SecurityException: Shell cannot change component state`（AOSP 限制：shell 只能整包 enable/disable） |

结论：**`bst.feature.rooting` 只控制 UI 元素渲染，功能实现没有编译进 Air 版二进制。**

---

## 为什么用 Kitsune 而非官方 Magisk

官方 Magisk **v30.7 与本方案不兼容**，实测证据：

| | 官方 v30.7 | Kitsune v31.0 |
|---|---|---|
| `libmagisk64.so` | ❌ 已合并为 `libmagisk.so` | ✅ 存在 |
| `--auto-selinux` | ❌ `Unrecognized argument` | ✅ 识别 |
| `--setup-sbin` | ❌ help 中已移除 | ✅ 识别 |

新版 Magisk 把 sbin 初始化交给 `magiskinit` 以 PID 1 接管，而本方案恰好绕开那条路径。这不是改个名能解决的，**是契约本身变了**。

> 排查提示：Magisk 是 busybox 式多调用二进制，**按 `argv[0]` 分派**。命名为 `magisk64` 而二进制只认 `magisk` 时，会返回 `applet not found` 并 exit 1 —— 表现为启动日志里一行 `exited with status 1`，极易误判为参数不支持。

**来源说明**：脚本 README 指向的原始 Kitsune 仓库 `1q23lyc45/KitsuneMagisk` 已下架（404）。本项目使用 [`Jordan231111/KitsuneMagisk`](https://github.com/Jordan231111/KitsuneMagisk) v31.0，`kitsune.apk` SHA256：

```
fac319d2de262fcfff1684e13e1a5c61c486d2a773a7a8ffcfdbfe6f763a7fd4
```

这是一个**第三方 fork，未经审计**。Magisk 拥有实例的最高权限，使用前请自行评估。

---

## 排查

日志分散在三处：

```bash
# 虚拟机控制台（最有用，含 init 各服务的退出码）
grep -a magisk "/Users/Shared/Library/Application Support/BlueStacks/Engine/<实例名>/qvirt.log"

# 设备内核日志（stage2.sh 的 log_echo 写到 /dev/kmsg）
adb shell dmesg | grep -i magisk

# 宿主机应用日志
grep -i magisk "/Users/Shared/Library/Application Support/BlueStacks/Logs/Player.log"
```

关键判据：`magisk64 --auto-selinux --setup-sbin` 那行的退出码必须是 **0**。若为 1，则 `/sbin/magisk` 不会被创建，后续全部失败。

**验证二进制兼容性不必走完整启动流程**（一轮好几分钟），推到设备上直接跑即可：

```bash
adb push magisk-bin/magisk64 /data/local/tmp/magisk64
adb shell 'chmod 755 /data/local/tmp/magisk64; /data/local/tmp/magisk64 -c'
adb shell '/data/local/tmp/magisk64 --auto-selinux --setup-sbin /boot/magisk /sbin'
# 参数被识别即可；mount 环节的 "Operation not permitted" 是因为当前是 shell 身份，属正常
```

---

## 回滚

```bash
sudo cp /Applications/BlueStacks.app/Contents/img/initrd_hvf.img.bak \
        /Applications/BlueStacks.app/Contents/img/initrd_hvf.img
# 或用本目录的纯净备份
sudo cp initrd_original.img /Applications/BlueStacks.app/Contents/img/initrd_hvf.img
```

---

## 注意事项

- **initrd 是 App 级而非实例级** —— 补丁对**所有实例**生效。跑银行类或有完整性检测的应用的实例，建议配置 Magisk DenyList。
- **Play Integrity / SafetyNet** 更易被检测到。
- 修改 App Bundle 内部会破坏代码签名。
- BlueStacks 更新后需重新打补丁。

---

## 文件

| 文件 | 说明 |
|---|---|
| `repatch.sh` | 重新打补丁脚本，含多重前置校验 |
| `initrd_original.img` | 纯净原始镜像，SHA256 `d489725a…45326b`（BlueStacks 5.21.782.7501） |
| `initrd_patched.img` | 已打补丁镜像，SHA256 `ea100cf5…41c6a22` |
| `magisk-bin/` | Kitsune 的 `magisk64` / `magiskinit` / `magiskpolicy` / `stub.apk` |
| `magisk.rc` | Magisk 的 init 服务定义 |
| `kitsune.apk` | Kitsune Mask 管理器，需装进实例 |

首次验证环境：BlueStacks Air **5.21.782.7501**，Android 13 (API 33)，arm64-v8a。

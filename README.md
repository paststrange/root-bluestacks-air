# root-bluestacks-air

给 **BlueStacks Air (macOS / Apple Silicon)** 注入 Magisk 以获得 root。

BlueStacks Air 官方不提供 root：`bst.feature.rooting` 由服务端下发强制为 `0`，且引擎二进制里根本没有 root 实现。本项目绕开整个应用层，直接 patch 虚拟机的 initrd。

原始思路来自 [hanreev/root-bluestacks-air](https://github.com/hanreev/root-bluestacks-air)，本项目做了两处适配：换用可获取的 Magisk 分支、增加多处前置校验避免静默产出坏补丁。

---

## 快速使用

**BlueStacks 更新后一键恢复 root：**

```bash
# 完全退出 BlueStacks（含 multi-instance manager）后：
./update.sh
```

它依次完成：调用 `repatch.sh` 生成补丁 → 用新版纯净镜像刷新 `initrd_hvf.img.bak` → 部署补丁 → 启动 BlueStacks、等待开机 → `su -c id` 验证。中途只需输入一次 sudo 密码。若当前 initrd 已打过补丁，会跳过前三步直接验证。实例端口不是 `127.0.0.1:5565` 时，用 `ADB_SERIAL=127.0.0.1:xxxx ./update.sh`。

**分步手动执行：**

```bash
# 1. 完全退出 BlueStacks（含 multi-instance manager）
# 2. 生成补丁
./repatch.sh
# 3. 按脚本末尾提示执行 sudo cp
# 4. 启动实例 → 打开 Kitsune Mask → 「修复运行环境」→ 自动重启
#    （升级 BlueStacks 后重打补丁时，data 分区保留了 /data/adb/magisk，通常不会再弹此提示，直接 su 即可）
```

验证：

```bash
adb connect 127.0.0.1:5565
adb -s 127.0.0.1:5565 shell 'su -c id'   # 期望 uid=0(root)
```

**BlueStacks 每次更新都会覆盖 initrd，root 失效，运行 `./update.sh` 即可。**

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

`repatch.sh` 每次打补丁前，都会把当前（未打补丁的）镜像另存为本目录的 `initrd_original.img`：

```bash
sudo cp initrd_original.img /Applications/BlueStacks.app/Contents/img/initrd_hvf.img
```

> ⚠️ **刚 clone 完仓库的机器上没有任何备份。** `initrd_original.img` 是 `repatch.sh` 运行时才生成的产物，且被 gitignore（见「文件」一节）。`repatch.sh` **不会**在 `/Applications` 下创建 `.bak`。所以第一次打补丁前，请自己留一份：
>
> ```bash
> sudo cp /Applications/BlueStacks.app/Contents/img/initrd_hvf.img{,.bak}
> ```
>
> 之后即可用它回滚：
>
> ```bash
> sudo cp /Applications/BlueStacks.app/Contents/img/initrd_hvf.img.bak \
>         /Applications/BlueStacks.app/Contents/img/initrd_hvf.img
> ```

### 降级 BlueStacks

新版 BlueStacks 有兼容问题时（如上文 790 的视频变灰），可以降回旧版，实例数据保留。以下步骤 2026-10-04 实测从 790.7505 降到 782.7501：

1. **获取旧版安装包**：官网只提供最新版。旧版的官方地址和 SHA256 可以在 homebrew-cask 的 [`Casks/b/bluestacks.rb` 提交历史](https://github.com/Homebrew/homebrew-cask/commits/HEAD/Casks/b/bluestacks.rb)里找到，地址格式为 `https://ak-build.bluestacks.com/public/app-player/mac/nxt_mac2/<版本>/<哈希>/BlueStacksInstaller_<版本>.pkg`。下载后用 `shasum -a 256` 核对，再用 `pkgutil --check-signature` 确认是 now.gg 的签名且经过公证。
2. **完全退出 BlueStacks**，含 multi-instance manager。
3. **备份**：在 APFS 上用写时复制克隆，瞬间完成，也不额外占空间：
   ```bash
   B="/Users/Shared/Library/Application Support/BlueStacks"
   cp -c  "$B/bluestacks.conf" "$B/bluestacks.conf.bak.<日期>"
   cp -cR "$B/Engine"          "$B/Engine.bak.<日期>"
   ```
4. **绕过降级拦截**：安装程序判断已装版本时读的是 `bluestacks.conf` 里的 `bst.version`，遇到相同或更高的版本会报 `Same or higher version already installed` 并退出。把它改成比目标版本略低的值，安装程序就会走「升级」流程，保留实例数据；装完后它会自动写回正确的版本号：
   ```bash
   sed -i '' 's/^bst\.version=".*"$/bst.version="5.21.782.7500"/' "$B/bluestacks.conf"
   ```
5. **安装**：`sudo installer -pkg BlueStacksInstaller_<版本>.pkg -target /`。安装完成后会自动启动 BlueStacks，需要先把它完全退出。
6. **重新打补丁**：降级会把 initrd 换回旧版的原版镜像，root 会丢失，需要重跑 `./update.sh`。

> 降级前先确认实例的 data 分区没被新版用 casefold 格式化过：实例的 `qvirt.log` 里出现 `Skipping casefold format to preserve data`，说明数据分区未被改动，旧版可以直接读取。
>
> 用 Homebrew 安装的话，降级后 Homebrew 仍记录着新版本号。等 BlueStacks 发布比它更新的版本时，不带参数的 `brew upgrade` 会自动把 BlueStacks 升上去，所以要么用 `brew upgrade --formula`，要么升级前先确认兼容性。

---

## 注意事项

- **initrd 是 App 级而非实例级** —— 补丁对**所有实例**生效。跑银行类或有完整性检测的应用的实例，建议配置 Magisk DenyList。
- **Play Integrity / SafetyNet** 更易被检测到。
- 修改 App Bundle 内部会破坏代码签名。
- BlueStacks 更新后需重新打补丁。更新会连带替换 `kernel_hvf` 与 initrd 内的 `.ko` 模块，旧版 initrd 与新内核不配套 —— **部署新补丁前先用新版纯净镜像刷新 `.bak`**（`sudo cp …/initrd_hvf.img{,.bak}`），否则 `.bak` 回滚会装上旧模块。

---

## 文件

| 文件 | 说明 |
|---|---|
| `update.sh` | 一键流程：调用 `repatch.sh` → 刷新 `.bak` → 部署 → 启动并验证 root |
| `repatch.sh` | 重新打补丁脚本，含多重前置校验；只生成镜像，不部署 |
| `initrd_original.img` | 纯净原始镜像，SHA256 `d489725a…45326b`（BlueStacks 5.21.782.7501） |
| `initrd_patched.img` | 已打补丁镜像，SHA256 `b76eb0b1…a6ff97`（BlueStacks 5.21.782.7501） |
| `magisk-bin/` | Kitsune 的 `magisk64` / `magiskinit` / `magiskpolicy` / `stub.apk` |
| `magisk.rc` | Magisk 的 init 服务定义 |
| `kitsune.apk` | Kitsune Mask 管理器，需装进实例 |

已验证环境（均为 Android 13 (API 33)，arm64-v8a，Kitsune 31.0）：

- BlueStacks Air **5.21.782.7501**（首次验证；**当前使用版本**，2026-10-04 从 790 降级回来，见「降级 BlueStacks」）
- BlueStacks Air **5.21.790.7505**（2026-10-04；`stage2.sh` 未变，脚本零改动通过。新版仅在 `bstsetup.env` 中为 data 分区加入 casefold，已有数据的实例不会被重格式化）
  - ⚠️ **已知问题，与 root 无关**：Unity 游戏内视频只有声音、画面全灰。实测 DNF 手游（`com.tencent.tmgp.dnf` 129.5.10.0，Unity 2022.3.74f1）开屏动画复现，降回 782 后恢复。视频解码本身正常，是 790 的 GLES 模拟层拒绝了 Unity 绑定视频纹理的调用，每次播放 logcat 都会出现 `GL2Encoder.cpp:s_glBindTexture … GL error 0x502`。Unity 拿不到画面，就用默认灰色纹理顶替。该游戏包未打包 Vulkan 后端，无法用 `-force-vulkan` 绕过

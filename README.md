# macos-update-clean-4-opencore

一组围绕 macOS 软件更新链路的脚本，目标是：

- 尽量彻底关闭 Apple 原生更新检查、下载和通知
- 清理会影响 OpenCore Legacy Patcher Post-Install Root Patch 的本地更新污染
- 用只读脚本验证当前系统是否仍存在更新残留
- 在需要时撤销上述修改，恢复系统更新能力

## 适用范围

- 脚本没有把 `15.7.4` 或某个固定 build 写死到执行逻辑里
- 清理脚本和检查脚本会动态读取当前系统的 `ProductVersion` / `BuildVersion`，然后把“本机当前版本”作为干净基线
- 目前是按 `macOS 15.7.4 (24G517)` 的实际环境验证和迭代出来的，尤其针对这套 Apple Software Update 路径、`launchd` 标签以及 OCLP staged-update watcher
- 对同一代或相邻版本、且仍保留相同路径和服务标签的系统，通常也可以用
- 如果未来 macOS 大版本改了 `launchd` 标签、`AssetsV2` 路径、`Software Update` 偏好键名，脚本就需要再调整

## 脚本

### `disable_macos_updates.sh`

用途：

- 关闭 `softwareupdate` 定时检查
- 关闭系统级和用户级更新相关 `launchd` job
- 在 `/etc/hosts` 中写入一段受控的更新域名 blocklist
- 清理 Apple 原生更新提醒和 `System Settings`/`Software Update` 相关的用户级提示

说明：

- 这是“阻断更新链路”的脚本，不负责 OCLP 专用缓存清理
- 会重启 `Dock`、`NotificationCenter`、`System Settings` 等进程来刷新 UI

### `clean_oclp_update_pollution.sh`

用途：

- 停掉 OCLP 中直接盯 `Preflight.plist` / `Update.plist` 的 watcher
- 清理 `/Library/Updates` 和 `AssetsV2` 里的更新元数据
- 清理系统级和用户级 `SoftwareUpdate` 相关缓存和提示
- 将几个关键目录设为 `uchg`，降低污染文件再次生成的概率

说明：

- 这是“清理 + 硬化”脚本，面向 OCLP `Post-Install Root Patch`
- 不会动 OCLP 的 `auto-patch` 背景进程

### `check_oclp_update_cleanliness.sh`

用途：

- 只读检查当前系统里是否还留有更新污染
- 检查 Apple 原生更新链和 OCLP watcher 是否仍处于启用状态
- 检查关键缓存目录是否已经被冻结

说明：

- 不会改系统
- 用于执行清理后做验收

### `restore_macos_updates.sh`

用途：

- 重新启用 Apple 原生更新链
- 移除 `/etc/hosts` 里由脚本管理的 blocklist
- 解除 `uchg` 冻结

说明：

- 这是“尽量恢复”为正常更新状态的脚本
- 不会恢复你手动清掉的缓存文件内容，只会解除阻断和硬化措施

## 典型流程

### 禁用并清理

```bash
sudo zsh ./disable_macos_updates.sh
sudo zsh ./clean_oclp_update_pollution.sh
zsh ./check_oclp_update_cleanliness.sh
```

### 恢复

```bash
sudo zsh ./restore_macos_updates.sh
```

## 风险提示

- 这些脚本会改 `launchctl` 状态、`/etc/hosts`、`/Library/Updates`、`AssetsV2` 目录标志
- 如果你以后还想正常使用 macOS 更新，建议执行恢复脚本
- `System Settings` 侧栏里的红底数字可能是 UI 缓存残留；只要验收脚本全绿，一般不会再影响 OCLP patching

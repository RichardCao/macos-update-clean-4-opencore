#!/bin/zsh

set -euo pipefail

# Undo the blocking/hardening steps from the other scripts so Apple-native
# software update services and caches can function normally again.

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
fi

hosts_block_start="# >>> macOS update blocklist >>>"
hosts_block_end="# <<< macOS update blocklist <<<"
chflags_bin="$(command -v chflags 2>/dev/null || true)"
if [[ -z "${chflags_bin}" ]]; then
  chflags_bin="/bin/chflags"
fi

if (( ! dry_run )) && [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行: sudo $0"
  exit 1
fi

console_user="$(stat -f%Su /dev/console)"
console_uid="$(id -u "${console_user}" 2>/dev/null || true)"
console_home="$(dscl . -read "/Users/${console_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${console_home}" && -d "/Users/${console_user}" ]]; then
  console_home="/Users/${console_user}"
fi

run_quietly() {
  if (( dry_run )); then
    echo "[dry-run] 将执行: $*"
  else
    "$@" >/dev/null 2>&1 || true
  fi
}

write_bool_pref() {
  local plist="$1"
  local key="$2"
  local value="$3"
  local current_value="<unset>"
  current_value="$(/usr/bin/defaults read "${plist}" "${key}" 2>/dev/null || true)"
  if [[ -z "${current_value}" ]]; then
    current_value="<unset>"
  fi

  if (( dry_run )); then
    echo "[dry-run] 将写入 ${plist} : ${key}=${value} (当前: ${current_value})"
  else
    /usr/bin/defaults write "${plist}" "${key}" -bool "${value}" >/dev/null
  fi
}

run_chflags() {
  local flag="$1"
  shift
  if (( dry_run )); then
    echo "[dry-run] 将执行: ${chflags_bin} ${flag} $*"
  else
    if ! "${chflags_bin}" "${flag}" "$@" >/dev/null 2>&1; then
      echo "警告: 执行 ${chflags_bin} ${flag} $* 失败" >&2
    fi
  fi
}

remove_hosts_block() {
  local hosts_path="/etc/hosts"
  local tmp_path
  tmp_path="$(/usr/bin/mktemp)"

  /usr/bin/awk -v start="${hosts_block_start}" -v end="${hosts_block_end}" '
    $0 == start { in_block=1; next }
    $0 == end { in_block=0; next }
    !in_block { print }
  ' "${hosts_path}" > "${tmp_path}"

  if (( dry_run )); then
    echo "[dry-run] 将从 ${hosts_path} 移除由 restore_macos_updates.sh 管理的更新屏蔽区块"
    /bin/rm -f "${tmp_path}"
  else
    /bin/cp -p "${hosts_path}" "${hosts_path}.codex-restore-backup.$(/bin/date +%Y%m%d-%H%M%S)"
    /bin/cp "${tmp_path}" "${hosts_path}"
    /bin/rm -f "${tmp_path}"
  fi
}

enable_system_job() {
  local label="$1"
  local plist_path="/System/Library/LaunchDaemons/${label}.plist"
  run_quietly /bin/launchctl enable "system/${label}"
  if [[ -f "${plist_path}" ]]; then
    run_quietly /bin/launchctl bootstrap system "${plist_path}"
    run_quietly /bin/launchctl kickstart -k "system/${label}"
  fi
}

enable_user_job() {
  local label="$1"
  local plist_path="/System/Library/LaunchAgents/${label}.plist"
  if [[ -n "${console_uid:-}" && -n "${console_home:-}" && "${console_user}" != "root" && -f "${plist_path}" ]]; then
    run_quietly /bin/launchctl enable "gui/${console_uid}/${label}"
    run_quietly /bin/launchctl bootstrap "gui/${console_uid}" "${plist_path}"
    run_quietly /bin/launchctl kickstart -k "gui/${console_uid}/${label}"
  fi
}

unfreeze_if_exists() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    run_chflags -R nouchg "${path}"
  elif (( dry_run )); then
    echo "[dry-run] 跳过解冻 ${path}，路径不存在"
  fi
}

echo "[1/4] 恢复软件更新与 App Store 偏好..."
run_quietly /usr/sbin/softwareupdate --schedule on
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticCheckEnabled true
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticDownload true
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticallyInstallMacOSUpdates true
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist ConfigDataInstall true
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist CriticalUpdateInstall true
write_bool_pref /Library/Preferences/com.apple.commerce.plist AutoUpdate true
write_bool_pref /Library/Preferences/com.apple.commerce.plist AutoUpdateRestartRequired true
if [[ -n "${console_home:-}" && -d "${console_home}/Library/Preferences" ]]; then
  write_bool_pref "${console_home}/Library/Preferences/com.apple.commerce.plist" AutoUpdate true
  write_bool_pref "${console_home}/Library/Preferences/com.apple.commerce.plist" AutoUpdateRestartRequired true
fi

echo "[2/4] 移除 /etc/hosts 中受控的软件更新屏蔽区块..."
remove_hosts_block

echo "[3/4] 解除关键更新缓存目录的 uchg 冻结..."
unfreeze_if_exists /Library/Updates
unfreeze_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate
unfreeze_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain

echo "[4/4] 重新启用被禁用的系统与用户级更新服务..."
enable_system_job com.apple.softwareupdated
enable_system_job com.apple.mobile.softwareupdated
enable_system_job com.apple.softwareupdate_firstrun_tasks
enable_user_job com.apple.SoftwareUpdateNotificationManager
enable_user_job com.apple.appstoreagent

run_quietly /usr/bin/killall cfprefsd
run_quietly /usr/bin/killall usernoted
run_quietly /usr/bin/killall NotificationCenter
run_quietly /usr/bin/killall Dock
run_quietly /usr/bin/killall "System Settings"

echo
if (( dry_run )); then
  echo "以上为 dry-run 预演，系统未被修改。"
else
  echo "恢复完成。建议手动重启一次，确保 launchd、Dock 和 System Settings 全部回到正常状态。"
fi

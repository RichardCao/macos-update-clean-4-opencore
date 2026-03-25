#!/bin/zsh

set -euo pipefail

# Disable Apple-native update services, block update domains, and clear
# Software Update / System Settings UI state that can re-surface notices.

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
fi

hosts_block_start="# >>> macOS update blocklist >>>"
hosts_block_end="# <<< macOS update blocklist <<<"
hosts_entries=(
  "127.0.0.1 gdmf.apple.com"
  "127.0.0.1 mesu.apple.com"
  "127.0.0.1 swcdn.apple.com"
  "127.0.0.1 swdist.apple.com"
  "127.0.0.1 swdownload.apple.com"
  "127.0.0.1 swscan.apple.com"
  "127.0.0.1 update.cdn-apple.com"
  "127.0.0.1 updates.cdn-apple.com"
  "127.0.0.1 xp.apple.com"
  "127.0.0.1 gg.apple.com"
  "127.0.0.1 gs.apple.com"
  "127.0.0.1 ig.apple.com"
  "127.0.0.1 skl.apple.com"
)

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

if [[ -z "${console_user}" || "${console_user}" == "root" || -z "${console_uid}" || -z "${console_home}" ]]; then
  echo "未检测到有效的登录用户，会跳过用户会话级别的通知/Agent 处理。"
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

delete_pref_key() {
  local plist="$1"
  local key="$2"
  local current_value="<absent>"
  current_value="$(/usr/bin/defaults read "${plist}" "${key}" 2>/dev/null || true)"
  if [[ -z "${current_value}" ]]; then
    current_value="<absent>"
  fi

  if (( dry_run )); then
    echo "[dry-run] 将删除 ${plist} : ${key} (当前: ${current_value})"
  else
    /usr/bin/defaults delete "${plist}" "${key}" >/dev/null 2>&1 || true
  fi
}

delete_plistbuddy_key() {
  local plist="$1"
  local key_path="$2"
  local current_value="<absent>"
  current_value="$(
    /usr/libexec/PlistBuddy -c "Print ${key_path}" "${plist}" 2>/dev/null || true
  )"
  if [[ -z "${current_value}" ]]; then
    current_value="<absent>"
  fi

  if (( dry_run )); then
    echo "[dry-run] 将删除 ${plist} : ${key_path} (当前: ${current_value})"
  else
    /usr/libexec/PlistBuddy -c "Delete ${key_path}" "${plist}" >/dev/null 2>&1 || true
  fi
}

update_hosts_block() {
  local hosts_path="/etc/hosts"
  local tmp_path
  tmp_path="$(/usr/bin/mktemp)"

  /usr/bin/awk -v start="${hosts_block_start}" -v end="${hosts_block_end}" '
    $0 == start { in_block=1; next }
    $0 == end { in_block=0; next }
    !in_block { print }
  ' "${hosts_path}" > "${tmp_path}"

  {
    echo
    echo "${hosts_block_start}"
    echo "# Managed by disable_macos_updates.sh"
    local entry
    for entry in "${hosts_entries[@]}"; do
      echo "${entry}"
    done
    echo "${hosts_block_end}"
  } >> "${tmp_path}"

  if (( dry_run )); then
    echo "[dry-run] 将更新 ${hosts_path}，追加/刷新以下屏蔽条目:"
    /bin/cat "${tmp_path}" | /usr/bin/sed -n "/^${hosts_block_start}$/,/^${hosts_block_end}$/p"
    /bin/rm -f "${tmp_path}"
  else
    /bin/cp -p "${hosts_path}" "${hosts_path}.codex-backup.$(/bin/date +%Y%m%d-%H%M%S)"
    /bin/cp "${tmp_path}" "${hosts_path}"
    /bin/rm -f "${tmp_path}"
  fi
}

disable_system_job() {
  local label="$1"
  run_quietly /bin/launchctl disable "system/${label}"
  run_quietly /bin/launchctl bootout system "/System/Library/LaunchDaemons/${label}.plist"
}

disable_user_job() {
  local label="$1"
  if [[ -n "${console_uid:-}" && -n "${console_home:-}" && "${console_user}" != "root" ]]; then
    run_quietly /bin/launchctl disable "gui/${console_uid}/${label}"
    run_quietly /bin/launchctl bootout "gui/${console_uid}" "/System/Library/LaunchAgents/${label}.plist"
  fi
}

clear_update_ui_badges() {
  if [[ -z "${console_home:-}" || ! -d "${console_home}/Library/Preferences" ]]; then
    return
  fi

  delete_pref_key "${console_home}/Library/Preferences/com.apple.preferences.softwareupdate.plist" ProductKeysLastSeenByUser
  delete_plistbuddy_key "${console_home}/Library/Preferences/com.apple.systempreferences.plist" ":AttentionPrefBundleIDs:com.apple.Software-Update-Settings.extension"
  delete_plistbuddy_key "${console_home}/Library/Preferences/com.apple.systempreferences.plist" ":AttentionPrefBundleIDs:com.apple.FollowUpSettings.FollowUpSettingsExtension"
  if (( dry_run )); then
    echo "[dry-run] 将删除 ${console_home}/Library/Group Containers/com.apple.systempreferences.cache/com.apple.systemsettings.usercache"
  else
    /bin/rm -f "${console_home}/Library/Group Containers/com.apple.systempreferences.cache/com.apple.systemsettings.usercache" >/dev/null 2>&1 || true
  fi
}

echo "[1/6] 关闭软件更新检查与自动安装偏好..."
run_quietly /usr/sbin/softwareupdate --schedule off
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticCheckEnabled false
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticDownload false
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticallyInstallMacOSUpdates false
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist ConfigDataInstall false
write_bool_pref /Library/Preferences/com.apple.SoftwareUpdate.plist CriticalUpdateInstall false

echo "[2/6] 关闭 App Store 自动更新偏好..."
write_bool_pref /Library/Preferences/com.apple.commerce.plist AutoUpdate false
write_bool_pref /Library/Preferences/com.apple.commerce.plist AutoUpdateRestartRequired false

if [[ -n "${console_home:-}" && -d "${console_home}/Library/Preferences" ]]; then
  write_bool_pref "${console_home}/Library/Preferences/com.apple.commerce.plist" AutoUpdate false
  write_bool_pref "${console_home}/Library/Preferences/com.apple.commerce.plist" AutoUpdateRestartRequired false
fi

echo "[3/6] 更新 /etc/hosts 屏蔽已知软件更新域名..."
update_hosts_block

echo "[4/6] 禁用系统级更新守护进程..."
disable_system_job com.apple.softwareupdated
disable_system_job com.apple.mobile.softwareupdated
disable_system_job com.apple.softwareupdate_firstrun_tasks

echo "[5/6] 禁用用户会话里的更新通知和 App Store 更新 Agent..."
disable_user_job com.apple.SoftwareUpdateNotificationManager
disable_user_job com.apple.appstoreagent

echo "[6/6] 清理已经缓存的更新提醒状态..."
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist RecommendedUpdates
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist FirstOfferDateDictionary
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastRecommendedMajorOSBundleIdentifier

if [[ -n "${console_home:-}" && -d "${console_home}/Library/Preferences" ]]; then
  delete_pref_key "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" AvailableUpdatesNotificationCountKey
  delete_pref_key "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" AvailableUpdatesNotificationProductKey
  delete_pref_key "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" UserNotificationDate
  clear_update_ui_badges
fi

run_quietly /usr/bin/killall cfprefsd
run_quietly /usr/bin/killall usernoted
run_quietly /usr/bin/killall NotificationCenter
run_quietly /usr/bin/killall Dock
run_quietly /usr/bin/killall "System Settings"

echo
echo "已完成。当前建议手动执行一次重启，确保被 bootout 的系统/用户级 job 不会在当前会话里残留状态。"
if (( dry_run )); then
  echo "以上为 dry-run 预演，系统未被修改。"
fi
echo "重启后可用以下命令自检："
echo "  softwareupdate --schedule"
echo "  launchctl print-disabled system | egrep 'softwareupdated|softwareupdate_firstrun_tasks'"
if [[ -n "${console_uid:-}" && "${console_user}" != "root" ]]; then
  echo "  launchctl print-disabled gui/${console_uid} | egrep 'SoftwareUpdateNotificationManager|appstoreagent'"
fi

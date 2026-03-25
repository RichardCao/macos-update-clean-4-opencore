#!/bin/zsh

set -euo pipefail

# Remove local update metadata that can confuse OCLP root patching, then
# harden a few cache directories so the same metadata is harder to recreate.

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
fi

chflags_bin="$(command -v chflags 2>/dev/null || true)"
if [[ -z "${chflags_bin}" ]]; then
  chflags_bin="/bin/chflags"
fi

if (( ! dry_run )) && [[ "${EUID}" -ne 0 ]]; then
  echo "请用 sudo 运行: sudo $0"
  exit 1
fi

current_version="$(sw_vers -productVersion)"
current_build="$(sw_vers -buildVersion)"
backup_root="/Users/Shared/OCLP-update-cleanup-backup-$(date +%Y%m%d-%H%M%S)"

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

ensure_dir_exists() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    return
  fi

  if (( dry_run )); then
    echo "[dry-run] 将创建目录 ${path}"
  else
    /bin/mkdir -p "${path}"
  fi
}

backup_file_if_exists() {
  local src="$1"
  if [[ -e "${src}" ]]; then
    local rel="${src#/}"
    local dst="${backup_root}/${rel}"
    if (( dry_run )); then
      echo "[dry-run] 将备份 ${src} -> ${dst}"
    else
      /bin/mkdir -p "$(dirname "${dst}")"
      /bin/cp -Rp "${src}" "${dst}"
    fi
  elif (( dry_run )); then
    echo "[dry-run] 跳过备份 ${src}，文件不存在"
  fi
}

remove_if_exists() {
  local src="$1"
  if [[ -e "${src}" ]]; then
    backup_file_if_exists "${src}"
    if (( dry_run )); then
      echo "[dry-run] 将删除 ${src}"
    else
      /bin/rm -f "${src}"
    fi
  elif (( dry_run )); then
    echo "[dry-run] 跳过删除 ${src}，文件不存在"
  fi
}

unfreeze_path_if_exists() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    run_chflags -R nouchg "${path}"
  elif (( dry_run )); then
    echo "[dry-run] 跳过解冻 ${path}，路径不存在"
  fi
}

freeze_path_if_exists() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    run_chflags uchg "${path}"
  elif (( dry_run )); then
    echo "[dry-run] 跳过冻结 ${path}，路径不存在"
  fi
}

bootout_if_present() {
  local domain="$1"
  local label="$2"
  local plist_path="$3"
  if [[ -f "${plist_path}" ]]; then
    run_quietly /bin/launchctl disable "${domain}/${label}"
    if [[ "${domain}" == system ]]; then
      run_quietly /bin/launchctl bootout system "${plist_path}"
    else
      run_quietly /bin/launchctl bootout "${domain}" "${plist_path}"
    fi
  elif (( dry_run )); then
    echo "[dry-run] 跳过 ${label}，未找到 ${plist_path}"
  fi
}

echo "当前系统版本: ${current_version} (${current_build})"
echo "备份目录: ${backup_root}"
echo

echo "[1/6] 先停掉 OCLP 针对 staged update 的 watcher..."
bootout_if_present system com.dortania.opencore-legacy-patcher.macos-update /Library/LaunchDaemons/com.dortania.opencore-legacy-patcher.macos-update.plist
bootout_if_present system com.dortania.opencore-legacy-patcher.os-caching /Library/LaunchDaemons/com.dortania.opencore-legacy-patcher.os-caching.plist

echo "[2/6] 解冻将要清理/重建的更新缓存目录..."
unfreeze_path_if_exists /Library/Updates
unfreeze_path_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate
unfreeze_path_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain

echo "[3/6] 备份并移除 OCLP 会监视的 staged update 文件..."
remove_if_exists /System/Volumes/Update/Preflight.plist
remove_if_exists /System/Volumes/Update/Update.plist

echo "[4/6] 备份并移除本机缓存的更新产品元数据..."
remove_if_exists /Library/Updates/ProductMetadata.plist
remove_if_exists /Library/Updates/index.plist
remove_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml
remove_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml.purged
remove_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain.xml
remove_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain.xml.purged

echo "[5/6] 清理系统级 Software Update 推荐版本与扫描痕迹..."
backup_file_if_exists /Library/Preferences/com.apple.SoftwareUpdate.plist
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist RecommendedUpdates
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist FirstOfferDateDictionary
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastRecommendedMajorOSBundleIdentifier
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist DDMPersistedErrorKey
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastBackgroundSuccessfulDate
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastSuccessfulBackgroundMSUScanDate
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastSuccessfulDate
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastFullSuccessfulDate
delete_pref_key /Library/Preferences/com.apple.SoftwareUpdate.plist LastResultCode

echo "[6/6] 清理用户会话更新提示并冻结关键更新缓存目录..."
if [[ -n "${console_home:-}" && -d "${console_home}/Library/Preferences" ]]; then
  backup_file_if_exists "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist"
  delete_pref_key "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" AvailableUpdatesNotificationCountKey
  delete_pref_key "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" AvailableUpdatesNotificationProductKey
  delete_pref_key "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" UserNotificationDate
  delete_pref_key "${console_home}/Library/Preferences/com.apple.preferences.softwareupdate.plist" ProductKeysLastSeenByUser
  delete_plistbuddy_key "${console_home}/Library/Preferences/com.apple.systempreferences.plist" ":AttentionPrefBundleIDs:com.apple.Software-Update-Settings.extension"
  delete_plistbuddy_key "${console_home}/Library/Preferences/com.apple.systempreferences.plist" ":AttentionPrefBundleIDs:com.apple.FollowUpSettings.FollowUpSettingsExtension"
  if (( dry_run )); then
    echo "[dry-run] 将删除 ${console_home}/Library/Group Containers/com.apple.systempreferences.cache/com.apple.systemsettings.usercache"
  else
    /bin/rm -f "${console_home}/Library/Group Containers/com.apple.systempreferences.cache/com.apple.systemsettings.usercache" >/dev/null 2>&1 || true
  fi
fi

ensure_dir_exists /Library/Updates
ensure_dir_exists /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate
ensure_dir_exists /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain
freeze_path_if_exists /Library/Updates
freeze_path_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate
freeze_path_if_exists /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain

run_quietly /usr/bin/killall cfprefsd
run_quietly /usr/bin/killall usernoted
run_quietly /usr/bin/killall NotificationCenter
run_quietly /usr/bin/killall Dock
run_quietly /usr/bin/killall "System Settings"

echo
echo "清理完成。建议下一步："
echo "  1. 先运行 disable_macos_updates.sh，确保 Apple 原生更新链已禁用。"
echo "  2. 然后重启一次。"
echo "  3. 如需确认是否还残留高版本信息，再检查以下文件："
echo "     /Library/Preferences/com.apple.SoftwareUpdate.plist"
echo "     /Users/${console_user}/Library/Preferences/com.apple.SoftwareUpdate.plist"
echo "     /Library/Updates/ProductMetadata.plist"
echo "     /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml"
echo "     /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain.xml"
echo "     /System/Volumes/Update/Preflight.plist"
echo "     /System/Volumes/Update/Update.plist"
echo
echo "说明: 脚本只停掉 OCLP 中直接跟 staged update 相关的 macos-update / os-caching watcher，"
echo "不会动 auto-patch 背景进程，避免影响你后续手动执行 Post-Install Root Patch。"
echo "同时会将 /Library/Updates 及两个 AssetsV2 更新缓存目录设为 uchg，降低重新生成关键污染文件的概率。"
if (( dry_run )); then
  echo "以上为 dry-run 预演，系统未被修改。"
fi

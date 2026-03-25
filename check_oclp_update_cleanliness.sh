#!/bin/zsh

set -euo pipefail

# Read-only validation for update-related residue that can interfere with OCLP
# root patching. This script intentionally does not modify system state.

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "[dry-run] 该脚本本身是只读检查，dry-run 等同于正常执行。"
  echo
fi

current_version="$(sw_vers -productVersion)"
current_build="$(sw_vers -buildVersion)"
script_dir="$(cd "$(dirname "$0")" && pwd)"

console_user="$(stat -f%Su /dev/console)"
console_uid="$(id -u "${console_user}" 2>/dev/null || true)"
console_home="$(dscl . -read "/Users/${console_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
if [[ -z "${console_home}" && -d "/Users/${console_user}" ]]; then
  console_home="/Users/${console_user}"
fi

issues=0

note_ok() {
  echo "[OK] $1"
}

note_warn() {
  echo "[WARN] $1"
  issues=$((issues + 1))
}

note_info() {
  echo "[INFO] $1"
}

check_frozen() {
  local path="$1"
  local label="$2"
  local flags
  if [[ ! -e "${path}" ]]; then
    note_warn "${label}: 路径不存在 ${path}"
    return
  fi

  flags="$(/bin/ls -ldO "${path}" 2>/dev/null || true)"
  if echo "${flags}" | /usr/bin/grep -q 'uchg'; then
    note_ok "${label}: 已冻结 (uchg)"
  else
    note_warn "${label}: 未冻结 (缺少 uchg)"
  fi
}

file_exists_warn() {
  local path="$1"
  local label="$2"
  if [[ -e "${path}" ]]; then
    note_warn "${label}: 仍然存在 ${path}"
  else
    note_ok "${label}: 未发现 ${path}"
  fi
}

plist_key_exists_warn() {
  local plist="$1"
  local key="$2"
  local label="$3"
  if /usr/bin/defaults read "${plist}" "${key}" >/dev/null 2>&1; then
    local value
    value="$(/usr/bin/defaults read "${plist}" "${key}" 2>/dev/null || true)"
    note_warn "${label}: ${plist} 里仍有 ${key} = ${value}"
  else
    note_ok "${label}: ${plist} 不含 ${key}"
  fi
}

scan_for_foreign_versions() {
  local path="$1"
  local label="$2"
  if [[ ! -e "${path}" ]]; then
    note_ok "${label}: 文件不存在"
    return
  fi

  local mismatches
  mismatches="$(
    /usr/bin/plutil -convert xml1 -o - "${path}" 2>/dev/null \
      | /usr/bin/awk -v current_version="${current_version}" -v current_build="${current_build}" '
          /<key>OSVersion<\/key>/ { getline; if ($0 ~ /<string>/) { gsub(/.*<string>|<\/string>.*/, "", $0); os=$0; if (os != current_version) print "OSVersion=" os; next } }
          /<key>VERSION<\/key>/ { getline; if ($0 ~ /<string>/) { gsub(/.*<string>|<\/string>.*/, "", $0); os=$0; if (os != current_version) print "VERSION=" os; next } }
          /<key>Build<\/key>/ { getline; if ($0 ~ /<string>/) { gsub(/.*<string>|<\/string>.*/, "", $0); build=$0; if (build != current_build) print "Build=" build; next } }
          /<key>BUILD<\/key>/ { getline; if ($0 ~ /<string>/) { gsub(/.*<string>|<\/string>.*/, "", $0); build=$0; if (build != current_build) print "BUILD=" build; next } }
        ' \
      | /usr/bin/sort -u
  )"

  if [[ -n "${mismatches}" ]]; then
    note_warn "${label}: 发现非当前系统版本/构建信息 -> $(echo "${mismatches}" | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')"
  else
    note_ok "${label}: 未发现高于或不同于当前系统的版本/构建信息"
  fi
}

check_launchctl_disabled() {
  local domain="$1"
  local label="$2"
  local label_text="$3"
  local output

  if ! output="$(/bin/launchctl print-disabled "${domain}" 2>/dev/null)"; then
    note_info "${label_text}: 无法读取 ${domain} 的 disable 状态"
    return
  fi

  if echo "${output}" | /usr/bin/grep -F "\"${label}\" => disabled" >/dev/null 2>&1; then
    note_ok "${label_text}: 已 disabled"
  else
    note_warn "${label_text}: 还没有 disabled"
  fi
}

echo "当前系统: ${current_version} (${current_build})"
echo
echo "检查 staged update 状态..."
file_exists_warn /System/Volumes/Update/Preflight.plist "OCLP staged update preflight"
file_exists_warn /System/Volumes/Update/Update.plist "OCLP staged update payload"

echo
echo "检查 Apple Software Update 缓存..."
plist_key_exists_warn /Library/Preferences/com.apple.SoftwareUpdate.plist RecommendedUpdates "系统级推荐更新"
plist_key_exists_warn /Library/Preferences/com.apple.SoftwareUpdate.plist FirstOfferDateDictionary "系统级 first-offer 记录"
plist_key_exists_warn /Library/Preferences/com.apple.SoftwareUpdate.plist LastRecommendedMajorOSBundleIdentifier "系统级 major update 记录"
scan_for_foreign_versions /Library/Updates/ProductMetadata.plist "ProductMetadata"
scan_for_foreign_versions /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml "MacSoftwareUpdate asset"
scan_for_foreign_versions /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain.xml "MacUpdateBrain asset"

echo
echo "检查用户会话更新通知痕迹..."
if [[ -n "${console_home:-}" && -d "${console_home}/Library/Preferences" ]]; then
  plist_key_exists_warn "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" AvailableUpdatesNotificationCountKey "用户级通知计数"
  plist_key_exists_warn "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" AvailableUpdatesNotificationProductKey "用户级通知产品键"
  plist_key_exists_warn "${console_home}/Library/Preferences/com.apple.SoftwareUpdate.plist" UserNotificationDate "用户级通知时间"
  plist_key_exists_warn "${console_home}/Library/Preferences/com.apple.preferences.softwareupdate.plist" ProductKeysLastSeenByUser "Software Update 侧栏已见产品键"
else
  note_info "未检测到有效登录用户，跳过用户级 SoftwareUpdate.plist 检查"
fi

echo
echo "检查 Apple 原生更新链是否仍可能写回状态..."
check_launchctl_disabled system com.apple.softwareupdated "com.apple.softwareupdated"
check_launchctl_disabled system com.apple.mobile.softwareupdated "com.apple.mobile.softwareupdated"
check_launchctl_disabled system com.apple.softwareupdate_firstrun_tasks "com.apple.softwareupdate_firstrun_tasks"
if [[ -n "${console_uid:-}" && "${console_user}" != "root" ]]; then
  check_launchctl_disabled "gui/${console_uid}" com.apple.SoftwareUpdateNotificationManager "com.apple.SoftwareUpdateNotificationManager"
  check_launchctl_disabled "gui/${console_uid}" com.apple.appstoreagent "com.apple.appstoreagent"
else
  note_info "未检测到有效登录用户，跳过用户级 LaunchAgent 检查"
fi

echo
echo "检查 OCLP staged-update watcher 状态..."
check_launchctl_disabled system com.dortania.opencore-legacy-patcher.macos-update "OCLP macos-update watcher"
check_launchctl_disabled system com.dortania.opencore-legacy-patcher.os-caching "OCLP os-caching watcher"

echo
echo "检查关键更新缓存目录是否已冻结..."
check_frozen /Library/Updates "/Library/Updates"
check_frozen /System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate "MacSoftwareUpdate cache dir"
check_frozen /System/Library/AssetsV2/com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain "MacUpdateBrain cache dir"

echo
if (( issues == 0 )); then
  echo "结论: 当前未发现明显的更新污染，适合继续做 OCLP Post-Install Root Patch。"
  exit 0
else
  echo "结论: 发现 ${issues} 项可能影响 OCLP Post-Install Root Patch 的更新残留或活跃链路。"
  echo "建议先运行:"
  echo "  sudo ${script_dir}/disable_macos_updates.sh"
  echo "  sudo ${script_dir}/clean_oclp_update_pollution.sh"
  echo "然后重启，再重新执行本脚本。"
  exit 1
fi

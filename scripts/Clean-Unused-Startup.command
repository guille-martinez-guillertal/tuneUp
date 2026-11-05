#!/bin/bash
# Targeted cleanup for the startup entries reviewed in TuneUp reports.
# No wildcards are used for removal. Run as your normal logged-in user.
set -u
set -o pipefail
export LC_ALL=C

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  echo 'This script is for macOS only.' >&2
  exit 1
fi
if [[ "$EUID" -eq 0 ]]; then
  echo 'Run this as your normal user, without sudo. It requests sudo when needed.' >&2
  exit 1
fi

mode="${1:---interactive}"
case "$mode" in
  --interactive|--preview|--apply) ;;
  --restore) ;;
  *) echo 'Usage: Clean-Unused-Startup.command [--preview | --apply | --restore BACKUP_ID]'; exit 1 ;;
esac

user_uid="$(/usr/bin/id -u)"
archive_root='/Library/Application Support/TuneUp/StartupBackups'
# Index, relative archive path, original path. Paths are fixed, not read from reports.
relative=(
  'user-agents/com.adobe.AAM.Updater-1.0.plist'
  'user-agents/com.skype.skype.shareagent.plist'
  'system-agents/com.adobe.AAM.Updater-1.0.plist'
  'system-agents/com.adobe.ARMDCHelper.cc24aef4a1b90ed56a725c38014c95072f92651fb65e1bf9c8e43c37a23d420d.plist'
  'system-agents/com.microsoft.entraidentitybrokerxpc.plist'
  'system-agents/com.sony.SonyAutoLauncher.agent.plist'
  'system-agents/com.sony.WirelessAutoImportLauncher.agent.plist'
  'system-daemons/com.adobe.ARMDC.Communicator.plist'
  'system-daemons/com.adobe.ARMDC.SMJobBlessHelper.plist'
)
original=(
  "$HOME/Library/LaunchAgents/com.adobe.AAM.Updater-1.0.plist"
  "$HOME/Library/LaunchAgents/com.skype.skype.shareagent.plist"
  '/Library/LaunchAgents/com.adobe.AAM.Updater-1.0.plist'
  '/Library/LaunchAgents/com.adobe.ARMDCHelper.cc24aef4a1b90ed56a725c38014c95072f92651fb65e1bf9c8e43c37a23d420d.plist'
  '/Library/LaunchAgents/com.microsoft.entraidentitybrokerxpc.plist'
  '/Library/LaunchAgents/com.sony.SonyAutoLauncher.agent.plist'
  '/Library/LaunchAgents/com.sony.WirelessAutoImportLauncher.agent.plist'
  '/Library/LaunchDaemons/com.adobe.ARMDC.Communicator.plist'
  '/Library/LaunchDaemons/com.adobe.ARMDC.SMJobBlessHelper.plist'
)

# Avoid following symlinks when archiving or restoring privileged startup files.
check_archive_parents() {
  local directory
  for directory in '/Library/Application Support/TuneUp' "$archive_root"; do
    if [[ -L "$directory" ]]; then
      echo "Refusing symlink: $directory" >&2; return 1
    fi
    if [[ -e "$directory" ]]; then
      if [[ ! -d "$directory" ]] || [[ "$(/usr/bin/stat -f '%u' "$directory")" != 0 ]]; then
        echo "Expected a root-owned directory: $directory" >&2; return 1
      fi
      # Refuse group/other writable parents, even if root-owned.
      local permissions
      permissions="$(/usr/bin/stat -f '%Lp' "$directory")"
      if (( (8#$permissions & 0022) != 0 )); then
        echo "Refusing writable archive parent: $directory" >&2; return 1
      fi
    fi
  done
}

if [[ "$mode" == --restore ]]; then
  backup_id="${2:-}"
  if [[ ! "$backup_id" =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{6}$ ]]; then
    echo 'Provide the exact backup ID printed by cleanup.' >&2; exit 1
  fi
  check_archive_parents || exit 1
  /usr/bin/sudo -v || exit 1
  archive="$archive_root/$backup_id"
  if ! /usr/bin/sudo /bin/test -d "$archive" || /usr/bin/sudo /bin/test -L "$archive"; then
    echo 'Backup not found or is a symlink.' >&2; exit 1
  fi
  if [[ "$(/usr/bin/sudo /usr/bin/stat -f '%u:%Lp' "$archive")" != '0:700' ]]; then
    echo 'Backup must be root-owned with permissions 700.' >&2; exit 1
  fi
  if [[ "$(/usr/bin/sudo /bin/cat "$archive/user-uid.txt")" != "$user_uid" ]]; then
    echo 'Restore from the same user account that ran cleanup.' >&2; exit 1
  fi
  echo 'Restore these archived startup files? Existing files will never be overwritten.'
  echo 'Restore puts files back only. Services are not loaded now; existing disable flags stay unchanged.'
  read -r -p 'Type RESTORE to continue: ' answer
  [[ "$answer" == RESTORE ]] || exit 0
  failed=0
  for i in "${!original[@]}"; do
    source_file="$archive/${relative[$i]}"
    destination="${original[$i]}"
    /usr/bin/sudo /bin/test -f "$source_file" || continue
    if [[ -e "$destination" || -L "$destination" ]] || /usr/bin/sudo /bin/test -L "$source_file"; then
      echo "SKIP (exists or symlink): $destination"; failed=1; continue
    fi
    parent="$(/usr/bin/dirname "$destination")"
    if [[ ! -d "$parent" || -L "$parent" ]]; then
      echo "SKIP (missing or symlink parent): $parent"; failed=1; continue
    fi
    if /usr/bin/sudo /bin/cp -p "$source_file" "$destination"; then
      echo "RESTORED: $destination"
    else
      failed=1
    fi
  done
  echo 'Archive retained. Restart if you want restored services to run.'
  exit "$failed"
fi

# Conservative guard: do not unregister Company Portal on an enrolled Mac.
enrollment="$(/usr/bin/profiles status -type enrollment 2>&1)"
portal_allowed=false
if [[ "$enrollment" == *'Enrolled via DEP: No'* && "$enrollment" == *'MDM enrollment: No'* ]]; then
  portal_allowed=true
fi

# If an associated app still exists, skip that vendor's entries. This is a
# cleanup of explicitly unwanted software, not a general-purpose uninstaller.
vendor_present() {
  local path="$1" candidate
  case "$path" in
    *com.adobe.*)
      for candidate in /Applications/Adobe* "$HOME"/Applications/Adobe*; do
        [[ -e "$candidate" ]] && return 0
      done ;;
    *com.skype.*)
      [[ -e /Applications/Skype.app || -e "$HOME/Applications/Skype.app" ]] && return 0 ;;
    *com.microsoft.entraidentitybrokerxpc*)
      [[ "$portal_allowed" != true || -e '/Applications/Company Portal.app' || -e "$HOME/Applications/Company Portal.app" ]] && return 0 ;;
    *com.sony.*)
      [[ -e /Applications/PMHMac.app || -e '/Applications/Wireless Auto Import.app' || -e "$HOME/Applications/PMHMac.app" || -e "$HOME/Applications/Wireless Auto Import.app" ]] && return 0 ;;
  esac
  return 1
}

selected=()
echo 'TuneUp — targeted startup cleanup'
echo 'Archives only these unwanted vendors: Adobe, Skype, Company Portal, Sony.'
echo 'Google and Microsoft AutoUpdate, Office and OneDrive entries are excluded.'
echo
for i in "${!original[@]}"; do
  path="${original[$i]}"
  if [[ -L "$path" ]]; then
    echo "SKIP (symlink): $path"
  elif [[ ! -e "$path" ]]; then
    echo "ABSENT: $path"
  elif [[ ! -f "$path" ]]; then
    echo "SKIP (not a regular file): $path"
  elif vendor_present "$path"; then
    echo "SKIP (related app present, or Company Portal enrollment not confirmed absent): $path"
  else
    selected+=("$i")
    echo "ARCHIVE: $path"
  fi
done

if [[ ${#selected[@]} -eq 0 ]]; then
  echo 'No eligible files to archive. Nothing changed.'
  exit 0
fi
[[ "$mode" == --preview ]] && { echo 'Preview only. Nothing changed.'; exit 0; }
echo
echo 'System-wide entries affect all accounts on this Mac.'
echo 'No application data, documents, helper binaries, or historical crash reports are deleted.'
read -r -p 'Type CLEAN to unload and archive the listed files: ' answer
[[ "$answer" == CLEAN ]] || { echo 'Canceled. Nothing changed.'; exit 0; }
check_archive_parents || exit 1
/usr/bin/sudo -v || exit 1
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 700 "$archive_root" || exit 1
archive="$(/usr/bin/sudo /usr/bin/mktemp -d "$archive_root/$(/bin/date +%Y%m%d-%H%M%S)-XXXXXX")" || exit 1
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 700 "$archive/user-agents" "$archive/system-agents" "$archive/system-daemons" || exit 1
# Record the user so a later restore cannot move user agents into another account.
printf '%s\n' "$user_uid" | /usr/bin/sudo /usr/bin/tee "$archive/user-uid.txt" >/dev/null || exit 1
moved=0
failed=0
for i in "${selected[@]}"; do
  path="${original[$i]}"
  # Re-check after administrator authorization in case another process changed it.
  if [[ -L "$path" || ! -f "$path" ]] || vendor_present "$path"; then
    echo "SKIP (state changed): $path"; failed=1; continue
  fi
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$path" 2>/dev/null)"
  # Refuse unexpected service identities instead of unloading arbitrary labels.
  if [[ "$label.plist" != "$(/usr/bin/basename "$path")" ]]; then
    echo "SKIP (unexpected or unreadable service Label): $path"; failed=1; continue
  fi
  domain="gui/$user_uid"
  if [[ "${relative[$i]}" == system-daemons/* ]]; then
    domain=system
    if /usr/bin/sudo /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
      /usr/bin/sudo /bin/launchctl bootout "$domain" "$path" || true
      if /usr/bin/sudo /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
        echo "FAILED (still loaded, left in place): $path"; failed=1; continue
      fi
    fi
  else
    if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
      /bin/launchctl bootout "$domain" "$path" 2>/dev/null || /usr/bin/sudo /bin/launchctl bootout "$domain" "$path" || true
      if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
        echo "FAILED (still loaded, left in place): $path"; failed=1; continue
      fi
    fi
  fi
  if /usr/bin/sudo /bin/mv "$path" "$archive/${relative[$i]}"; then
    echo "ARCHIVED: $path"; moved=$((moved + 1))
  else
    echo "FAILED TO ARCHIVE: $path"; failed=1
  fi
done
backup_id="${archive##*/}"
echo
echo "Archived $moved file(s). Backup ID: $backup_id"
echo "Archive: $archive"
echo "To restore, run this same script with: --restore $backup_id"
echo 'Other logged-in users may retain loaded agents until they sign out.'
echo 'Restart the Mac, then run a fresh TuneUp scan to verify the startup entries are gone.'
[[ "$failed" -eq 0 ]] || echo 'Some entries were skipped or failed; review the messages above.'
if [[ "$mode" == --interactive ]]; then
  read -r -p 'Press Return to close…' unused
fi
exit "$failed"

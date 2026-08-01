#!/bin/bash

guardian_install_bundle_transaction() {
  if [[ "$#" -lt 5 || "$#" -gt 6 ]]; then
    /bin/echo "guardian_install_bundle_transaction: invalid arguments" >&2
    return 64
  fi
  local source_bundle="$1"
  local destination_bundle="$2"
  local backup_root="$3"
  local verify_function="$4"
  local activate_function="$5"
  local rollback_function="${6:-}"
  local destination_parent
  local destination_name
  destination_parent="$(/usr/bin/dirname "$destination_bundle")"
  destination_name="$(/usr/bin/basename "$destination_bundle")"

  if [[ ! -d "$source_bundle" || -L "$source_bundle" || -L "$destination_bundle" ||
        -L "$backup_root" || "$destination_bundle" != /* || "$destination_bundle" == "/" ]]; then
    /bin/echo "guardian_install_bundle_transaction: unsafe path" >&2
    return 65
  fi

  /bin/mkdir -p "$destination_parent" "$backup_root"
  /bin/chmod 700 "$backup_root"
  local stage_root
  stage_root="$(/usr/bin/mktemp -d "$destination_parent/.guardian-stage.XXXXXX")"
  local staged_bundle="$stage_root/$destination_name"
  local stamp
  stamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  local backup_bundle="$backup_root/$stamp.backup"
  local failed_bundle="$backup_root/$stamp.failed"
  local had_previous=0

  if ! /usr/bin/ditto "$source_bundle" "$staged_bundle"; then
    /bin/rm -rf "$stage_root"
    return 1
  fi
  if ! "$verify_function" "$staged_bundle"; then
    /bin/rm -rf "$stage_root"
    return 1
  fi

  if [[ -e "$destination_bundle" ]]; then
    had_previous=1
    if ! /bin/mv "$destination_bundle" "$backup_bundle"; then
      /bin/rm -rf "$stage_root"
      return 1
    fi
  fi
  if ! /bin/mv "$staged_bundle" "$destination_bundle"; then
    if [[ "$had_previous" -eq 1 ]]; then
      /bin/mv "$backup_bundle" "$destination_bundle" || true
    fi
    /bin/rm -rf "$stage_root"
    return 1
  fi
  /bin/rmdir "$stage_root" 2>/dev/null || true

  if ! "$activate_function" "$destination_bundle"; then
    /bin/mv "$destination_bundle" "$failed_bundle" || true
    if [[ "$had_previous" -eq 1 ]]; then
      /bin/mv "$backup_bundle" "$destination_bundle" || true
    fi
    if [[ -n "$rollback_function" ]]; then
      "$rollback_function" "$destination_bundle" || true
    fi
    return 1
  fi
}

guardian_archive_runtime_files() {
  if [[ "$#" -lt 2 ]]; then
    /bin/echo "guardian_archive_runtime_files: invalid arguments" >&2
    return 64
  fi
  local archive_root="$1"
  shift
  if [[ "$archive_root" != /* || "$archive_root" == "/" || -L "$archive_root" ]]; then
    /bin/echo "guardian_archive_runtime_files: unsafe archive path" >&2
    return 65
  fi
  local stamp
  stamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  local archive="$archive_root/$stamp"
  /bin/mkdir -p "$archive"
  /bin/chmod 700 "$archive_root" "$archive"
  local index=0
  local path
  for path in "$@"; do
    if [[ -z "$path" || "$path" == "/" ]]; then
      /bin/echo "guardian_archive_runtime_files: unsafe source path" >&2
      return 65
    fi
    if [[ -e "$path" || -L "$path" ]]; then
      index=$((index + 1))
      /bin/mv "$path" "$archive/$index-$(/usr/bin/basename "$path")"
    fi
  done
}

#!/usr/bin/env bash

guardian_require_credential() {
  local credential_path="$1"
  local temporary_path=""

  if [[ ! -e "$credential_path" && ! -L "$credential_path" ]]; then
    temporary_path="$(/usr/bin/mktemp "${credential_path}.tmp.XXXXXX")" || return 1
    chmod 600 "$temporary_path" || return 1
    if ! /usr/bin/openssl rand -out "$temporary_path" 32; then
      /bin/rm -f "$temporary_path"
      return 1
    fi
    if ! /bin/ln "$temporary_path" "$credential_path"; then
      /bin/rm -f "$temporary_path"
      return 1
    fi
    /bin/rm -f "$temporary_path"
  fi

  [[ ! -L "$credential_path" && -f "$credential_path" ]] || return 1
  [[ "$(/usr/bin/stat -f %u "$credential_path")" = "$(/usr/bin/id -u)" ]] || return 1
  [[ "$(/usr/bin/stat -f %z "$credential_path")" = 32 ]] || return 1
  local mode
  mode="$(/usr/bin/stat -f %Lp "$credential_path")" || return 1
  (( (8#$mode & 8#077) == 0 )) || return 1
}

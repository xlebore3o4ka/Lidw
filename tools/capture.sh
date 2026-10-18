#!/bin/bash
# tools/capture.sh — source from patch.sh to auto-copy a failure
# context bundle to the clipboard on non-zero exit. No-op on success.
#
# Usage (patch.sh header):
#   #!/bin/bash
#   set -e
#   set -o pipefail
#   source tools/capture.sh
#
# Environment:
#   CAPTURE_LINES            tail lines in the bundle (default 40)
#   CAPTURE_CTX              context lines around file:line (default 15)
#   LIDW_CAPTURE_FORCE_FILE  skip clipboard, write /tmp/lidw-last-fail.log
#
# On failure the bundle is written to: wl-copy, else xclip, else
# /tmp/lidw-last-fail.log. Bundle: exit code, tail of stdout+stderr,
# up to 3 context blocks around any `<path>.nim(<line>` in the log.

[ -n "${_LIDW_CAPTURE_LOADED:-}" ] && return 0
_LIDW_CAPTURE_LOADED=1

_capture_tmp=$(mktemp -t lidw-capture-XXXXXX.log)
_capture_ctx=${CAPTURE_CTX:-15}
_capture_lines=${CAPTURE_LINES:-40}

# Duplicate stdout/stderr to terminal (via 3,4) and tee into the log.
exec 3>&1 4>&2
exec > >(tee -a "$_capture_tmp" >&3) 2> >(tee -a "$_capture_tmp" >&4)

_capture_on_exit() {
  local rc=$?
  trap - EXIT
  local _prev="" _cur=0 _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    _cur=$(wc -c < "$_capture_tmp" 2>/dev/null || echo 0)
    [ "$_cur" = "$_prev" ] && break
    _prev="$_cur"
    sleep 0.05
  done
  if [ "$rc" -eq 0 ]; then
    local okout
    okout=$(printf '=== exit 0 ===\n'; cat "$_capture_tmp" 2>/dev/null)
    local nok
    nok=$(printf '%s\n' "$okout" | wc -l)
    if [ -z "${LIDW_CAPTURE_FORCE_FILE:-}" ] && command -v wl-copy >/dev/null 2>&1; then
      printf '%s\n' "$okout" | wl-copy
      printf '\n[capture: success output (%d lines) copied to clipboard]\n' "$nok" >&3
    elif [ -z "${LIDW_CAPTURE_FORCE_FILE:-}" ] && command -v xclip >/dev/null 2>&1; then
      printf '%s\n' "$okout" | xclip -selection clipboard
      printf '\n[capture: success output (%d lines) copied to clipboard]\n' "$nok" >&3
    fi
    rm -f "$_capture_tmp"
    return 0
  fi

  local out=""
  out+="=== exit $rc ==="$'\n'
  out+="--- last $_capture_lines lines (stdout+stderr) ---"$'\n'
  out+="$(tail -n "$_capture_lines" "$_capture_tmp" 2>/dev/null)"$'\n'
  local seen="" found=0 m file rest line start end
  while IFS= read -r m; do
    file="${m%%(*}"
    rest="${m#*(}"
    line="${rest%%[!0-9]*}"
    [ -z "$file" ] && continue
    [ -z "$line" ] && continue
    [ ! -f "$file" ] && continue
    echo "$seen" | grep -qF "$file:$line" && continue
    seen="$seen $file:$line"
    found=$((found + 1))
    [ "$found" -gt 3 ] && break
    start=$((line - _capture_ctx))
    [ "$start" -lt 1 ] && start=1
    end=$((line + _capture_ctx))
    out+=$'\n'"--- $file:$line (lines $start-$end) ---"$'\n'
    out+="$(sed -n "${start},${end}p" "$file" 2>/dev/null)"$'\n'
  done < <(grep -oE '[A-Za-z0-9_./-]+\.nim\([0-9]+' "$_capture_tmp" 2>/dev/null | sort -u)
  out+=$'\n'"=== end ==="$'\n'
  local nlines
  nlines=$(printf '%s' "$out" | wc -l)
  if [ -z "${LIDW_CAPTURE_FORCE_FILE:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$out" | wl-copy
    printf '\n[capture: failure context (%d lines) copied to clipboard]\n' "$nlines" >&3
  elif [ -z "${LIDW_CAPTURE_FORCE_FILE:-}" ] && command -v xclip >/dev/null 2>&1; then
    printf '%s' "$out" | xclip -selection clipboard
    printf '\n[capture: failure context (%d lines) copied to clipboard]\n' "$nlines" >&3
  else
    printf '%s' "$out" > /tmp/lidw-last-fail.log
    printf '\n[capture: failure context saved to /tmp/lidw-last-fail.log]\n' >&3
  fi
  rm -f "$_capture_tmp"
  return "$rc"
}
trap _capture_on_exit EXIT

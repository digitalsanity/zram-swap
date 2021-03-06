#!/bin/sh
# source: https://github.com/foundObjects/zram-swap

[ "$(id -u)" -eq '0' ] || { echo "This script requires root." && exit 1; }
case "$(readlink /proc/$$/exe)" in */bash) set -euo pipefail ;; *) set -eu ;; esac

# make sure our environment is predictable
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
\unalias -a

# parse debug flag early so we can trace user configuration
[ "$#" -gt "0" ] && [ "$1" = "-x" ] && shift && set -x
# make sure $1 exists for 'set -u' so we can get through 'case "$1"' below
{ [ "$#" -eq "0" ] && set -- ""; } > /dev/null 2>&1

# set sane defaults, see /etc/default/zram-swap for explanations
_zram_fraction="1/2"
_zram_algorithm="lz4"
_comp_factor=''
_zram_fixedsize=''

# load user config
[ -f /etc/default/zram-swap ] &&
  . /etc/default/zram-swap

# set expected compression ratio based on algorithm; this is a rough estimate
# skip if already set in user config
if [ -z "$_comp_factor" ]; then
  case $_zram_algorithm in
    lzo* | zstd) _comp_factor="3" ;;
    lz4) _comp_factor="2.5" ;;
    *) _comp_factor="2" ;;
  esac
fi

# main script:
_main() {
  if ! modprobe zram; then
    err "main: Failed to load zram module, exiting"
    return 1
  fi

  case "$1" in
    "init" | "start")
      if grep -q zram /proc/swaps; then
        err "main: zram swap already in use, exiting"
        return 1
      fi
      _init
      ;;
    "end" | "stop")
      if ! grep -q zram /proc/swaps; then
        err "main: no zram swaps to cleanup, exiting"
        return 1
      fi
      _end
      ;;
    *)
      _usage
      exit 1
      ;;
  esac
}

# initialize swap
_init() {
  if [ -n "$_zram_fixedsize" ]; then
    if ! _regex_match "$_zram_fixedsize" '^[[:digit:]]+(\.[[:digit:]]+)?(G|M)$'; then
      err "init: Invalid size '$_zram_fixedsize'. Format sizes like: 100M 250M 1.5G 2G etc."
      exit 1
    fi
    # Use user supplied zram size
    mem="$_zram_fixedsize"
  else
    # Calculate memory to use for zram
    totalmem=$(LC_ALL=C free | grep -e "^Mem:" | sed -e 's/^Mem: *//' -e 's/  *.*//')
    mem=$(calc "$totalmem * $_comp_factor * $_zram_fraction * 1024")
  fi

  # NOTE: init is a little janky; zramctl sometimes fails if we don't wait after module
  #       load so retry a couple of times with slightly increasing delay before giving up
  _device=''
  for i in $(seq 3); do
    sleep "$(calc 2 "0.1 * $i")"
    _device=$(zramctl -f -s "$mem" -a "$_zram_algorithm") || true
    [ -b "$_device" ] && break
  done

  if [ -b "$_device" ]; then
    # cleanup the device if swap setup fails
    trap "_rem_zdev $_device" EXIT
    mkswap "$_device"
    swapon -p 5 "$_device"
    trap - EXIT
    return 0
  else
    err "init: Failed to initialize zram device"
    return 1
  fi
}

# end swapping and cleanup
_end() {
  ret="0"
  DEVICES=$(awk '/zram/ {print $1}' /proc/swaps)
  for d in $DEVICES; do
    swapoff "$d"
    if ! _rem_zdev "$d"; then
      err "end: Failed to remove zram device $d"
      ret=1
    fi
  done
  return "$ret"
}

# Remove zram device with retry
_rem_zdev() {
  if [ ! -b "$1" ]; then
    err "rem_zdev: No zram device '$1' to remove"
    return 1
  fi
  for i in $(seq 3); do
    sleep "$(calc 2 "0.1 * $i")"  # calculate "0.1 * $i" rounded to 2 digits
    zramctl -r "$1" || true
    [ -b "$1" ] || break
  done
  if [ -b "$1" ]; then
    err "rem_zdev: Couldn't remove zram device '$1' after 3 attempts"
    return 1
  fi
  return 0
}

# calculate with variable precision
# usage: calc (int; precision := 0) (str; expr to evaluate)
calc() {
  case "$1" in [0-9]) n="$1" && shift ;; *) n=0 ;; esac
  awk "BEGIN{printf \"%.${n}f\", $*}"
}
#calc_i() { echo "r=$*;scale=0;r/1" | LC_ALL=C bc; }  # bc int calc
#calc_f() { echo "$*" | LC_ALL=C bc; }                # todo: float calc
#crapout() { echo "$@" >&2 && exit 1; }
err() { echo "Err $*" >&2; }
_usage() { echo "Usage: $(basename "$0") (init|end)"; }
# posix compliant replacement for [[ $foo =~ bar-pattern ]]
_regex_match() { echo "$1" | grep -Eq "$2" > /dev/null 2>&1; }

_main "$@"

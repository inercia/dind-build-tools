#!/usr/bin/env bash

# shellcheck disable=SC2068,SC2155,SC2145,SC2086,SC2129

common_sh_dir="$(cd "$(dirname ${BASH_SOURCE[0]})" >/dev/null 2>&1 && pwd)"
[ -d "$common_sh_dir" ] || {
	echo "FATAL: no current dir (maybe running in zsh?)"
	exit 1
}

########################################################################################################################
# utils
########################################################################################################################

RED='\033[1;31m'
GRN='\033[1;32m'
YEL='\033[1;33m'
BLU='\033[1;34m'
WHT='\033[1;37m'
MGT='\033[1;95m'
CYA='\033[1;96m'
END='\033[0m'
BLOCK='\033[1;47m'
BOLD='\033[1m' # or $(tput bold)

alias echo_on="{ set -x; }"
alias echo_off="{ set +x; } 2>/dev/null"

# command_exists <cmd>
#
# return true if the command provided exsists
#
command_exists() {
	[ -x "$1" ] || command -v $1 >/dev/null 2>/dev/null
}

log() { printf >&2 ">>> [DIND] $1\n"; }

hl() {
	local curr_cols=$(tput cols)
	local cols=${1:-$((curr_cols - 4))}
	printf '>>> %*s\n' "$cols" '' | tr ' ' '*'
}

info() { log "${BLU}$1${END}"; }
highlight() { log "${MGT}$1${END}"; }

failed() {
	if [ -z "$1" ]; then
		log "${RED}failed!!!${END}"
	else
		log "${RED}$1${END}"
	fi
	abort "test failed"
}

passed() {
	if [ -z "$1" ]; then
		log "${GRN}done!${END}"
	else
		log "${GRN}$1${END}"
	fi
}

bye() {
	log "${BLU}$1... exiting${END}"
	exit 0
}

warn() { log "${YEL}!!! Warning: $1 ${END}"; }

abort() {
	[ -n "$1" ] && log "${RED}FATAL: $1${END}"
	exit 1
}

# get a timestamp (in seconds)
timestamp() {
	date '+%s'
}

timeout_from() {
	local start=$1
	local now=$(timestamp)
	test $now -gt $((start + DEF_WAIT_TIMEOUT))
}

wait_until() {
	local start_time=$(timestamp)
	info "Waiting for $@"
	until timeout_from $start_time || eval "$@"; do
		info "... still waiting for condition"
		sleep 1
	done
	! timeout_from $start_time
}

# kill_background
#
# kill the background job
#
kill_background() {
	info "(Stopping background job)"
	kill $!
	wait $! 2>/dev/null
}

########################################################################################################################
# Images utils
#######################################################################################################################

image_id() {
	local image=$1
	shift || abort "${FUNCNAME[0]} usage error"

	docker inspect --format "{{.Id}}" "$image" 2>/dev/null
}

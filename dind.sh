#!/usr/bin/env bash
#shellcheck disable=2086

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -d "$this_dir" ] || {
	echo "FATAL: no current dir (maybe running in zsh?)"
	exit 1
}
COMMON_FILE=$this_dir/common.sh

source "$COMMON_FILE" || {
	echo "FATAL: $COMMON_FILE not found"
	exit 1
}

set -o pipefail

#################################################################################

TOP_DIR=${TOP_DIR:-$this_dir}

# when DIND_READY is set, we assume nothing has changed and the DinD
# container is ready to be used
DIND_READY=${DIND_READY:-}

# when DIND_RESTART is set, we force the restart of the DIND container
DIND_RESTART=${DIND_RESTART:-}

# when CONT_DELETE is set, the container should be deleted
CONT_DELETE=${CONT_DELETE:-}

# the Dockefile to use for the DinD
DOCKERFILE="${DOCKERFILE:-$TOP_DIR/Dockerfile.ci}"

# timeout for waits
WAIT_TIMEOUT=30

# at-exit handlers
ATEXIT=()

#################################################################################

# handler for exit functions
# exit functions are evaluated in reverse order to their registration
function _atexit_handler() {
	local EXPR
	for EXPR in "${ATEXIT[@]}"; do
		eval "$EXPR" || true
	done
}

trap _atexit_handler EXIT

function atexit() {
	local EXPR
	for EXPR in "$@"; do
		ATEXIT=("$EXPR" ${ATEXIT[*]})
	done
}

#################################################################################
# arguments processing
#################################################################################

CONFIG=

ARGS=()
while [[ $# -gt 0 ]]; do
	arg="$1"
	shift

	case $arg in
	--name | -name)
		CONT_NAME="$1"
		shift
		;;
	-C | --config | --cfg)
		CONFIG="$1"
		shift
		;;
	-D | --dockerfile)
		DOCKERFILE=$1
		shift
		;;
	--ready)
		DIND_READY=1
		;;
	--restart)
		DIND_RESTART=1
		;;
	-d | --destroy | --delete)
		CONT_DELETE=1
		;;
	*)
		ARGS+=("$arg")
		;;
	esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
	exit 0
fi

[ -n "$CONFIG" ] || abort "not config provided with --config"
[ -e "$CONFIG" ] || abort "'$CONFIG' not found."
info "Loading config from $CONFIG"
source "$CONFIG" || abort "could not load $CONFIG"

[ -n "$DOCKERFILE" ] || abort "no Dockerfile provided with --dockerfile."
[ -e $DOCKERFILE ] || abort "Dockerfile '$DOCKERFILE' not found."
info "Using Dockerfile $DOCKERFILE"

[ -n "$CONT_HOME" ] || abort "CONT_HOME not defined"

#################################################################################
# aux functions
#################################################################################

if [ -n "$DIND_RESTART" ]; then
	[ -n "$DIND_READY" ] && warn "(DIND_READY ignored: DIND_RESTART set)"
	DIND_READY=
fi

# create a valid container name (if not given one)
if [ -z "$CONT_NAME" ]; then
	CONT_NAME="$CONT_NAME_GEN_BASE"
	[ -n "$USER" ] && CONT_NAME="$CONT_NAME-$USER"
	[ -n "$BUILD_NUMBER" ] && CONT_NAME="$CONT_NAME-$BUILD_NUMBER"
	if [ -n "$WORKSPACE" ]; then
		ws=$(echo $WORKSPACE | sha1sum | head -c 10)
		CONT_NAME="$CONT_NAME-$ws"
	fi
fi

function cont_status() {
	local cont_name="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	docker container inspect -f '{{.State.Status}}' $cont_name 2>/dev/null
}

function cont_running() {
	local cont_name="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	local state="$(cont_status $cont_name)"
	[ -n "$VERBOSE" ] && info "(current state of DinD: '$state')"
	test "$state" = "running"
}

function cont_wait_running() {
	local cont_name="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	count=0
	while [ $count -lt $WAIT_TIMEOUT ] && ! cont_running "$cont_name"; do
		sleep 1
		info "... waiting"
		count=$((count + 1))
	done
	cont_running "$cont_name"
}

function cont_wait_not_running() {
	local cont_name="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	count=0
	while [ $count -lt $WAIT_TIMEOUT ] && cont_running "$cont_name"; do
		sleep 1
		info "... waiting"
		count=$((count + 1))
	done
	! cont_running "$cont_name"
}

function cont_stop() {
	local cont_name="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	if cont_running "$cont_name"; then
		timeout=$((CONT_DELAY - 1))
		info "Stopping container '$cont_name' (with timeout $timeout)..."
		docker stop --time $timeout "$cont_name" ||
			docker kill "$cont_name" ||
			warn "could not stop $cont_name"

		info "Waiting until '$cont_name' is stopped..."
		cont_wait_not_running "$cont_name" || abort "$cont_name is still running"
		docker rm "$cont_name" 2>/dev/null || info "$cont_name is not present"
		passed "... DinD '$cont_name' is stopped"
	fi
}

function cont_mounts() {
	local cont="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	docker inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$cont"
}

function cont_has_mount() {
	local cont=$1
	shift || abort "${FUNCNAME[0]} usage error"
	local mount=$1
	shift || abort "${FUNCNAME[0]} usage error"

	IFS=', ' read -r -a arr <<<"$(cont_mounts $cont)"
	[[ " ${arr[*]} " =~ " ${mount} " ]]
}

function cont_has_mounts() {
	local cont=$1
	shift || abort "${FUNCNAME[0]} usage error"
	local mounts=("$@")

	info "Checking $cont has the expected mounts..."
	[ -n "$DEBUG" ] && info "- (current mounts in DinD: ${mounts[*]})"
	for mount in "${mounts[@]}"; do
		cont_has_mount $cont $mount || {
			info "- '$mount' not found in existing DinD container: will need to restart it..."
			return 1
		}
	done
	passed "- same mounts found in the DinD container."
}

function file_hash() {
	md5sum $1 | cut -f1 -d' '
}

function file_different() {
	local file1=$1
	local file2=$2
	[ "$(file_hash $file1)" != "$(file_hash $file2)" ]
}

function docker_config_has_auth() {
	local docker_config="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	[ "null" != "$(jq '.auths["docker-hub-remote.dr-uw2.adobeitc.com"].auth' "${docker_config}")" ]
}

function copy_docker_config() {
	local docker_config="$1"
	shift || abort "${FUNCNAME[0]} usage error"
	local local_docker_config="$1"
	shift || abort "${FUNCNAME[0]} usage error"

	local local_docker_config_tmp="${local_docker_config}.tmp"

	if [ -f "$docker_config" ]; then
		CLEANUP+=("$local_docker_config")
		CLEANUP+=("$local_docker_config_tmp")

		info "Adding Docker authentication file for using inside DinD:"
		info " - $local_docker_config -> $CONT_HOME/.docker/config.json"

		docker_config_has_auth "$docker_config" || {
			warn "No registry credentials found in ${docker_config}, using the MacOS keychain?."
			warn "Maybe we will not be able to pull/push some images !!!"
			return
		}

		rm -f "$local_docker_config_tmp"
		echo "{ \"auths\" : $(cat $docker_config | jq .auths) }" | jq . >"$local_docker_config_tmp"

		if [ -f "$local_docker_config" ]; then
			if file_different "$local_docker_config" "$local_docker_config_tmp"; then
				info " - 'docker/config.json' config file has changed: overwriting..."
				cat "$local_docker_config_tmp" >"$local_docker_config" || abort "could not overwrite file"
			else
				info " - 'docker/config.json' seems to be the same: no update necessary."
			fi
		else
			info " - copying new '$local_docker_config' file"
			mv "$local_docker_config_tmp" "$local_docker_config" || abort "could not copy file"
		fi

		passed " - Docker configuration for DinD container:"
		cat "$local_docker_config" | jq . | sed -e 's/"auth".*/******/g'
	else
		warn "No Docker configuration found in $docker_config"
	fi
}

function maybe_cont_stop() {
	if [ -n "$CONT_DELETE" ] || [ -n "$DOCKER_DIND_DELETE" ]; then
		info "... stopping the DinD container: we are done."
		cont_stop "$CONT_NAME"
	else
		info "... not stopping the DinD container."
	fi
}
atexit maybe_cont_stop

function maybe_cleanup_files() {
	if [ -n "$CONT_DELETE" ] || [ -n "$DOCKER_DIND_DELETE" ]; then
		if [ ${#CLEANUP[@]} -ne 0 ]; then
			info "... cleaning up files: ${CLEANUP[*]}."
			rm -rf "${CLEANUP[*]}"
		fi
	fi
}
atexit maybe_cleanup_files

#################################################################################
# main
#################################################################################

dind_start_time=$(date +%s)

info "Starting DinD for running: ${ARGS[*]}"

info "- TOP_DIR: $TOP_DIR"
if [ -n "$CONT_TOP_DIR" ]; then
	info "- ... mounting in container: $TOP_DIR -> $CONT_TOP_DIR"
	CONT_MOUNTS+=("$TOP_DIR":"$CONT_TOP_DIR")
	CONT_ENV_VARS+=(TOP_DIR="$CONT_TOP_DIR")
fi

info "- Dockerfile: $DOCKERFILE"
info "- container name: $CONT_NAME"
if [ -n "$OUTPUT_DIR" ]; then
	info "- outputs will be left at: $OUTPUT_DIR"
fi

[ -n "$CONT_DELETE" ] && info " - will delete the container at the end."

DOCKER_EXEC_ARGS="-ti"
[ -n "$JENKINS_HOME" ] && {
	info "- running in Jenkins: non interactive terminal"
	DOCKER_EXEC_ARGS=""
}

[ -e "/.dockerenv" ] && abort "cannot run $0 in a container"

# set DOCKER_DEFAULT_PLATFORM depending on the OS
if [ -n "$DOCKER_DEFAULT_PLATFORM" ]; then
	info "- using default platform: $DOCKER_DEFAULT_PLATFORM"
else
	case "$(uname -s)" in
	Darwin)
		case "$(uname -m)" in
		arm64)
			info "- detected Darwin arm64: using default platform: linux/arm64"
			DOCKER_DEFAULT_PLATFORM="linux/arm64"
			;;
		*)
			info "- using default platform: linux/amd64"
			DOCKER_DEFAULT_PLATFORM="linux/amd64"
			;;
		esac
		;;
	*)
		info "- using default platform: linux/amd64"
		DOCKER_DEFAULT_PLATFORM="linux/amd64"
		;;
	esac
	export DOCKER_DEFAULT_PLATFORM
fi

# try to rebuild the image
# if there is a current container, check if the image has changed
prev_id=$(image_id $CONT_IMAGE_NAME)

if [ -z "$DIND_READY" ]; then
	if [ -n "${CACHE_REGISTRY:-}" ]; then
		info "- using cache registry: $CACHE_REGISTRY"
		DOCKER_BUILD_CACHE_ARGS="--build-arg BUILDKIT_INLINE_CACHE=1 --cache-from $CACHE_REGISTRY/$CONT_IMAGE_NAME"
	fi

	info "Rebuilding '$CONT_IMAGE_NAME' image from '$DOCKERFILE'"
	[ -n "$DEBUG" ] && set -x
	docker build -t "$CONT_IMAGE_NAME" \
		$DOCKER_BUILD_CACHE_ARGS \
		--build-arg CLUSTER_PROVIDER="$CLUSTER_PROVIDER" \
		-f "$DOCKERFILE" "$TOP_DIR" || abort "could not build image"
	[ -n "$DEBUG" ] && set +x
	new_id=$(image_id $CONT_IMAGE_NAME)

	if [ "$prev_id" != "$new_id" ]; then
		info "Image has changed from $prev_id to $new_id: stopping previous container"
		cont_stop "$CONT_NAME"
		sleep $CONT_DELAY
	else
		info "Image has not changed ($new_id)"
	fi

	if [ -n "${CACHE_REGISTRY:-}" ]; then
		# push to the build cache, but only if this is the first build or the build has changed
		if [ -z "$prev_id" ] || [ "$prev_id" != "$new_id" ]; then
			info "Pushing build cache to $CACHE_REGISTRY/$CONT_IMAGE_NAME"
			info "- previous image ID: $prev_id"
			info "- new image ID:      $new_id"
			docker tag "$CONT_IMAGE_NAME" "$CACHE_REGISTRY/$CONT_IMAGE_NAME" || abort "could not tag image as $CACHE_REGISTRY/$CONT_IMAGE_NAME"
			docker push "$CACHE_REGISTRY/$CONT_IMAGE_NAME" || abort "could not push image $CACHE_REGISTRY/$CONT_IMAGE_NAME"
		fi
	fi
fi

#
# mounts
#

if [ -n "$DIND_READY" ]; then
	info "(DIND_READY was set: assuming '$CONT_NAME' container is already running and current mounts are valid)"
else
	# We must "export" the docker credentials to the DinD container
	if [ -e "$DOCKER_CONFIG/config.json" ]; then
		local_docker_config="${DOCKER_CONFIG}/config-dind.json"

		copy_docker_config "$DOCKER_CONFIG/config.json" "$local_docker_config" || abort "coult not copy docker/config.json"
		CLEANUP+=("$local_docker_config")

		CONT_MOUNTS+=("$local_docker_config:$CONT_HOME/.docker/config.json")
		CONT_ENV_VARS+=("DOCKER_CONFIG=$CONT_HOME/.docker")
	fi
	if [ -e "${HOME}/.ssh" ]; then
		info "Adding .ssh config directory..."
		CONT_MOUNTS+=("${HOME}/.ssh:${CONT_HOME}/.ssh")
	fi
	if [ -e "${HOME}/.gitconfig" ]; then
		info "Adding Git config file..."
		CONT_MOUNTS+=("${HOME}/.gitconfig:${CONT_HOME}/.gitconfig")
	fi
	if [ -n "$KUBECONFIG" ]; then
		if [[ $KUBECONFIG == *":"* ]]; then
			info "Several kubeconfig files found: merging all these files..."
			kubeconfig_tmp_file=$(mktemp)
			kubectl config view --flatten >"$kubeconfig_tmp_file" || abort "could not merge kubeconfig files"
			[ -f "$kubeconfig_tmp_file" ] || abort "$kubeconfig_tmp_file does not exist"
			CONT_MOUNTS+=("${kubeconfig_tmp_file}:${CONT_HOME}/.kube/config")
			CLEANUP+=("$kubeconfig_tmp_file")
		else
			[ -f "$KUBECONFIG" ] || abort "$KUBECONFIG does not exist"
			CONT_MOUNTS+=("$KUBECONFIG:$CONT_HOME/.kube/config")
		fi
		CONT_ENV_VARS+=(KUBECONFIG="$CONT_HOME/.kube/config")
	fi
fi

#
# maybe start/restart the container
#

if [ -n "$DIND_READY" ]; then
	info "(DIND_READY was set: assuming '$CONT_NAME' container is already running: reusing it)"
else
	if cont_running "$CONT_NAME"; then
		if [ -n "$DIND_RESTART" ] || ! cont_has_mounts "$CONT_NAME" "${CONT_MOUNTS[@]}"; then
			info "Mounts have changed: stopping previous container"
			cont_stop "$CONT_NAME"
			sleep $CONT_DELAY
		fi
	fi

	if cont_running "$CONT_NAME"; then
		info "('$CONT_NAME' container already running: reusing it)"
	else
		info "Starting DinD '$CONT_NAME' with image '$CONT_IMAGE_NAME'"

		CONT_MOUNTS_ARGS=()
		for v in "${CONT_MOUNTS[@]}"; do
			info "- mounting '$v'"
			e=$(echo "$v" | cut -d":" -f1)
			d=$(echo "$v" | cut -d":" -f2)
			if [ ! -e "$e" ]; then
				warn "'$e' does not exist: creating as directory..."
				mkdir -p "$e"
			fi
			if [[ $d == /tmp/* ]]; then
				warn "mounting in /tmp: it can not be shown in the container"
			fi
			CONT_MOUNTS_ARGS+=("-v $v")
		done

		DOCKER_RUN_ENV_VARS_ARGS=()
		for v in "${CONT_ENV_VARS[@]}"; do
			info "- passing env. var. (as default): $v"
			DOCKER_RUN_ENV_VARS_ARGS+=("-e $v")
		done

		[ -n "$DEBUG" ] && set -x
		docker run \
			--rm \
			--privileged -d \
			--name "$CONT_NAME" \
			-v "$TOP_DIR":$CONT_TOP_DIR \
			${CONT_MOUNTS_ARGS[*]} \
			${DOCKER_RUN_ENV_VARS_ARGS[*]} \
			${DOCKER_RUN_EXTRA_ARGS[*]} \
			"$CONT_IMAGE_NAME"
		rc=$?
		[ -n "$DEBUG" ] && set +x
		[ $rc -eq 0 ] || warn "waybe the DinD container is not running"

		info "Waiting until $CONT_NAME is running..."
		cont_wait_running "$CONT_NAME" || {
			info "container status: $(cont_status $CONT_NAME)"
			abort "could not start $CONT_NAME"
		}
		passed "... DinD container '$CONT_NAME' is running (in the background)"

		# give some time docker to start...
		sleep $CONT_DELAY
	fi

fi

hl
info "Running '${ARGS[*]}' in the '$CONT_NAME' container"

DOCKER_EXEC_ENV_VARS_ARGS=()
for v in "${CONT_ENV_VARS[@]}"; do
	info "- passing env. var (overridding): $v"
	DOCKER_EXEC_ENV_VARS_ARGS+=("-e $v")
done

maybe_fix_owner() {
	if [ -n "$CONT_DELETE" ] || [ -n "$DOCKER_DIND_DELETE" ]; then
		if [ -n "${CHOWN_UID:-}" ] && [ ${#CHOWN_DIRS[@]} -ne 0 ]; then
			info "... ensuring owner for ${CHOWN_DIRS[*]} (in DinD container) is ${CHOWN_UID}"
			docker exec \
				${DOCKER_EXEC_ENV_VARS_ARGS[*]} \
				${DOCKER_EXEC_EXTRA_ARGS[*]} \
				${DOCKER_EXEC_ARGS[*]} \
				"$CONT_NAME" \
				chown -R "$CHOWN_UID" ${CHOWN_DIRS[*]} || warn "chown failed (ignored)"
		fi
	fi
}
atexit maybe_fix_owner

start_time=$(date +%s)
print_time() {
	end_time=$(date +%s)
	dind_end_time=$end_time

	diff_secs=$((end_time - start_time))
	dind_diff_secs=$((dind_end_time - dind_start_time))
	passed "... command run in $diff_secs secs ($dind_diff_secs secs in total)."
}
atexit print_time

[ -n "$DEBUG" ] && set -x
docker exec \
	${DOCKER_EXEC_ENV_VARS_ARGS[*]} \
	${DOCKER_EXEC_EXTRA_ARGS[*]} \
	${DOCKER_EXEC_ARGS[*]} \
	"$CONT_NAME" ${ARGS[*]}
rc=$?
[ -n "$DEBUG" ] && set +x
[ $rc -eq 0 ] || abort "'${ARGS[*]}' failed (with 'docker exec' in DinD)"

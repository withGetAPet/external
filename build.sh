#!/bin/bash

set -eo pipefail

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

jobs=$(nproc)
verbose='false'
build_lib='all'
clean='false'
out_dir="$SCRIPTPATH/out"

print_usage() {
	printf "Usage: ./build.sh [options...]\n"
	printf "Options:\n"
	printf "  -v, --verbose    Verbose output\n"
	printf "  --clean          Clean build directory\n"
	printf "  -j, --jobs       Number of jobs to run simultaneously (default $jobs)\n"
	printf "  -b, --build      [all|protobuf] Build specific library (default: $build)\n"
	printf "  --prefix         Out Prefix (default: $out_dir)\n"
	printf "  -h, --help       Show this help message\n"
}

build_target() {
	local target=$(echo "$1" | tr '[:upper:]' '[:lower:]')

	if [[ $build_lib =~ "$target" ]]; then
		return 0
	fi

	return 1
}

function parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-v | --verbose)
			verbose='true'
			shift # Remove argument name from processing
			;;
		-j | --jobs)
			jobs=$2
			shift # Remove argument name
			shift # Remove argument value
			;;
		-b | --build)
			build_lib=$2
			shift # Remove argument name
			shift # Remove argument value
			;;
		-h | --help)
			print_usage
			exit 0
			;;
		--clean)
			clean='true'
			shift # Remove argument name
			;;
		--prefix)
			out_dir=$2
			shift # Remove argument name
			shift # Remove argument value
			;;
		*)
			echo "Unknown option: $1"
			print_usage
			exit 1
			;;
		esac
	done
}

function init() {
	parse_args "$@"

	OLD_ENV="$(env)"
	pushd "$SCRIPTPATH" >/dev/null

	if [ ! -z "$TERM" ] && tty -s; then
		tput civis
	fi

	function cleanup() {
		if [ ! -z "$TERM" ] && tty -s; then
			tput cnorm
		fi
		popd >/dev/null

		for line in $(env); do
			if [[ $line == *=* ]]; then
				unset $line
			fi
		done

		for line in $OLD_ENV; do
			if [[ $line == *=* ]]; then
				export $line
			fi
		done
	}

	trap cleanup EXIT

	out_dir=$(realpath "$out_dir")

	mkdir -p $out_dir
	mkdir -p "$SCRIPTPATH/build"

	if [ "$verbose" = 'true' ]; then
		set -x
	fi

	if build_target "all"; then
		build_lib="$build_lib protobuf"
	fi
}

function settings() {
	echo "CC=$CC CXX=$CXX LD=$LD INSTALL_DIR=$out_dir"
}

function check_tool() {
	local name=$1

	printf "Checking $name "
	path=$(which $name || true) || ""

	if [ -z "$path" ]; then
		echo "[NOT FOUND]"
		echo "$name could not be found, please install $name"
		exit 1
	fi

	echo "[FOUND] ($path)"
}

function spinner() {
	local name=$1
	local pid=$2

	local spinstr='|/-\'
	while ps -p $pid >/dev/null; do
		local temp=${spinstr#?}
		printf "[%c]  " "$spinstr"
		local spinstr=$temp${spinstr%"$temp"}
		sleep 0.75
		printf "\b\b\b\b\b"
	done
	printf "    \b\b\b\b"

	wait $pid || {
		echo "[FAILED]"
		echo "tail of build log:"
		local log=$SCRIPTPATH/build/$name/build.log
		tail -n 100 $log
		echo ""
		echo "Failed to build $name, see $log for more details"
		exit 1
	}

	echo "[DONE]"
}

function builder() {
	local name=$1
	local check_file=$2
	local build_inner=$3

	if [ ! -f "$SCRIPTPATH/$name/$check_file" ]; then
		echo "Failed to find $name source code, please run git submodule update --init --recursive"
		exit 1
	fi

	printf "Building $name "

	if [ "$(build_target $name && echo "1" || echo "0")" == '0' ]; then
		echo "[SKIPPED]"
		return
	fi

	local build_done=$SCRIPTPATH/build/$name/build-done

	local do_build='true'

	local build_done_content=$(cat $build_done 2>/dev/null) || ""

	local settings_value="$(settings)"

	if [ "$build_done_content" = "$settings_value" ]; then
		do_build='false'
	fi

	if [ "$clean" = 'true' ] || [ "$do_build" = 'true' ]; then
		rm -rf "$SCRIPTPATH/build/$name"
		do_build='true'
	fi

	if [ "$do_build" = 'false' ]; then
		echo "[CACHED]"
		return
	fi

	mkdir -p $SCRIPTPATH/build/$name
	cd $SCRIPTPATH/build/$name

	function inner() {
		set -exo pipefail

		SOURCEPATH=$SCRIPTPATH/$1
		OUTPATH=$out_dir
		DOBUILD=$do_build
		$build_inner

		echo $settings_value >$build_done
	}

	inner $name >$SCRIPTPATH/build/$name/build.log 2>&1 &
	spinner $name $!
}

function build_protobuf() {
	cmake \
		-GNinja \
		-Dprotobuf_BUILD_TESTS=OFF \
		-DCMAKE_BUILD_TYPE=Release \
		-DABSL_PROPAGATE_CXX_STD=ON \
		-DCMAKE_INSTALL_PREFIX=$OUTPATH \
		$SOURCEPATH

	cmake --build . --config Release -j $jobs

	cmake --install . --config Release
}

init "$@"

check_tool ninja
check_tool cmake
check_tool make
check_tool nasm

echo "Settings:"
echo "  Build: $build_lib"
echo "  Clean: $clean"
echo "  Prefix: $out_dir"
echo "  CC: $CC"
echo "  CXX: $CXX"
echo "  LD: $LD"
echo "  Jobs: $jobs"
echo ""

builder "protobuf" "CMakeLists.txt" build_protobuf

echo "Done!"
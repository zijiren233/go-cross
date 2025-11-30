#!/bin/bash
set -e

# =============================================================================
# Go Cross-Compilation Build Script
# =============================================================================
# This script provides cross-compilation support for Go projects across
# multiple platforms including Linux, Windows, macOS, FreeBSD, iOS, and Android.
# =============================================================================

# -----------------------------------------------------------------------------
# Color Definitions
# -----------------------------------------------------------------------------
readonly COLOR_LIGHT_RED='\033[1;31m'
readonly COLOR_LIGHT_GREEN='\033[1;32m'
readonly COLOR_LIGHT_YELLOW='\033[1;33m'
readonly COLOR_LIGHT_BLUE='\033[1;34m'
readonly COLOR_LIGHT_MAGENTA='\033[1;35m'
readonly COLOR_LIGHT_CYAN='\033[1;36m'
readonly COLOR_LIGHT_GRAY='\033[0;37m'
readonly COLOR_DARK_GRAY='\033[1;30m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_LIGHT_ORANGE='\033[1;91m'
readonly COLOR_RESET='\033[0m'

# -----------------------------------------------------------------------------
# Default Configuration
# -----------------------------------------------------------------------------
readonly DEFAULT_SOURCE_DIR="$(pwd)"
readonly DEFAULT_RESULT_DIR="${DEFAULT_SOURCE_DIR}/build"
readonly DEFAULT_BUILD_CONFIG="${DEFAULT_SOURCE_DIR}/build.config.sh"
readonly DEFAULT_BUILDMODE="default"
readonly DEFAULT_CROSS_COMPILER_DIR="$(dirname $(mktemp -u))/go-cross-compiler"
readonly DEFAULT_CGO_FLAGS="-O2 -g0 -pipe"
readonly DEFAULT_CGO_LDFLAGS="-s"
readonly DEFAULT_LDFLAGS="-s -w -linkmode auto"
readonly DEFAULT_EXT_LDFLAGS=""
readonly DEFAULT_CGO_DEPS_VERSION="v0.6.7"
readonly DEFAULT_TTY_WIDTH="40"
readonly DEFAULT_NDK_VERSION="r27"
readonly DEFAULT_COMMAND="build"
readonly SUPPORTED_COMMANDS="build|run|test|bench"
readonly DEFAULT_PACKAGE="."

# -----------------------------------------------------------------------------
# Host Environment Detection
# -----------------------------------------------------------------------------
readonly GOHOSTOS="$(go env GOHOSTOS)"
readonly GOHOSTARCH="$(go env GOHOSTARCH)"
readonly GOHOSTPLATFORM="${GOHOSTOS}/${GOHOSTARCH}"
readonly GOVERSION="$(go env GOVERSION | sed 's/^go//')" # e.g 1.23.1
readonly GODISTLIST="$(go tool dist list)"
readonly DEFAULT_CC="$(go env CC)"
readonly DEFAULT_CXX="$(go env CXX)"

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

# Sets a variable to a default value if it's not already set
set_default() {
	local var_name="$1"
	local default_value="$2"
	[[ -z "${!var_name}" ]] && eval "${var_name}=\"${default_value}\"" || true
}

# Gets a separator line based on the terminal width
print_separator() {
	local width=$(tput cols 2>/dev/null || echo $DEFAULT_TTY_WIDTH)
	printf '%*s\n' "$width" '' | tr ' ' -
}

# Log functions for consistent output
log_info() {
	echo -e "${COLOR_LIGHT_BLUE}$*${COLOR_RESET}"
}

log_success() {
	echo -e "${COLOR_LIGHT_GREEN}$*${COLOR_RESET}"
}

log_warning() {
	echo -e "${COLOR_LIGHT_YELLOW}$*${COLOR_RESET}"
}

log_error() {
	echo -e "${COLOR_LIGHT_RED}$*${COLOR_RESET}" >&2
}

# Maps Go host architecture to GCC tuple architecture
# Arguments:
#   $1: Go architecture (GOHOSTARCH or GOARCH)
# Returns:
#   GCC tuple architecture (e.g., x86_64, aarch64)
map_go_arch_to_gcc() {
	case "$1" in
	"amd64") echo "x86_64" ;;
	"arm64") echo "aarch64" ;;
	"arm") echo "armv7" ;;
	*) echo "$1" ;;
	esac
}

# Parse single-value option argument
parse_option_value() {
	local option_name="$1"
	shift
	if [[ $# -gt 0 ]]; then
		echo "$1"
	else
		log_error "Error: $option_name requires a value"
		exit 1
	fi
}

# Check if the next argument is an option (starts with -)
is_next_arg_option() {
	if [[ $# -le 1 ]]; then
		return 1
	fi

	local next_arg="$2"
	[[ "$next_arg" =~ ^- ]]
}

# -----------------------------------------------------------------------------
# Help and Information
# -----------------------------------------------------------------------------

# Prints help information about build configuration
print_build_config_help() {
	echo -e "${COLOR_LIGHT_ORANGE}You can customize the build configuration using the following functions (defined in ${DEFAULT_BUILD_CONFIG}):${COLOR_RESET}"
	echo -e "  ${COLOR_LIGHT_GREEN}init_dep${COLOR_RESET}            - Initialize dependencies"
	echo -e "  ${COLOR_LIGHT_GREEN}init_dep_targets${COLOR_RESET}    - Initialize dependency targets"
	echo -e "  ${COLOR_LIGHT_GREEN}parse_dep_args${COLOR_RESET}      - Parse dependency arguments"
	echo -e "  ${COLOR_LIGHT_GREEN}print_dep_env_help${COLOR_RESET}  - Print dependency environment variable help"
	echo -e "  ${COLOR_LIGHT_GREEN}print_dep_help${COLOR_RESET}      - Print dependency help information"
}

# Prints help information about environment variables
print_env_help() {
	echo -e "${COLOR_LIGHT_YELLOW}Environment Variables:${COLOR_RESET}"
	echo -e "  ${COLOR_LIGHT_CYAN}BIN_NAME${COLOR_RESET}           - Set the binary name (default: source directory basename)"
	echo -e "  ${COLOR_LIGHT_CYAN}BIN_NAME_NO_SUFFIX${COLOR_RESET} - Do not append the architecture suffix to the binary name"
	echo -e "  ${COLOR_LIGHT_CYAN}BUILD_CONFIG${COLOR_RESET}       - Set the build configuration file (default: ${DEFAULT_BUILD_CONFIG})"
	echo -e "  ${COLOR_LIGHT_CYAN}BUILDMODE${COLOR_RESET}          - Set the build mode (default: ${DEFAULT_BUILDMODE})"
	echo -e "  ${COLOR_LIGHT_CYAN}CGO_ENABLED${COLOR_RESET}        - Enable or disable CGO (default: disabled)"
	echo -e "  ${COLOR_LIGHT_CYAN}CGO_FLAGS${COLOR_RESET}          - Set CGO flags (default: ${DEFAULT_CGO_FLAGS})"
	echo -e "  ${COLOR_LIGHT_CYAN}CGO_LDFLAGS${COLOR_RESET}        - Set CGO linker flags (default: ${DEFAULT_CGO_LDFLAGS})"
	echo -e "  ${COLOR_LIGHT_CYAN}CROSS_COMPILER_DIR${COLOR_RESET} - Set the cross compiler directory (default: ${DEFAULT_CROSS_COMPILER_DIR})"
	echo -e "  ${COLOR_LIGHT_CYAN}ENABLE_MICRO${COLOR_RESET}       - Enable building micro variants"
	echo -e "  ${COLOR_LIGHT_CYAN}GH_PROXY${COLOR_RESET}           - Set the GitHub proxy mirror (e.g., https://mirror.ghproxy.com/)"
	echo -e "  ${COLOR_LIGHT_CYAN}CC${COLOR_RESET}                 - Force set the use of a specific C compiler"
	echo -e "  ${COLOR_LIGHT_CYAN}CXX${COLOR_RESET}                - Force set the use of a specific C++ compiler"
	echo -e "  ${COLOR_LIGHT_CYAN}NDK_VERSION${COLOR_RESET}        - Set the Android NDK version (default: ${DEFAULT_NDK_VERSION})"
	echo -e "  ${COLOR_LIGHT_CYAN}PLATFORM${COLOR_RESET}           - Set the target target(s) (default: host target, supports: all, linux, linux/arm*, ...)"
	echo -e "  ${COLOR_LIGHT_CYAN}RESULT_DIR${COLOR_RESET}         - Set the build result directory (default: ${DEFAULT_RESULT_DIR})"
	echo -e "  ${COLOR_LIGHT_CYAN}SOURCE_DIR${COLOR_RESET}         - Set the source directory (default: ${DEFAULT_SOURCE_DIR})"
	echo -e "  ${COLOR_LIGHT_CYAN}USE_GNU_LIBC${COLOR_RESET}       - Use GNU libc instead of musl for Linux targets"

	if declare -f print_dep_env_help >/dev/null; then
		echo -e "${COLOR_LIGHT_GRAY}$(print_separator)${COLOR_RESET}"
		echo -e "${COLOR_LIGHT_ORANGE}Dependency Environment Variables:${COLOR_RESET}"
		print_dep_env_help
	fi
}

# Prints help information about command-line arguments
print_help() {
	echo -e "${COLOR_LIGHT_GREEN}Usage:${COLOR_RESET} ${COLOR_LIGHT_CYAN}[command] [options] [packages]${COLOR_RESET}"
	echo -e ""
	echo -e "${COLOR_LIGHT_GREEN}Commands:${COLOR_RESET}"
	echo -e "  ${COLOR_LIGHT_CYAN}build${COLOR_RESET}       Build the project (default)"
	echo -e "  ${COLOR_LIGHT_CYAN}run${COLOR_RESET}         Compile and run the project"
	echo -e "  ${COLOR_LIGHT_CYAN}test${COLOR_RESET}        Run tests"
	echo -e "  ${COLOR_LIGHT_CYAN}bench${COLOR_RESET}       Run benchmarks"
	echo -e ""
	echo -e "${COLOR_LIGHT_RED}Options:${COLOR_RESET}"
	echo -e "${COLOR_LIGHT_YELLOW}Standard Go Build Flags:${COLOR_RESET}"
	echo -e "  ${COLOR_LIGHT_BLUE}-C <dir>${COLOR_RESET}                          - Change to dir before running the command"
	echo -e "  ${COLOR_LIGHT_BLUE}-a${COLOR_RESET}                                - Force rebuilding of packages that are already up-to-date"
	echo -e "  ${COLOR_LIGHT_BLUE}-n${COLOR_RESET}                                - Print the commands but do not run them"
	echo -e "  ${COLOR_LIGHT_BLUE}-p <n>${COLOR_RESET}                            - Number of programs that can be run in parallel"
	echo -e "  ${COLOR_LIGHT_BLUE}-race${COLOR_RESET}                             - Enable data race detection"
	echo -e "  ${COLOR_LIGHT_BLUE}-msan${COLOR_RESET}                             - Enable interoperation with memory sanitizer"
	echo -e "  ${COLOR_LIGHT_BLUE}-asan${COLOR_RESET}                             - Enable interoperation with address sanitizer"
	echo -e "  ${COLOR_LIGHT_BLUE}-cover${COLOR_RESET}                            - Enable code coverage instrumentation"
	echo -e "  ${COLOR_LIGHT_BLUE}-covermode <mode>${COLOR_RESET}                 - Set the mode for coverage analysis (set,count,atomic)"
	echo -e "  ${COLOR_LIGHT_BLUE}-coverpkg <pattern>${COLOR_RESET}               - Apply coverage analysis to packages matching pattern"
	echo -e "  ${COLOR_LIGHT_BLUE}-v${COLOR_RESET}                                - Print the names of packages as they are compiled"
	echo -e "  ${COLOR_LIGHT_BLUE}-work${COLOR_RESET}                             - Print the name of the temporary work directory and do not delete it when exiting"
	echo -e "  ${COLOR_LIGHT_BLUE}-x${COLOR_RESET}                                - Print the commands"
	echo -e "  ${COLOR_LIGHT_BLUE}-asmflags <flags>${COLOR_RESET}                 - Arguments to pass on each go tool asm invocation"
	echo -e "  ${COLOR_LIGHT_BLUE}-buildmode <mode>${COLOR_RESET}                 - Build mode to use (default: ${DEFAULT_BUILDMODE})"
	echo -e "  ${COLOR_LIGHT_BLUE}-buildvcs <bool>${COLOR_RESET}                  - Whether to stamp binaries with version control information"
	echo -e "  ${COLOR_LIGHT_BLUE}-compiler <name>${COLOR_RESET}                  - Name of compiler to use (gccgo or gc)"
	echo -e "  ${COLOR_LIGHT_BLUE}-gccgoflags <flags>${COLOR_RESET}               - Arguments to pass on each gccgo compiler/linker invocation"
	echo -e "  ${COLOR_LIGHT_BLUE}-gcflags <flags>${COLOR_RESET}                  - Arguments to pass on each go tool compile invocation"
	echo -e "  ${COLOR_LIGHT_BLUE}-installsuffix <suffix>${COLOR_RESET}           - A suffix to use in the name of the package installation directory"
	echo -e "  ${COLOR_LIGHT_BLUE}-json${COLOR_RESET}                             - Emit build output in JSON format"
	echo -e "  ${COLOR_LIGHT_BLUE}-ldflags <flags>${COLOR_RESET}                  - Arguments to pass on each go tool link invocation (default: \"${DEFAULT_LDFLAGS}\")"
	echo -e "  ${COLOR_LIGHT_BLUE}-linkshared${COLOR_RESET}                       - Build code that will be linked against shared libraries"
	echo -e "  ${COLOR_LIGHT_BLUE}-mod <mode>${COLOR_RESET}                       - Module download mode (readonly, vendor, or mod)"
	echo -e "  ${COLOR_LIGHT_BLUE}-modcacherw${COLOR_RESET}                       - Leave newly-created directories in the module cache read-write"
	echo -e "  ${COLOR_LIGHT_BLUE}-modfile <file>${COLOR_RESET}                   - Read an alternate go.mod file"
	echo -e "  ${COLOR_LIGHT_BLUE}-overlay <file>${COLOR_RESET}                   - Read a JSON config file that provides an overlay for build operations"
	echo -e "  ${COLOR_LIGHT_BLUE}-pgo <file>${COLOR_RESET}                       - Specify the file path of a profile for profile-guided optimization"
	echo -e "  ${COLOR_LIGHT_BLUE}-pkgdir <dir>${COLOR_RESET}                     - Install and load all packages from dir"
	echo -e "  ${COLOR_LIGHT_BLUE}-tags <tags>${COLOR_RESET}                      - A comma-separated list of build tags"
	echo -e "  ${COLOR_LIGHT_BLUE}-trimpath${COLOR_RESET}                         - Remove all file system paths from the resulting executable"
	echo -e "  ${COLOR_LIGHT_BLUE}-toolexec <cmd>${COLOR_RESET}                   - A program to use to invoke toolchain programs"
	echo -e ""
	echo -e "${COLOR_LIGHT_YELLOW}Cross-Compilation Specific Options:${COLOR_RESET}"
	echo -e "  ${COLOR_LIGHT_BLUE}-bin-name <name>${COLOR_RESET}                  - Specify the binary name (default: source directory basename)"
	echo -e "  ${COLOR_LIGHT_BLUE}-bin-name-no-suffix${COLOR_RESET}              - Do not append the architecture suffix to the binary name"
	echo -e "  ${COLOR_LIGHT_BLUE}-cross-compiler-dir <dir>${COLOR_RESET}        - Specify the cross compiler directory (default: ${DEFAULT_CROSS_COMPILER_DIR})"
	echo -e "  ${COLOR_LIGHT_BLUE}-cgo-enabled${COLOR_RESET}                     - Enable CGO (default: disabled)"
	echo -e "  ${COLOR_LIGHT_BLUE}-use-gnu-libc${COLOR_RESET}                    - Use GNU libc instead of musl for Linux targets"
	echo -e "  ${COLOR_LIGHT_BLUE}-enable-micro${COLOR_RESET}                    - Enable building micro architecture variants"
	echo -e "  ${COLOR_LIGHT_BLUE}-ext-ldflags <flags>${COLOR_RESET}             - Set external linker flags (default: \"${DEFAULT_EXT_LDFLAGS}\")"
	echo -e "  ${COLOR_LIGHT_BLUE}-cc <path>${COLOR_RESET}                       - Force set the use of a specific C compiler"
	echo -e "  ${COLOR_LIGHT_BLUE}-cxx <path>${COLOR_RESET}                      - Force set the use of a specific C++ compiler"
	echo -e "  ${COLOR_LIGHT_BLUE}-use-default-cc-cxx${COLOR_RESET}              - Use the default C and C++ compilers (${DEFAULT_CC} and ${DEFAULT_CXX})"
	echo -e "  ${COLOR_LIGHT_BLUE}-github-proxy-mirror <url>${COLOR_RESET}       - Use a GitHub proxy mirror (e.g., https://mirror.ghproxy.com/)"
	echo -e "  ${COLOR_LIGHT_BLUE}-ndk-version <version>${COLOR_RESET}           - Specify the Android NDK version (default: ${DEFAULT_NDK_VERSION})"
	echo -e "  ${COLOR_LIGHT_BLUE}-t <targets>${COLOR_RESET}                     - Specify target platform(s) (default: host platform, supports: all, linux, linux/arm*, ...)"
	echo -e "  ${COLOR_LIGHT_BLUE}-result-dir <dir>${COLOR_RESET}                - Specify the build result directory (default: ${DEFAULT_RESULT_DIR})"
	echo -e "  ${COLOR_LIGHT_BLUE}-show-all-targets${COLOR_RESET}                - Display all supported target platforms"
	echo -e ""
	echo -e "${COLOR_LIGHT_YELLOW}Other Options:${COLOR_RESET}"
	echo -e "  ${COLOR_LIGHT_BLUE}-h${COLOR_RESET}                                - Display this help message"
	echo -e "  ${COLOR_LIGHT_BLUE}-eh${COLOR_RESET}                               - Display help information about environment variables"

	if declare -f print_dep_help >/dev/null; then
		echo -e "${COLOR_LIGHT_MAGENTA}$(print_separator)${COLOR_RESET}"
		echo -e "${COLOR_LIGHT_MAGENTA}Dependency Options:${COLOR_RESET}"
		print_dep_help
	fi

	echo -e "${COLOR_DARK_GRAY}$(print_separator)${COLOR_RESET}"
	print_build_config_help
}

# -----------------------------------------------------------------------------
# Build Configuration Functions
# -----------------------------------------------------------------------------

# Appends tags to the TAGS variable
add_tags() {
	# Convert space-separated tags to comma-separated, remove quotes and newlines
	BUILD_TAGS="$(echo "$BUILD_TAGS $@" | sed 's/"//g' | sed 's/\n//g' | tr -s ' ' ',' | sed 's/^,//g' | sed 's/,,*/,/g')"
}

# Appends linker flags to the LDFLAGS variable
add_ldflags() {
	[[ -n "${1}" ]] && LDFLAGS="${LDFLAGS} ${1}" || true
}

# Appends external linker flags to the EXT_LDFLAGS variable
add_ext_ldflags() {
	[[ -n "${1}" ]] && EXT_LDFLAGS="${EXT_LDFLAGS} ${1}" || true
}

# Appends build arguments to the BUILD_ARGS variable
add_build_args() {
	[[ -n "${1}" ]] && BUILD_ARGS="${BUILD_ARGS} ${1}" || true
}

# Fixes and validates command-line arguments and sets default values
fix_args() {
	set_default "RESULT_DIR" "${SOURCE_DIR}/build"
	log_info "Result directory: ${COLOR_LIGHT_GREEN}${RESULT_DIR}${COLOR_RESET}"

	set_default "BIN_NAME" "$(basename "${SOURCE_DIR}")"
	log_info "Binary name: ${COLOR_LIGHT_GREEN}${BIN_NAME}${COLOR_RESET}"

	set_default "CROSS_COMPILER_DIR" "$DEFAULT_CROSS_COMPILER_DIR"
	set_default "PLATFORMS" "${GOHOSTPLATFORM}"
	set_default "BUILDMODE" "${DEFAULT_BUILDMODE}"
	set_default "LDFLAGS" "${DEFAULT_LDFLAGS}"
	set_default "EXT_LDFLAGS" "${DEFAULT_EXT_LDFLAGS}"
	set_default "CGO_DEPS_VERSION" "${DEFAULT_CGO_DEPS_VERSION}"
	set_default "CGO_FLAGS" "${DEFAULT_CGO_FLAGS}"
	set_default "CGO_LDFLAGS" "${DEFAULT_CGO_LDFLAGS}"
	set_default "NDK_VERSION" "${DEFAULT_NDK_VERSION}"
}

# Checks if CGO is enabled
is_cgo_enabled() {
	[[ "${CGO_ENABLED}" == "1" ]] || [[ "${CGO_ENABLED}" == "true" ]] || [[ "${CGO_ENABLED}" == "t" ]]
}

# -----------------------------------------------------------------------------
# Download and Archive Handling
# -----------------------------------------------------------------------------

# Downloads a file from a URL and extracts it
# Arguments:
#   $1: URL of the file to download
#   $2: Directory to extract the file to
#   $3: Optional. File type (e.g., "tgz", "zip"). If not provided, it's extracted from the URL
download_and_extract() {
	local url="$1"
	local file="$2"
	local type="${3:-$(echo "${url}" | sed 's/.*\.//g')}"

	mkdir -p "${file}" || return $?
	file="$(cd "${file}" && pwd)" || return $?
	if [ "$(ls -A "${file}")" ]; then
		rm -rf "${file}"/* || return $?
	fi
	log_info "Downloading \"${url}\" to \"${file}\""

	local start_time=$(date +%s)

	case "${type}" in
	"tgz" | "gz")
		curl -sL "${url}" | tar -xf - -C "${file}" --strip-components 1 -z || return $?
		;;
	"bz2")
		curl -sL "${url}" | tar -xf - -C "${file}" --strip-components 1 -j || return $?
		;;
	"xz")
		curl -sL "${url}" | tar -xf - -C "${file}" --strip-components 1 -J || return $?
		;;
	"lzma")
		curl -sL "${url}" | tar -xf - -C "${file}" --strip-components 1 --lzma || return $?
		;;
	"zip")
		curl -sL "${url}" -o "${file}/tmp.zip" || return $?
		unzip -q -o "${file}/tmp.zip" -d "${file}" || return $?
		rm -f "${file}/tmp.zip" || return $?
		;;
	*)
		log_error "Unsupported compression type: ${type}"
		return 2
		;;
	esac

	local end_time=$(date +%s)
	log_success "Download and extraction successful (took $((end_time - start_time))s)"
}

# -----------------------------------------------------------------------------
# Target Management Functions
# -----------------------------------------------------------------------------

# Removes duplicate targets from a comma-separated list
remove_duplicate_targets() {
	local all_targets="$1"
	all_targets="$(echo "${all_targets}" | tr ', ' '\n' | sort | uniq | paste -s -d ',' -)"
	all_targets="${all_targets#,}"
	all_targets="${all_targets%,}"
	echo "${all_targets}"
}

# Adds targets to the allowed targets list
add_allowed_targets() {
	ALLOWED_PLATFORMS=$(remove_duplicate_targets "$ALLOWED_PLATFORMS,$1")
}

# Removes targets from the allowed targets list
delete_allowed_targets() {
	ALLOWED_PLATFORMS=$(echo "${ALLOWED_PLATFORMS}" | sed "s|${1}$||g" | sed "s|${1},||g")
}

# Clears the allowed targets list
clear_allowed_targets() {
	ALLOWED_PLATFORMS=""
}

# Initializes the targets based on environment variables and allowed targets
init_targets() {
	add_allowed_targets "$GODISTLIST"
}

# Checks if a target is allowed
check_target() {
	local target_target="$1"

	if [[ "${ALLOWED_PLATFORMS}" =~ (^|,)${target_target}($|,) ]]; then
		return 0
	else
		return 1
	fi
}

# Checks if a list of targets are allowed
check_targets() {
	for target in ${1//,/ }; do
		case $(
			check_target "${target}"
			echo $?
		) in
		0)
			continue
			;;
		1)
			log_error "Target not supported: ${target}"
			return 1
			;;
		*)
			log_error "Error checking target: ${target}"
			return 3
			;;
		esac
	done
	return 0
}

# Expands target patterns (e.g., "linux/*") to a list of supported targets
expand_targets() {
	local targets="$1"
	IFS=, read -r -a targets <<<"${targets}"
	local expanded_targets=""
	for target in "${targets[@]}"; do
		if [[ "${target}" == "all" ]] || [[ "${target}" == '*' ]]; then

			echo "${ALLOWED_PLATFORMS}"
			return 0
		elif [[ "${target}" == *\** ]]; then
			for tmp_var in ${ALLOWED_PLATFORMS//,/ }; do
				[[ "${tmp_var}" == ${target} ]] && expanded_targets="${expanded_targets},${tmp_var}"
			done
		elif [[ "${target}" != */* ]]; then
			expanded_targets="${expanded_targets},$(expand_targets "${target}/*")"
		else
			expanded_targets="${expanded_targets},${target}"
		fi
	done
	remove_duplicate_targets "${expanded_targets}"
}

# -----------------------------------------------------------------------------
# CGO Environment Management
# -----------------------------------------------------------------------------

# Resets CGO environment variables
reset_cgo() {
	TARGET_CC=""
	TARGET_CXX=""
	MORE_CGO_CFLAGS=""
	MORE_CGOTARGET_CXXFLAGS=""
	MORE_CGO_LDFLAGS=""
	EXTRA_PATH=""
	EXTRA_LIBRARY_PATH=""
}

# Converts relative CC/CXX paths to absolute paths
abs_cc_cxx() {
	local cc_command cc_options
	read -r cc_command cc_options <<<"${TARGET_CC}"
	TARGET_CC="$(command -v "${cc_command}")" || return 2
	[[ -n "${cc_options}" ]] && TARGET_CC="${TARGET_CC} ${cc_options}"

	local cxx_command cxx_options
	read -r cxx_command cxx_options <<<"${TARGET_CXX}"
	TARGET_CXX="$(command -v "${cxx_command}")" || return 2
	[[ -n "${cxx_options}" ]] && TARGET_CXX="${TARGET_CXX} ${cxx_options}"

	return 0
}

# Initializes CGO dependencies for the host target
init_host_cgo_deps() {
	TARGET_CC="${HOSTTARGET_CC}"
	TARGET_CXX="${HOSTTARGET_CXX}"
}

# Initializes CGO dependencies based on the target operating system and architecture
# Arguments:
#   $1: Target operating system (GOOS)
#   $2: Target architecture (GOARCH)
#   $3: Optional. Micro architecture variant
# Returns:
#   0: CGO dependencies initialized successfully
#   1: CGO disabled
#   2: Error initializing CGO dependencies
init_cgo_deps() {
	reset_cgo
	local goos="$1"
	local goarch="$2"
	local micro="$3"

	local cc_var="CC_FOR_${goos}_${goarch}"
	local cxx_var="CXX_FOR_${goos}_${goarch}"
	TARGET_CC=${CC_FOR_TARGET}
	TARGET_CXX=${CXX_FOR_TARGET}

	if [[ -n "${TARGET_CC}" ]] && [[ -n "${TARGET_CXX}" ]]; then
		TARGET_CC=${CC_FOR_TARGET}
		TARGET_CXX=${CXX_FOR_TARGET}
	fi

	if [[ -n "${TARGET_CC}" ]] && [[ -n "${TARGET_CXX}" ]]; then
		TARGET_CC="${TARGET_CC}"
		TARGET_CXX="${TARGET_CXX}"
		return 0
	fi

	if [[ -n "${CC}" ]] && [[ -n "${CXX}" ]]; then
		TARGET_CC="${CC}"
		TARGET_CXX="${CXX}"
		return 0
	elif [[ -n "${CC}" ]] || [[ -n "${CXX}" ]]; then
		log_error "Both CC and CXX must be set at the same time."
		return 2
	fi

	init_default_cgo_deps "$@" || return $?

	return 0
}

# -----------------------------------------------------------------------------
# Platform-Specific CGO Initialization
# -----------------------------------------------------------------------------

# Initializes default CGO dependencies based on the target operating system, architecture, and micro architecture
# Arguments:
#   $1: Target operating system (GOOS)
#   $2: Target architecture (GOARCH)
#   $3: Optional. Micro architecture variant
init_default_cgo_deps() {
	local goos="$1"
	local goarch="$2"
	local micro="$3"

	case "${goos}" in
	"linux")
		case "${GOHOSTOS}" in
		"linux" | "darwin") ;;
		*)
			if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
				init_host_cgo_deps "$@"
				return 0
			else
				log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
				return 1
			fi
			;;
		esac

		case "${GOHOSTARCH}" in
		"amd64" | "arm64" | "arm" | "ppc64le" | "riscv64" | "s390x") ;;
		*)
			if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
				init_host_cgo_deps "$@"
				return 0
			else
				log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
				return 1
			fi
			;;
		esac

		case "${micro}" in
		"hardfloat")
			micro="hf"
			;;
		"softfloat")
			micro="sf"
			;;
		esac
		case "${goarch}" in
		"386")
			init_linux_cgo "i686" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"amd64")
			init_linux_cgo "x86_64" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"arm")
			if [[ -z "${micro}" ]]; then
				init_linux_cgo "armv6" "eabihf" "" "${USE_GNU_LIBC:+gnu}" || return $?
			elif [[ "${micro}" =~ ^5 ]]; then
				init_linux_cgo "armv${micro%,*}" "eabi" "" "${USE_GNU_LIBC:+gnu}" || return $?
			else
				if [[ "${micro}" =~ ,softfloat$ ]]; then
					init_linux_cgo "armv${micro%,*}" "eabi" "" "${USE_GNU_LIBC:+gnu}" || return $?
				else
					init_linux_cgo "armv${micro%,*}" "eabihf" "" "${USE_GNU_LIBC:+gnu}" || return $?
				fi
			fi
			;;
		"arm64")
			init_linux_cgo "aarch64" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"mips")
			[[ "${micro}" == "hf" ]] && micro="" || micro="sf"
			init_linux_cgo "mips" "" "${micro}" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"mipsle")
			[[ "${micro}" == "hf" ]] && micro="" || micro="sf"
			init_linux_cgo "mipsel" "" "${micro}" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"mips64")
			[[ "${micro}" == "hf" ]] && micro="" || micro="sf"
			init_linux_cgo "mips64" "" "${micro}" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"mips64le")
			[[ "${micro}" == "hf" ]] && micro="" || micro="sf"
			init_linux_cgo "mips64el" "" "${micro}" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"ppc64")
			# init_linux_cgo "powerpc64" "" "" "${USE_GNU_LIBC:+gnu}"
			log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
			return 1
			;;
		"ppc64le")
			init_linux_cgo "powerpc64le" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"riscv64")
			init_linux_cgo "riscv64" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"s390x")
			init_linux_cgo "s390x" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		"loong64")
			init_linux_cgo "loongarch64" "" "" "${USE_GNU_LIBC:+gnu}" || return $?
			;;
		*)
			if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
				init_host_cgo_deps "$@" || return $?
			else
				log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
				return 1
			fi
			;;
		esac
		;;
	"windows")
		case "${GOHOSTOS}" in
		"linux" | "darwin") ;;
		*)
			if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
				init_host_cgo_deps "$@" || return $?
				return 0
			else
				log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
				return 1
			fi
			;;
		esac

		case "${GOHOSTARCH}" in
		"amd64" | "arm64" | "arm" | "ppc64le" | "riscv64" | "s390x") ;;
		*)
			if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
				init_host_cgo_deps "$@" || return $?
				return 0
			else
				log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
				return 1
			fi
			;;
		esac

		case "${goarch}" in
		"386")
			init_windows_cgo "i686" || return $?
			;;
		"amd64")
			init_windows_cgo "x86_64" || return $?
			;;
		*)
			if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
				init_host_cgo_deps "$@" || return $?
			else
				log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
				return 1
			fi
			;;
		esac
		;;
	"android")
		case "${GOHOSTOS}" in
		"windows" | "linux")
			[[ "${GOHOSTARCH}" != "amd64" ]] && log_error "CGO is disabled for android/${goarch}${micro:+"/$micro"}." && return 1
			;;
		"darwin") ;;
		*)
			log_error "CGO is disabled for android/${goarch}${micro:+"/$micro"}." && return 1
			;;
		esac
		init_android_ndk "${goarch}" "${micro}" || return $?
		;;
	"darwin")
		init_osx_cgo "${goarch}" "${micro}" || return $?
		;;
	"ios")
		init_ios_cgo "${goarch}" "${micro}" || return $?
		;;
	"freebsd")
		init_freebsd_cgo "${goarch}" "${micro}" || return $?
		;;
	*)
		if [[ "${goos}" == "${GOHOSTOS}" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
			init_host_cgo_deps "$@" || return $?
		else
			log_warning "CGO is disabled for ${goos}/${goarch}${micro:+"/$micro"}."
			return 1
		fi
		;;
	esac
}

# -----------------------------------------------------------------------------
# iOS CGO Initialization
# -----------------------------------------------------------------------------

# Initializes iOS CGO based on host OS
init_ios_cgo() {
	local goarch="$1"

	case "${GOHOSTOS}" in
	"darwin")
		init_ios_native_cgo "${goarch}" || return $?
		;;
	"linux")
		init_ios_cross_compiler_cgo "${goarch}" || return $?
		;;
	*)
		log_warning "Cross compiler not supported for ${GOHOSTOS}/${GOHOSTARCH}."
		return 2
		;;
	esac
}

# Initializes iOS CGO for native macOS builds
init_ios_native_cgo() {
	local goarch="$1"
	local sdk_name sdk_path arch_name min_version

	if [[ "${goarch}" == "amd64" ]] || [[ "${APPLE_SIMULATOR}" == "true" ]]; then
		sdk_name="iphonesimulator"
		min_version="miphonesimulator-version-min=4.2"
	else
		sdk_name="iphoneos"
		min_version="miphoneos-version-min=4.2"
	fi

	sdk_path=$(xcrun -sdk "${sdk_name}" --show-sdk-path) || {
		log_error "Failed to get iOS${APPLE_SIMULATOR:+ simulator} SDK path."
		return 1
	}

	case "${goarch}" in
	"amd64")
		arch_name="x86_64"
		;;
	"arm64")
		arch_name="arm64"
		;;
	*)
		log_warning "Unknown ios architecture: ${goarch}"
		return 2
		;;
	esac

	TARGET_CC="clang -arch ${arch_name} -${min_version} -isysroot ${sdk_path}"
	TARGET_CXX="clang++ -arch ${arch_name} -${min_version} -isysroot ${sdk_path}"
}

# Initializes iOS CGO for cross-compilation from Linux
init_ios_cross_compiler_cgo() {
	local goarch="$1"
	local host_arch="$(map_go_arch_to_gcc "${GOHOSTARCH}")"

	if [[ "${goarch}" == "arm64" ]] && [[ "${APPLE_SIMULATOR}" != "true" ]]; then
		init_ios_device_cross_compiler "${host_arch}" || return $?
	else
		init_ios_simulator_cross_compiler "${goarch}" "${host_arch}" || return $?
	fi
}

# Helper function to setup iOS cross-compiler
# Arguments:
#   $1: cross_compiler_name
#   $2: compiler_prefix
#   $3: target_name
#   $4: host_arch
setup_ios_cross_compiler() {
	local cross_compiler_name="$1"
	local compiler_prefix="$2"
	local target_name="$3"
	local host_arch="$4"

	# Check if compiler exists in cross compiler directory
	if [[ -x "${CROSS_COMPILER_DIR}/${cross_compiler_name}/bin/${compiler_prefix}-clang" ]] &&
		[[ -x "${CROSS_COMPILER_DIR}/${cross_compiler_name}/bin/${compiler_prefix}-clang++" ]]; then
		setup_existing_ios_cross_compiler "${cross_compiler_name}" "${compiler_prefix}" || return $?
		return 0
	fi

	# Download cross compiler
	download_ios_cross_compiler "${cross_compiler_name}" "${target_name}" "${host_arch}" "${compiler_prefix}" || return $?
}

# Initializes iOS device cross-compiler
init_ios_device_cross_compiler() {
	local host_arch="$1"
	setup_ios_cross_compiler "ioscross-arm64" "arm64-apple-darwin11" "iPhoneOS18-5-arm64" "${host_arch}"
}

# Initializes iOS simulator cross-compiler
init_ios_simulator_cross_compiler() {
	local goarch="$1"
	local host_arch="$2"

	case "${goarch}" in
	"arm64")
		setup_ios_cross_compiler "ioscross-simulator-arm64" "arm64-apple-darwin11" "iPhoneSimulator18-5-arm64" "${host_arch}"
		;;
	"amd64")
		setup_ios_cross_compiler "ioscross-simulator-amd64" "x86_64-apple-darwin11" "iPhoneSimulator18-5-x86_64" "${host_arch}"
		;;
	*)
		log_warning "Unknown ios architecture: ${goarch}"
		return 2
		;;
	esac
}

# Fixes rpath for Darwin/iOS linkers
# Returns: 0 on success, sets EXTRA_LIBRARY_PATH if using environment variable fallback
fix_darwin_linker_rpath() {
	local compiler_dir="$1"
	local arch_prefix="$2"
	local linker_path="${compiler_dir}/bin/${arch_prefix}-apple-darwin"*"-ld"

	# Try patchelf first
	if command -v patchelf &>/dev/null; then
		if patchelf --set-rpath "${compiler_dir}/lib" ${linker_path} 2>/dev/null; then
			return 0
		fi
	fi

	# Try chrpath as fallback
	if command -v chrpath &>/dev/null; then
		if chrpath -r "${compiler_dir}/lib" ${linker_path} 2>/dev/null; then
			return 0
		fi
	fi

	# Fallback to environment variable approach
	EXTRA_LIBRARY_PATH="${compiler_dir}/lib"
	return 0
}

# Sets up existing iOS cross-compiler environment
setup_existing_ios_cross_compiler() {
	local cross_compiler_name="$1"
	local compiler_prefix="$2"

	TARGET_CC="${compiler_prefix}-clang"
	TARGET_CXX="${compiler_prefix}-clang++"
	EXTRA_PATH="${CROSS_COMPILER_DIR}/${cross_compiler_name}/bin:${CROSS_COMPILER_DIR}/${cross_compiler_name}/clang/bin"
	fix_darwin_linker_rpath "${CROSS_COMPILER_DIR}/${cross_compiler_name}" "${compiler_prefix%%-*}"
}

# Downloads iOS cross-compiler
download_ios_cross_compiler() {
	local cross_compiler_name="$1"
	local target_name="$2"
	local host_arch="$3"
	local compiler_prefix="$4"
	local ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "20.04")

	[[ "$ubuntu_version" != *"."* ]] && ubuntu_version="20.04"

	download_and_extract "${GH_PROXY}https://github.com/zijiren233/cctools-port/releases/download/v0.1.6/ioscross-${target_name}-linux-${host_arch}-gnu-ubuntu-${ubuntu_version}.tar.gz" \
		"${CROSS_COMPILER_DIR}/${cross_compiler_name}" || return 2

	setup_existing_ios_cross_compiler "${cross_compiler_name}" "${compiler_prefix}" || return $?
}

# -----------------------------------------------------------------------------
# macOS/Darwin CGO Initialization
# -----------------------------------------------------------------------------

# Initializes macOS CGO based on host OS
init_osx_cgo() {
	local goarch="$1"

	case "${GOHOSTOS}" in
	"darwin")
		init_osx_native_cgo "${goarch}" || return $?
		;;
	"linux")
		init_osx_cross_compiler_cgo "${goarch}" || return $?
		;;
	*)
		log_warning "Cross compiler not supported for ${GOHOSTOS}/${GOHOSTARCH}."
		return 2
		;;
	esac
}

# Initializes macOS CGO for native macOS builds
init_osx_native_cgo() {
	local goarch="$1"
	local sdk_path

	sdk_path=$(xcrun -sdk macosx --show-sdk-path) || {
		log_error "Failed to get macOS SDK path."
		return 1
	}

	case "${goarch}" in
	"amd64")
		TARGET_CC="clang -arch x86_64 -mmacosx-version-min=10.11 -isysroot ${sdk_path}"
		TARGET_CXX="clang++ -arch x86_64 -mmacosx-version-min=10.11 -isysroot ${sdk_path}"
		;;
	"arm64")
		TARGET_CC="clang -arch arm64 -mmacosx-version-min=10.11 -isysroot ${sdk_path}"
		TARGET_CXX="clang++ -arch arm64 -mmacosx-version-min=10.11 -isysroot ${sdk_path}"
		;;
	*)
		log_warning "Unknown darwin architecture: ${goarch}"
		return 2
		;;
	esac
}

# Initializes macOS CGO for cross-compilation from Linux
init_osx_cross_compiler_cgo() {
	local goarch="$1"
	local host_arch="$(map_go_arch_to_gcc "${GOHOSTARCH}")"
	local target_arch="$(map_go_arch_to_gcc "${goarch}")"
	local cross_compiler_name="osxcross-${host_arch}"
	local compiler_prefix="${target_arch}-apple-darwin24.5"

	export OSXCROSS_MP_INC=1
	export MACOSX_DEPLOYMENT_TARGET=10.7

	# Check if compiler exists in cross compiler directory
	if [[ -x "${CROSS_COMPILER_DIR}/${cross_compiler_name}/bin/${compiler_prefix}-clang" ]] &&
		[[ -x "${CROSS_COMPILER_DIR}/${cross_compiler_name}/bin/${compiler_prefix}-clang++" ]]; then
		setup_existing_osx_cross_compiler "${cross_compiler_name}" "${compiler_prefix}" || return $?
		return 0
	fi

	# Download cross compiler
	download_osx_cross_compiler "${cross_compiler_name}" "${compiler_prefix}" "${host_arch}" || return $?
}

# Sets up existing macOS cross-compiler environment
setup_existing_osx_cross_compiler() {
	local cross_compiler_name="$1"
	local compiler_prefix="$2"

	TARGET_CC="${compiler_prefix}-clang"
	TARGET_CXX="${compiler_prefix}-clang++"
	EXTRA_PATH="${CROSS_COMPILER_DIR}/${cross_compiler_name}/bin:${CROSS_COMPILER_DIR}/${cross_compiler_name}/clang/bin"
	fix_darwin_linker_rpath "${CROSS_COMPILER_DIR}/${cross_compiler_name}" "${compiler_prefix%%-*}"
}

# Downloads macOS cross-compiler
download_osx_cross_compiler() {
	local cross_compiler_name="$1"
	local compiler_prefix="$2"
	local host_arch="$3"
	local ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "20.04")

	[[ "$ubuntu_version" != *"."* ]] && ubuntu_version="20.04"

	download_and_extract "${GH_PROXY}https://github.com/zijiren233/osxcross/releases/download/v0.2.3/osxcross-15-5-linux-${host_arch}-gnu-ubuntu-${ubuntu_version}.tar.gz" \
		"${CROSS_COMPILER_DIR}/${cross_compiler_name}" || return 2

	setup_existing_osx_cross_compiler "${cross_compiler_name}" "${compiler_prefix}" || return $?
}

# -----------------------------------------------------------------------------
# Linux CGO Initialization
# -----------------------------------------------------------------------------

# Initializes CGO dependencies for Linux
# Arguments:
#   $1: Architecture prefix (e.g., "i686", "x86_64")
#   $2: Optional. ABI (e.g., "eabi", "eabihf")
#   $3: Optional. Micro architecture variant
#   $4: Optional. Libc type ("gnu" or "musl", defaults to "musl")
init_linux_cgo() {
	local arch_prefix="$1"
	local abi="$2"
	local micro="$3"
	local libc="${4:-musl}"
	local cross_compiler_name="${arch_prefix}-linux-${libc}${abi}${micro}-cross"
	local gcc_name="${arch_prefix}-linux-${libc}${abi}${micro}-gcc"
	local gxx_name="${arch_prefix}-linux-${libc}${abi}${micro}-g++"

	# Check if compiler exists in cross compiler directory
	local compiler_dir="${CROSS_COMPILER_DIR}/${cross_compiler_name}"
	if [[ -x "${compiler_dir}/bin/${gcc_name}" ]] && [[ -x "${compiler_dir}/bin/${gxx_name}" ]]; then
		TARGET_CC="${gcc_name} -static --static"
		TARGET_CXX="${gxx_name} -static --static"
		EXTRA_PATH="${compiler_dir}/bin"
		return 0
	fi

	# Download cross compiler
	local host_arch="$(map_go_arch_to_gcc "${GOHOSTARCH}")"
	local download_url="${GH_PROXY}https://github.com/zijiren233/musl-cross-make/releases/download/${CGO_DEPS_VERSION}/${cross_compiler_name}-${GOHOSTOS}-${host_arch}.tgz"
	download_and_extract "${download_url}" "${compiler_dir}" || return 2

	TARGET_CC="${gcc_name} -static --static"
	TARGET_CXX="${gxx_name} -static --static"
	EXTRA_PATH="${compiler_dir}/bin"
}

# -----------------------------------------------------------------------------
# Windows CGO Initialization
# -----------------------------------------------------------------------------

# Initializes CGO dependencies for Windows
# Arguments:
#   $1: Architecture prefix (e.g., "i686", "x86_64")
init_windows_cgo() {
	local arch_prefix="$1"
	local cross_compiler_name="${arch_prefix}-w64-mingw32-cross"
	local gcc_name="${arch_prefix}-w64-mingw32-gcc"
	local gxx_name="${arch_prefix}-w64-mingw32-g++"

	# Check if compiler exists in cross compiler directory
	local compiler_dir="${CROSS_COMPILER_DIR}/${cross_compiler_name}"
	if [[ -x "${compiler_dir}/bin/${gcc_name}" ]] && [[ -x "${compiler_dir}/bin/${gxx_name}" ]]; then
		TARGET_CC="${gcc_name} -static --static"
		TARGET_CXX="${gxx_name} -static --static"
		EXTRA_PATH="${compiler_dir}/bin"
		return 0
	fi

	# Download cross compiler
	local host_arch="$(map_go_arch_to_gcc "${GOHOSTARCH}")"
	local download_url="${GH_PROXY}https://github.com/zijiren233/musl-cross-make/releases/download/${CGO_DEPS_VERSION}/${cross_compiler_name}-${GOHOSTOS}-${host_arch}.tgz"
	download_and_extract "${download_url}" "${compiler_dir}" || return 2

	TARGET_CC="${gcc_name} -static --static"
	TARGET_CXX="${gxx_name} -static --static"
	EXTRA_PATH="${compiler_dir}/bin"
}

# -----------------------------------------------------------------------------
# FreeBSD CGO Initialization
# -----------------------------------------------------------------------------

# Initializes CGO dependencies for FreeBSD
# Arguments:
#   $1: Target architecture (GOARCH)
#   $2: Optional. Micro architecture variant
# Note: Only amd64, arm64, and riscv64 are supported for cross-compilation
init_freebsd_cgo() {
	local goarch="$1"
	local micro="$2"

	# Check if running on FreeBSD natively
	if [[ "${GOHOSTOS}" == "freebsd" ]] && [[ "${goarch}" == "${GOHOSTARCH}" ]]; then
		init_host_cgo_deps "freebsd" "$@" || return $?
		return 0
	fi

	# Only support cross-compilation from Linux and macOS
	case "${GOHOSTOS}" in
	"linux" | "darwin") ;;
	*)
		log_warning "CGO cross-compilation to FreeBSD is not supported from ${GOHOSTOS}/${GOHOSTARCH}."
		return 1
		;;
	esac

	# Only certain host architectures can cross-compile
	case "${GOHOSTARCH}" in
	"amd64" | "arm64") ;;
	*)
		log_warning "CGO cross-compilation to FreeBSD is not supported from ${GOHOSTOS}/${GOHOSTARCH}."
		return 1
		;;
	esac

	# Map Go architecture to GCC architecture (only supported architectures)
	local arch_prefix
	case "${goarch}" in
	"amd64")
		arch_prefix="x86_64"
		;;
	"arm64")
		arch_prefix="aarch64"
		;;
	"riscv64")
		arch_prefix="riscv64"
		;;
	*)
		log_warning "CGO is not supported for freebsd/${goarch}${micro:+"/$micro"} (only amd64, arm64, and riscv64 are supported)."
		return 1
		;;
	esac

	local cross_compiler_name="${arch_prefix}-unknown-freebsd13-cross"
	local gcc_name="${arch_prefix}-unknown-freebsd13-gcc"
	local gxx_name="${arch_prefix}-unknown-freebsd13-g++"

	# Check if compiler exists in cross compiler directory
	local compiler_dir="${CROSS_COMPILER_DIR}/${cross_compiler_name}"
	if [[ -x "${compiler_dir}/bin/${gcc_name}" ]] && [[ -x "${compiler_dir}/bin/${gxx_name}" ]]; then
		TARGET_CC="${gcc_name}"
		TARGET_CXX="${gxx_name}"
		EXTRA_PATH="${compiler_dir}/bin"
		return 0
	fi

	# Download cross compiler
	local host_arch="$(map_go_arch_to_gcc "${GOHOSTARCH}")"
	local download_url="${GH_PROXY}https://github.com/zijiren233/musl-cross-make/releases/download/${CGO_DEPS_VERSION}/${cross_compiler_name}-${GOHOSTOS}-${host_arch}.tgz"
	download_and_extract "${download_url}" "${compiler_dir}" || return 2

	TARGET_CC="${gcc_name}"
	TARGET_CXX="${gxx_name}"
	EXTRA_PATH="${compiler_dir}/bin"
}

# -----------------------------------------------------------------------------
# Android CGO Initialization
# -----------------------------------------------------------------------------

# Initializes CGO dependencies for Android NDK
# Arguments:
#   $1: Target architecture (GOARCH)
init_android_ndk() {
	local goarch="$1"

	local ndk_dir="${CROSS_COMPILER_DIR}/android-ndk-${GOHOSTOS}-${NDK_VERSION}"

	# NDK prebuilt directory detection
	# On macOS, NDK always uses darwin-x86_64 even on Apple Silicon (runs via Rosetta 2)
	# On Linux, it uses linux-x86_64
	local ndk_host_arch="x86_64"
	local clang_base_dir="${ndk_dir}/toolchains/llvm/prebuilt/${GOHOSTOS}-${ndk_host_arch}/bin"

	local clang_prefix="$(get_android_clang "${goarch}")"

	if [[ ! -d "${ndk_dir}" ]]; then
		local ndk_url="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-${GOHOSTOS}.zip"
		download_and_extract "${ndk_url}" "${ndk_dir}" "zip" || return 2
		mv "$ndk_dir/android-ndk-${NDK_VERSION}/"* "$ndk_dir"
		rmdir "$ndk_dir/android-ndk-${NDK_VERSION}" || return 2
	fi

	if [[ ! -x "${clang_base_dir}/${clang_prefix}-clang" ]] || [[ ! -x "${clang_base_dir}/${clang_prefix}-clang++" ]]; then
		log_error "Android NDK not found or invalid. Please check the NDK_VERSION environment variable."
		log_error "Expected CC: ${clang_base_dir}/${clang_prefix}-clang"
		log_error "Expected CXX: ${clang_base_dir}/${clang_prefix}-clang++"
		return 2
	fi

	TARGET_CC="${clang_prefix}-clang"
	TARGET_CXX="${clang_prefix}-clang++"
	EXTRA_PATH="${clang_base_dir}"
}

# Gets the Clang host prefix for Android NDK
# Arguments:
#   $1: Target architecture (GOARCH)
# Returns:
#   The Clang host prefix
get_android_clang() {
	local API="${API:-24}"
	case ${1} in
	arm)
		echo "armv7a-linux-androideabi${API}"
		;;
	arm64)
		echo "aarch64-linux-android${API}"
		;;
	386)
		echo "i686-linux-android${API}"
		;;
	amd64)
		echo "x86_64-linux-android${API}"
		;;
	esac
}

# -----------------------------------------------------------------------------
# Version Comparison Functions
# -----------------------------------------------------------------------------

# Compares two version strings
compare_versions() {
	if [[ $1 == $2 ]]; then
		return 0
	fi

	local IFS=.
	local i ver1=($1) ver2=($2)

	# Fill empty fields in ver1 with zeros
	for ((i = ${#ver1[@]}; i < ${#ver2[@]}; i++)); do
		ver1[i]=0
	done

	# Fill empty fields in ver2 with zeros
	for ((i = ${#ver2[@]}; i < ${#ver1[@]}; i++)); do
		ver2[i]=0
	done

	for ((i = 0; i < ${#ver1[@]}; i++)); do
		if ((10#${ver1[i]} > 10#${ver2[i]})); then
			return 1
		fi
		if ((10#${ver1[i]} < 10#${ver2[i]})); then
			return 2
		fi
	done

	return 0
}

version_greater_than() {
	if [[ $(compare_versions "${GOVERSION}" "$1") -eq 1 ]]; then
		return 0
	fi
	return 1
}

version_less_than() {
	if [[ $(compare_versions "${GOVERSION}" "$1") -eq 2 ]]; then
		return 0
	fi
	return 1
}

version_equal() {
	if [[ $(compare_versions "${GOVERSION}" "$1") -eq 0 ]]; then
		return 0
	fi
	return 1
}

micro_disabled() {
	local micro="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
	local var="MICRO_${micro}_DISABLED"
	if [[ -n "${micro}" ]] && [[ -n "${!var}" ]]; then
		return 0
	fi
	return 1
}

submicro_disabled() {
	local micro="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
	local var="SUBMICRO_${micro}_DISABLED"
	if [[ -n "${micro}" ]] && [[ -n "${!var}" ]]; then
		return 0
	fi
	return 1
}

# -----------------------------------------------------------------------------
# Build Functions
# -----------------------------------------------------------------------------

# Cleans the build cache
clean_build_cache() {
	go clean -cache
}

# Gets the extension based on the build mode and operating system
# Arguments:
#   $1: Operating system (e.g., "linux", "windows", "darwin", "ios")
#   $2: Build mode (e.g., "archive", "shared", "default")
# Returns:
#   The extension string
extension() {
	local goos="$1"
	local buildmode="$2"
	if [ "$buildmode" == "archive" ] || [ "$buildmode" == "c-archive" ]; then
		if [ "$goos" == "windows" ]; then
			echo ".lib"
		else
			echo ".a"
		fi
	elif [ "$buildmode" == "shared" ] || [ "$buildmode" == "c-shared" ]; then
		if [ "$goos" == "windows" ]; then
			echo ".dll"
		elif [ "$goos" == "darwin" ] || [ "$goos" == "ios" ]; then
			echo ".dylib"
		else
			echo ".so"
		fi
	else
		if [ "$goos" == "windows" ]; then
			echo ".exe"
		fi
	fi
}

# Builds a target for a specific target and micro architecture variant
# Arguments:
#   $1: Target target (e.g., "linux/amd64")
#   $2: Target name (e.g., binary name)
# Ref:
# https://go.dev/wiki/MinimumRequirements#microarchitecture-support
# https://go.dev/doc/install/source#environment
build_target() {
	local target="$1"

	local goos="${target%/*}"
	local goarch="${target#*/}"

	echo -e "${COLOR_LIGHT_GRAY}$(print_separator)${COLOR_RESET}"

	clean_build_cache

	build_target_with_micro "${goos}" "${goarch}" ""

	if [ -z "${ENABLE_MICRO}" ]; then
		return 0
	fi
	if micro_disabled "${goarch}"; then
		return 0
	fi

	# Build micro architecture variants based on the target architecture.
	case "${goarch%%-*}" in
	"386")
		echo
		build_target_with_micro "${goos}" "${goarch}" "sse2"
		echo
		build_target_with_micro "${goos}" "${goarch}" "softfloat"
		;;
	"arm")
		for v in {5..7}; do
			echo
			build_target_with_micro "${goos}" "${goarch}" "$v"
			if submicro_disabled "arm"; then
				continue
			fi
			if version_less_than "${GOVERSION}" "1.22"; then
				continue
			fi
			echo
			build_target_with_micro "${goos}" "${goarch}" "$v,softfloat"
			echo
			build_target_with_micro "${goos}" "${goarch}" "$v,hardfloat"
		done
		;;
	"arm64")
		if version_less_than "${GOVERSION}" "1.23"; then
			return 0
		fi
		for major in 8 9; do
			for minor in $(seq 0 $((major == 8 ? 9 : 5))); do
				echo
				build_target_with_micro "${goos}" "${goarch}" "v${major}.${minor}"
				if submicro_disabled "arm64"; then
					continue
				fi
				echo
				build_target_with_micro "${goos}" "${goarch}" "v${major}.${minor},lse"
				echo
				build_target_with_micro "${goos}" "${goarch}" "v${major}.${minor},crypto"
			done
		done
		;;
	"amd64")
		if version_less_than "${GOVERSION}" "1.18"; then
			return 0
		fi
		for v in {1..4}; do
			echo
			build_target_with_micro "${goos}" "${goarch}" "v$v"
		done
		;;
	"mips" | "mipsle")
		if version_less_than "${GOVERSION}" "1.10"; then
			return 0
		fi
		echo
		build_target_with_micro "${goos}" "${goarch}" "hardfloat"
		echo
		build_target_with_micro "${goos}" "${goarch}" "softfloat"
		;;
	"mips64" | "mips64le")
		if version_less_than "${GOVERSION}" "1.11"; then
			return 0
		fi
		echo
		build_target_with_micro "${goos}" "${goarch}" "hardfloat"
		echo
		build_target_with_micro "${goos}" "${goarch}" "softfloat"
		;;
	"ppc64" | "ppc64le")
		for version in 8 9 10; do
			echo
			build_target_with_micro "${goos}" "${goarch}" "power${version}"
		done
		;;
	"wasm")
		echo
		build_target_with_micro "${goos}" "${goarch}" "satconv"
		echo
		build_target_with_micro "${goos}" "${goarch}" "signext"
		;;
	"riscv64")
		if version_less_than "${GOVERSION}" "1.23"; then
			return 0
		fi
		echo
		build_target_with_micro "${goos}" "${goarch}" "rva20u64"
		echo
		build_target_with_micro "${goos}" "${goarch}" "rva22u64"
		if version_less_than "${GOVERSION}" "1.25"; then
			return 0
		fi
		echo
		build_target_with_micro "${goos}" "${goarch}" "rva23u64"
		;;
	esac
}

# Builds a target for a specific target, micro architecture variant, and build environment
# Arguments:
#   $1: GOOS
#   $2: GOARCH
#   $3: Micro architecture variant (e.g., "sse2", "softfloat")
# Ref: https://go.dev/wiki/MinimumRequirements#microarchitecture-support
build_target_with_micro() {
	local goos="$1"
	local goarch="$2"
	local micro="$3"

	local build_env=(
		"GOOS=${goos}"
		"GOARCH=${goarch}"
	)
	local buildmode=$BUILDMODE
	local ext=$(extension "${goos}" "${buildmode}")
	local target_file="${RESULT_DIR}/${BIN_NAME}"

	# For non-build commands, we don't need target file with suffix
	if [[ "$COMMAND" == "build" ]]; then
		[ -z "$BIN_NAME_NO_SUFFIX" ] && target_file="${target_file}-${goos}-${goarch}${micro:+"-${micro//[.,]/-}"}" || true
		target_file="${target_file}${ext}"
	fi

	# Set micro architecture specific environment variables.
	case "${goarch}" in
	"386")
		build_env+=("GO386=${micro}")
		[ -z "$micro" ] && micro="sse2"
		;;
	"arm")
		build_env+=("GOARM=${micro}")
		[ -z "$micro" ] && micro="6"
		;;
	"arm64")
		build_env+=("GOARM64=${micro}")
		[ -z "$micro" ] && micro="v8.0"
		;;
	"amd64")
		build_env+=("GOAMD64=${micro}")
		;;
	"mips" | "mipsle")
		build_env+=("GOMIPS=${micro}")
		[ -z "$micro" ] && micro="hardfloat"
		;;
	"mips64" | "mips64le")
		build_env+=("GOMIPS64=${micro}")
		[ -z "$micro" ] && micro="hardfloat"
		;;
	"ppc64" | "ppc64le")
		build_env+=("GOPPC64=${micro}")
		;;
	"wasm")
		build_env+=("GOWASM=${micro}")
		;;
	"riscv64")
		build_env+=("GORISCV64=${micro}")
		[ -z "$micro" ] && micro="rva20u64"
		;;
	esac

	local command_capitalized="$(echo "${COMMAND:0:1}" | tr '[:lower:]' '[:upper:]')${COMMAND:1}"
	echo -e "${COLOR_LIGHT_MAGENTA}${command_capitalized} ${goos}/${goarch}${micro:+/${micro}}...${COLOR_RESET}"

	if is_cgo_enabled; then
		if init_cgo_deps "${goos}" "${goarch}" "${micro}"; then
			code=0
		else
			code=$?
		fi

		build_env+=("PATH=${EXTRA_PATH:+$EXTRA_PATH:}$PATH")

		# Set up library path if needed (e.g., for linker when patchelf/chrpath not available)
		if [[ -n "$EXTRA_LIBRARY_PATH" ]]; then
			if [[ "$GOHOSTOS" == "darwin" ]]; then
				build_env+=("DYLD_LIBRARY_PATH=${EXTRA_LIBRARY_PATH}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}")
			else
				build_env+=("LD_LIBRARY_PATH=${EXTRA_LIBRARY_PATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
			fi
		fi

		case "$code" in
		0)
			build_env+=("CGO_ENABLED=1")
			build_env+=("CC=${TARGET_CC}")
			build_env+=("CXX=${TARGET_CXX}")
			build_env+=("CGO_CFLAGS=${CGO_FLAGS}${MORE_CGO_CFLAGS:+ ${MORE_CGO_CFLAGS}}")
			build_env+=("CGOTARGET_CXXFLAGS=${CGO_FLAGS}${MORE_CGOTARGET_CXXFLAGS:+ ${MORE_CGOTARGET_CXXFLAGS}}")
			build_env+=("CGO_LDFLAGS=${CGO_LDFLAGS}${MORE_CGO_LDFLAGS:+ ${MORE_CGO_LDFLAGS}}")
			;;
		*)
			log_error "Error initializing CGO dependencies."
			return 1
			;;
		esac
	else
		build_env+=("CGO_ENABLED=0")
	fi

	local full_ldflags="${LDFLAGS}${EXT_LDFLAGS:+ -extldflags '$EXT_LDFLAGS'}"

	# Build the go command dynamically based on COMMAND variable
	local go_build_cmd="go ${COMMAND}"

	# Add -C flag first if specified
	[[ -n "$GO_CHANGE_DIR" ]] && go_build_cmd="$go_build_cmd -C \"${GO_CHANGE_DIR}\""

	# Add command-specific flags
	case "${COMMAND}" in
	"build")
		go_build_cmd="$go_build_cmd -buildmode=$buildmode"
		# Add -trimpath unless GO_TRIMPATH is explicitly set
		[[ "$GO_TRIMPATH" = "true" || -z "$GO_TRIMPATH" ]] && go_build_cmd="$go_build_cmd -trimpath"
		;;
	"test")
		# Test command doesn't use buildmode or output flags
		;;
	"bench")
		# Benchmark is actually 'go test -bench'
		go_build_cmd="go test -bench=."
		;;
	"run")
		# Run command doesn't use buildmode
		;;
	esac

	# Add standard go build flags
	[[ "$GO_A" = "true" ]] && go_build_cmd="$go_build_cmd -a"
	[[ "$GO_N" = "true" ]] && go_build_cmd="$go_build_cmd -n"
	[[ -n "$GO_P" ]] && go_build_cmd="$go_build_cmd -p ${GO_P}"
	[[ "$GO_RACE" = "true" ]] && go_build_cmd="$go_build_cmd -race"
	[[ "$GO_MSAN" = "true" ]] && go_build_cmd="$go_build_cmd -msan"
	[[ "$GO_ASAN" = "true" ]] && go_build_cmd="$go_build_cmd -asan"
	[[ "$GO_COVER" = "true" ]] && go_build_cmd="$go_build_cmd -cover"
	[[ -n "$GO_COVERMODE" ]] && go_build_cmd="$go_build_cmd -covermode ${GO_COVERMODE}"
	[[ -n "$GO_COVERPKG" ]] && go_build_cmd="$go_build_cmd -coverpkg \"${GO_COVERPKG}\""
	[[ "$GO_V" = "true" ]] && go_build_cmd="$go_build_cmd -v"
	[[ "$GO_WORK" = "true" ]] && go_build_cmd="$go_build_cmd -work"
	[[ "$GO_X" = "true" ]] && go_build_cmd="$go_build_cmd -x"
	[[ -n "$GO_ASMFLAGS" ]] && go_build_cmd="$go_build_cmd -asmflags \"${GO_ASMFLAGS}\""
	[[ -n "$GO_BUILDVCS" ]] && go_build_cmd="$go_build_cmd -buildvcs ${GO_BUILDVCS}"
	[[ -n "$GO_COMPILER" ]] && go_build_cmd="$go_build_cmd -compiler ${GO_COMPILER}"
	[[ -n "$GO_GCCGOFLAGS" ]] && go_build_cmd="$go_build_cmd -gccgoflags \"${GO_GCCGOFLAGS}\""
	[[ -n "$GO_GCFLAGS" ]] && go_build_cmd="$go_build_cmd -gcflags \"${GO_GCFLAGS}\""
	[[ -n "$GO_INSTALLSUFFIX" ]] && go_build_cmd="$go_build_cmd -installsuffix ${GO_INSTALLSUFFIX}"
	[[ "$GO_JSON" = "true" ]] && go_build_cmd="$go_build_cmd -json"
	[[ "$GO_LINKSHARED" = "true" ]] && go_build_cmd="$go_build_cmd -linkshared"
	[[ -n "$GO_MOD" ]] && go_build_cmd="$go_build_cmd -mod ${GO_MOD}"
	[[ "$GO_MODCACHERW" = "true" ]] && go_build_cmd="$go_build_cmd -modcacherw"
	[[ -n "$GO_MODFILE" ]] && go_build_cmd="$go_build_cmd -modfile \"${GO_MODFILE}\""
	[[ -n "$GO_OVERLAY" ]] && go_build_cmd="$go_build_cmd -overlay \"${GO_OVERLAY}\""
	[[ -n "$GO_PGO" ]] && go_build_cmd="$go_build_cmd -pgo \"${GO_PGO}\""
	[[ -n "$GO_PKGDIR" ]] && go_build_cmd="$go_build_cmd -pkgdir \"${GO_PKGDIR}\""
	[[ -n "$BUILD_TAGS" ]] && go_build_cmd="$go_build_cmd -tags \"${BUILD_TAGS}\""
	[[ "$GO_TRIMPATH" = "false" ]] && : # Already handled in build section
	[[ -n "$GO_TOOLEXEC" ]] && go_build_cmd="$go_build_cmd -toolexec \"${GO_TOOLEXEC}\""

	# Add ldflags (for build and run commands)
	if [[ "$COMMAND" == "build" ]] || [[ "$COMMAND" == "run" ]]; then
		[[ -n "$full_ldflags" ]] && go_build_cmd="$go_build_cmd -ldflags \"${full_ldflags}\""
	fi

	# Add output file (only for build command)
	if [[ "$COMMAND" == "build" ]]; then
		go_build_cmd="$go_build_cmd -o \"${target_file}\""
	fi

	# Add build args from ADD_GO_BUILD_ARGS variable
	[[ -n "$ADD_GO_BUILD_ARGS" ]] && go_build_cmd="$go_build_cmd $ADD_GO_BUILD_ARGS"

	# Add package path (defaults to current directory)
	go_build_cmd="$go_build_cmd ${PACKAGE}"

	log_info "Run command:"
	for var in "${build_env[@]}"; do
		key=$(echo "${var}" | cut -d= -f1)
		value=$(echo "${var}" | cut -d= -f2-)
		echo -e "  ${COLOR_LIGHT_GREEN}export${COLOR_RESET} ${COLOR_WHITE}${key}='${value}'${COLOR_RESET}"
	done
	echo -e "  ${COLOR_LIGHT_CYAN}${go_build_cmd}${COLOR_RESET}"

	local start_time=$(date +%s)

	# reset CC_FOR_TARGET and CC_FOR_${goos}_${goarch}, because it will be set by initCGODeps to CC and CXX environment variables
	build_env+=("CC_FOR_TARGET=")
	build_env+=("CXX_FOR_TARGET=")
	build_env+=("CC_FOR_${goos}_${goarch}=")
	build_env+=("CXX_FOR_${goos}_${goarch}=")

	eval env '"${build_env[@]}"' "$go_build_cmd"
	local end_time=$(date +%s)

	# Show appropriate success message based on command
	if [[ "$COMMAND" == "build" ]]; then
		log_success "${command_capitalized} successful: ${goos}/${goarch}${micro:+ ${micro}} (took $((end_time - start_time))s, size: $(du -sh "${target_file}" | cut -f1))"
	else
		log_success "${command_capitalized} successful: ${goos}/${goarch}${micro:+ ${micro}} (took $((end_time - start_time))s)"
	fi
}

# -----------------------------------------------------------------------------
# Main Build Orchestration
# -----------------------------------------------------------------------------

# Performs the automatic build process for the specified targets
# Arguments:
#   $1: Comma-separated list of targets to build for
auto_build() {
	local targets=$(expand_targets "$1")
	check_targets "${targets}" || return 1
	[ -z "${targets}" ] &&
		log_error "No targets specified." &&
		log_error "Supported targets: ${COLOR_LIGHT_CYAN}${ALLOWED_PLATFORMS}${COLOR_RESET}" &&
		return 1

	local command_capitalized="$(echo "${COMMAND:0:1}" | tr '[:lower:]' '[:upper:]')${COMMAND:1}"
	log_info "${command_capitalized} Targets: ${COLOR_LIGHT_GREEN}${targets}${COLOR_RESET}" 1>&2
	local start_time=$(date +%s)
	if declare -f init_dep >/dev/null; then
		init_dep
	fi
	local build_num=0
	for target in ${targets//,/ }; do
		build_target "${target}" # Ensure the full target with suffix is passed
		build_num=$((build_num + 1))
	done
	local end_time=$(date +%s)
	if [[ "${build_num}" -gt 1 ]]; then
		log_warning "Total took $((end_time - start_time))s"
	fi
}

# -----------------------------------------------------------------------------
# Configuration and Initialization
# -----------------------------------------------------------------------------

# Loads the build configuration file if it exists
load_build_config() {
	if [[ -f "${BUILD_CONFIG}" ]]; then
		source "${BUILD_CONFIG}" && return 0
		log_error "Failed to load build configuration from ${BUILD_CONFIG}" 1>&2
		exit 1
	fi
}

# Prints current configuration variables
print_var() {
	log_info "Working directory: ${COLOR_LIGHT_GREEN}$(pwd)${COLOR_RESET}" 1>&2
	log_info "Source directory: ${COLOR_LIGHT_GREEN}${SOURCE_DIR}${COLOR_RESET}" 1>&2
	log_info "Config file: ${COLOR_LIGHT_GREEN}${BUILD_CONFIG}${COLOR_RESET}" 1>&2
	local allowed_targets="$(echo "${ALLOWED_PLATFORMS}" | sed 's/,/ /g')"
	log_info "Allowed targets: ${COLOR_LIGHT_GREEN}${allowed_targets}${COLOR_RESET}" 1>&2
}

# -----------------------------------------------------------------------------
# Script Entry Point
# -----------------------------------------------------------------------------

set_default "SOURCE_DIR" "${DEFAULT_SOURCE_DIR}"
SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"
set_default "BUILD_CONFIG" "${SOURCE_DIR}/build.config.sh"
set_default "COMMAND" "${DEFAULT_COMMAND}"
set_default "PACKAGE" "${DEFAULT_PACKAGE}"

init_targets
print_var
load_build_config

# Handle USE_DEFAULT_CC_CXX flag
if [[ "$USE_DEFAULT_CC_CXX" = "true" ]]; then
	CC="${DEFAULT_CC}"
	CXX="${DEFAULT_CXX}"
fi

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------

# Array to collect package paths (non-option arguments)
PACKAGE_PATHS=()

while [[ $# -gt 0 ]]; do
	# Check if current argument is a command
	if [[ "$1" =~ ^(${SUPPORTED_COMMANDS})$ ]]; then
		COMMAND="$1"
		shift
		continue
	fi

	# Handle arguments that don't start with - as package paths
	if [[ ! "$1" =~ ^- ]]; then
		PACKAGE_PATHS+=("$1")
		shift
		continue
	fi

	case "${1}" in
	-h)
		print_help
		exit 0
		;;
	-eh)
		print_env_help
		exit 0
		;;
	# Standard Go build flags
	-C)
		shift
		GO_CHANGE_DIR="$(parse_option_value "-C" "$@")"
		;;
	-a)
		GO_A="true"
		;;
	-n)
		GO_N="true"
		;;
	-p)
		shift
		GO_P="$(parse_option_value "-p" "$@")"
		;;
	-race)
		GO_RACE="true"
		;;
	-msan)
		GO_MSAN="true"
		;;
	-asan)
		GO_ASAN="true"
		;;
	-cover)
		GO_COVER="true"
		;;
	-covermode)
		shift
		GO_COVERMODE="$(parse_option_value "-covermode" "$@")"
		;;
	-coverpkg)
		shift
		GO_COVERPKG="$(parse_option_value "-coverpkg" "$@")"
		;;
	-v)
		GO_V="true"
		;;
	-work)
		GO_WORK="true"
		;;
	-x)
		GO_X="true"
		;;
	-asmflags)
		shift
		GO_ASMFLAGS="$(parse_option_value "-asmflags" "$@")"
		;;
	-buildmode)
		shift
		BUILDMODE="$(parse_option_value "-buildmode" "$@")"
		;;
	-buildvcs)
		shift
		GO_BUILDVCS="$(parse_option_value "-buildvcs" "$@")"
		;;
	-compiler)
		shift
		GO_COMPILER="$(parse_option_value "-compiler" "$@")"
		;;
	-gccgoflags)
		shift
		GO_GCCGOFLAGS="$(parse_option_value "-gccgoflags" "$@")"
		;;
	-gcflags)
		shift
		GO_GCFLAGS="$(parse_option_value "-gcflags" "$@")"
		;;
	-installsuffix)
		shift
		GO_INSTALLSUFFIX="$(parse_option_value "-installsuffix" "$@")"
		;;
	-json)
		GO_JSON="true"
		;;
	-ldflags)
		shift
		LDFLAGS="${LDFLAGS:+$LDFLAGS }$(parse_option_value "-ldflags" "$@")"
		;;
	-linkshared)
		GO_LINKSHARED="true"
		;;
	-mod)
		shift
		GO_MOD="$(parse_option_value "-mod" "$@")"
		;;
	-modcacherw)
		GO_MODCACHERW="true"
		;;
	-modfile)
		shift
		GO_MODFILE="$(parse_option_value "-modfile" "$@")"
		;;
	-overlay)
		shift
		GO_OVERLAY="$(parse_option_value "-overlay" "$@")"
		;;
	-pgo)
		shift
		GO_PGO="$(parse_option_value "-pgo" "$@")"
		;;
	-pkgdir)
		shift
		GO_PKGDIR="$(parse_option_value "-pkgdir" "$@")"
		;;
	-tags)
		shift
		# Convert space-separated tags to comma-separated, remove quotes and newlines
		BUILD_TAGS="$(echo "$BUILD_TAGS $(parse_option_value "-tags" "$@")" | sed 's/^ //g' | sed 's/"//g' | sed 's/\n//g' | tr -s ' ' ',' | sed 's/^,//g' | sed 's/,,*/,/g')"
		;;
	-trimpath)
		GO_TRIMPATH="true"
		;;
	-toolexec)
		shift
		GO_TOOLEXEC="$(parse_option_value "-toolexec" "$@")"
		;;
	# Cross-compilation specific options
	-bin-name)
		shift
		BIN_NAME="$(parse_option_value "-bin-name" "$@")"
		;;
	-bin-name-no-suffix)
		BIN_NAME_NO_SUFFIX="true"
		;;
	-cross-compiler-dir)
		shift
		CROSS_COMPILER_DIR="$(parse_option_value "-cross-compiler-dir" "$@")"
		;;
	-cgo-enabled)
		CGO_ENABLED="1"
		;;
	-use-gnu-libc)
		USE_GNU_LIBC="true"
		;;
	-enable-micro)
		ENABLE_MICRO="true"
		;;
	-ext-ldflags)
		shift
		EXT_LDFLAGS="${EXT_LDFLAGS:+$EXT_LDFLAGS }$(parse_option_value "-ext-ldflags" "$@")"
		;;
	-cc)
		shift
		CC="$(parse_option_value "-cc" "$@")"
		;;
	-cxx)
		shift
		CXX="$(parse_option_value "-cxx" "$@")"
		;;
	-use-default-cc-cxx)
		CC="${DEFAULT_CC}"
		CXX="${DEFAULT_CXX}"
		;;
	-github-proxy-mirror)
		shift
		GH_PROXY="$(parse_option_value "-github-proxy-mirror" "$@")"
		;;
	-ndk-version)
		shift
		NDK_VERSION="$(parse_option_value "-ndk-version" "$@")"
		;;
	-t)
		shift
		PLATFORMS="$(parse_option_value "-t" "$@")"
		;;
	-result-dir)
		shift
		RESULT_DIR="$(parse_option_value "-result-dir" "$@")"
		;;
	-show-all-targets)
		echo "${ALLOWED_PLATFORMS}"
		exit 0
		;;
	-apple-simulator)
		APPLE_SIMULATOR="true"
		;;
	*)
		# Try to parse dependency args if function exists
		if declare -f parse_dep_args >/dev/null && parse_dep_args "$1"; then
			shift
			continue
		fi
		log_error "Invalid option: $1"
		log_error "Use -h for help"
		exit 1
		;;
	esac
	shift
done

# Set PACKAGE variable from collected paths
if [[ ${#PACKAGE_PATHS[@]} -gt 0 ]]; then
	PACKAGE="${PACKAGE_PATHS[*]}"
else
	set_default "PACKAGE" "${DEFAULT_PACKAGE}"
fi

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

fix_args
auto_build "${PLATFORMS}"

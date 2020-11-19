
# Interactive helpers for Android kernel development
# Copyright (C) 2019-2020 Danny Lin <danny@kdrag0n.dev>
#
# This script must be *sourced* from a Bourne-compatible shell in order to
# function. Nothing will happen if you execute it.
#
# Source a compiler-specific setup script for proper functionality. This is
# only a base script and does not suffice for kernel building without the
# flags that compiler-specific scripts append to kmake_flags.
#


#### CONFIGURATION ####

# Kernel name
kernel_name="ProtonKernel"

# Defconfig name
defconfig="redbull_defconfig"

# Target architecture
arch="arm64"

# Base kernel compile flags (extended by compiler setup script)
kmake_flags=(
	-j"${jobs:-6}"
	ARCH="$arch"
	O="out"
)

# Target device name to use in flashable package names
device_name="pixel5"


#### BASE ####

# Index of all variables and functions we set
# This allows us to clean up later without restarting the shell
_ksetup_vars+=(
	kernel_name
	defconfig
	arch
	kmake_flags
	device_name
	kroot
	_ksetup_vars
	_ksetup_functions
	_ksetup_old_ld_path
	_ksetup_old_path
)
_ksetup_functions+=(
	msg
	croot
	get_clang_version
	get_gcc_version
	buildnum
	zerover
	kmake
	mkimg
	dimg
	rel
	crel
	cleanbuild
	incbuild
	dbuild
	ktest
	inc
	dc
	cpc
	mc
	cf
	ec
	osize
	unsetup
)

# Get kernel repository root for later use
kroot="$PWD/$(dirname "$0")"

# Show an informational message
function msg() {
    echo -e "\e[1;32m$1\e[0m"
}

# Go to the root of the kernel repository repository
function croot() {
	cd "$kroot"
}

# Get the version of Clang in an user-friendly form
function get_clang_version() {
	"$1" --version | head -n 1 | sed -e 's/  */ /g' -e 's/[[:space:]]*$//' -e 's/^.*clang/clang/'
}

# Get the version of GCC in an user-friendly form
function get_gcc_version() {
	"$1" --version | head -n 1 | cut -d'(' -f2 | tr -d ')' | sed -e 's/[[:space:]]*$//'
}


#### VERSIONING ####

# Get the current build number
function buildnum() {
	cat "$kroot/out/.version"
}

# Reset the kernel version number
function zerover() {
	rm "$kroot/out/.version"
}


#### COMPILATION ####

# Make wrapper for kernel compilation
function kmake() {
	time make "${kmake_flags[@]}" "$@"
}


#### PACKAGE CREATION ####

# Create a flashable image with the current kernel image at the specified path
function mkimg() {
	local fn="${1:-flash.img}"

	# Populate fields based on build type (stable release or test build)
	if [[ $RELEASE_VER -gt 0 ]]; then
		local ver_prefix="v"
		local build_type="stable"
		local version="v$RELEASE_VER"
	else
		local ver_prefix="test"
		local build_type="test"
		local version="$(buildnum)"
	fi

	cp "$kroot/out/arch/$arch/boot/Image.lz4" "$kroot/flasher/rd/payload/"
	cat "$kroot/out/arch/$arch/boot/dts/google/"*.dtb > "$kroot/flasher/rd/payload/dtb"

	# Ensure that the directory containing $fn exists but $fn doesn't
	mkdir -p "$(dirname "$fn")"
	rm -f "$fn"

	echo "  IMG     $fn"
	"$kroot/flasher/pack-img.sh" "$fn"
}

# Create a test package of the current kernel image
function dimg() {
	mkimg "builds/$kernel_name-$device_name-test$(buildnum).img"
}

# Build an incremental release package with the specified version
function rel() {
	# Take the first argument as version and pass the rest to make
	local ver="$1"
	shift

	# Compile kernel
	kmake LOCALVERSION="-v$ver" KBUILD_BUILD_VERSION=1 "$@" && \

	# Create release package
	RELEASE_VER="$ver" mkimg "builds/$kernel_name-$device_name-v$ver.img"
}

# Build a clean release package
function crel() {
	kmake clean && rel "$@"
}


#### BUILD & PACKAGE HELPERS ####

# Build a clean working-copy package
function cleanbuild() {
	kmake clean && kmake "$@" && mkimg
}

# Build an incremental working-copy package
function incbuild() {
	kmake "$@" && mkimg
}

# Build an incremental test package
function dbuild() {
	kmake "$@" && dimg
}


#### INSTALLATION ####

# Flash the given kernel package (defaults to latest) on the device via fastboot
function ktest() {
	local fn="${1:-flash.img}"

	# If in fastbootd
	if fastboot devices 2>&1 | grep -q fastboot && fastboot getvar is-userspace 2>&1 | grep -q 'is-userspace: yes'; then
		fastboot reboot bootloader
	fi
	if adb devices 2>&1 | grep -q device; then
		adb reboot bootloader
	fi

	fastboot boot "$fn"
}


#### BUILD & FLASH HELPERS ####

# Build & flash an incremental working-copy kernel on the device via fastboot
function inc() {
	incbuild "$@" && ktest
}


#### KERNEL CONFIGURATION ####

# Show differences between the committed defconfig and current config
function dc() {
	diff "arch/$arch/configs/$defconfig" "$kroot/out/.config"
}

# Update the defconfig with the current config
function cpc() {
	cat "$kroot/out/.config" >| "arch/$arch/configs/$defconfig"
}

# Reset the current config to the committed defconfig
function mc() {
	kmake "$defconfig"
}

# Open an interactive config editor
function cf() {
	kmake nconfig
}

# Edit the raw text config
function ec() {
	"${EDITOR:-vim}" "$kroot/out/.config"
}


#### MISCELLANEOUS ####

# Get a sorted list of the size of various objects in the kernel
function osize() {
	find "$kroot/out" -type f -name '*.o' ! -name 'built-in.o' ! -name 'vmlinux.o' \
	-exec du -h --apparent-size {} + | sort -r -h | head -n "${1:-75}" | \
	perl -pe 's/([\d.]+[A-Z]?).+\/out\/(.+)\.o/$1\t$2.c/g'
}

# Get a sorted list of the size of various symbols in the kernel
function ssize() {
	nm --size -r "$kroot/out/vmlinux" | rg -ve ' b ' -e ' B ' | head -${1:-25}
}

# Clean up shell environment and remove all traces of ksetup
function unsetup() {
	# unset calls are silenced to prevent error spam when elements are
	# repeated, which can happen if ksetup is sourced more than once

	# Unset functions
	for func in "${_ksetup_functions[@]}"; do
		unset -f "$func" > /dev/null 2>&1
	done

	# Restore PATH, if modified
	[[ ! -z "$_ksetup_old_path" ]] && export PATH="$_ksetup_old_path"

	# Unset variables
	for var in "${_ksetup_vars[@]}"; do
		unset -v "$var" > /dev/null 2>&1
	done
}

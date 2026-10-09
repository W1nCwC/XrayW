#!/bin/sh
# XrayW installer and manager.
#
# POSIX sh: runs under dash (Debian/Ubuntu), busybox ash (Alpine, OpenWRT) and
# bash. Service backends: systemd, OpenRC (Alpine), procd (OpenWRT).
#
#   sh install.sh install [--lite|--full] [--prefix DIR] [--with-geo]
#                         [--binary FILE | --url URL | --version vX.Y.Z]
#
# After installation the same script is the `XrayW` command: run it without
# arguments for a menu, or use the shortcuts (see `XrayW help`). XrayR files
# are never modified; XrayR keeps running until `XrayW switch`.

set -eu

REPO="${XRAYW_REPO:-W1nCwC/XrayW}"
ROOT="${XRAYW_ROOT:-}"
CONF_DIR="$ROOT/etc/XrayW"
CONF="$CONF_DIR/config.yml"
ENVFILE="$CONF_DIR/install.env"
XRAYR_DIR="${XRAYR_DIR:-$ROOT/etc/XrayR}"
XRAYR_UNIT="XrayR"
GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
DEFAULT_PREFIX="$ROOT/usr/local/XrayW"
# Seconds to watch a service after start / switch (tests shorten them).
WAIT_START="${XRAYW_WAIT:-2}"
WAIT_SWITCH="${XRAYW_WAIT:-5}"
# Extra seconds the stability watch gives the supervisor to settle on a single
# process, on top of the caller's SECONDS. procd returns from `restart` while
# the old process is still exiting (its init script allows term_timeout 10 s)
# and systemd's pidof is briefly empty, so the settle time is not bounded by
# SECONDS. Tests lower this.
WAIT_SETTLE="${XRAYW_SETTLE:-8}"
# Size needed to download, unpack and replace (KiB): gzip + binary + old binary.
NEED_KB_LITE=90000
NEED_KB_FULL=170000

# ---- output ----------------------------------------------------------------

if [ -t 1 ]; then
	ESC="$(printf '\033')"
	C_RED="${ESC}[31m"
	C_GREEN="${ESC}[32m"
	C_YELLOW="${ESC}[33m"
	C_OFF="${ESC}[0m"
else
	C_RED=""
	C_GREEN=""
	C_YELLOW=""
	C_OFF=""
fi
red() { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF"; }
green() { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
yellow() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
die() {
	red "错误: $*" >&2
	exit 1
}

need_root() {
	[ -n "$ROOT" ] && return 0
	[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
}

# ask "question" -> 0 for yes. Non-interactive runs must pass -y.
ask() {
	if [ "${ASSUME_YES:-0}" -eq 1 ]; then
		return 0
	fi
	[ -t 0 ] || die "非交互环境请加 -y 确认"
	printf '%s [y/N] ' "$1"
	read -r _ans || _ans=""
	case "$_ans" in y | Y | yes | YES) return 0 ;; esac
	return 1
}

# ---- environment -----------------------------------------------------------

is_openwrt() { [ -f "$ROOT/etc/openwrt_release" ]; }

# load_env reads what `install` recorded (install prefix, build flavor).
load_env() {
	BIN_DIR="$DEFAULT_PREFIX"
	FLAVOR=""
	if [ -f "$ENVFILE" ]; then
		# shellcheck disable=SC1090
		. "$ENVFILE"
	fi
	BIN="$BIN_DIR/XrayW"
	if is_openwrt; then
		MGR="$ROOT/usr/bin/XrayW"
	else
		MGR="$ROOT/usr/local/bin/XrayW"
	fi
	BACKEND="$(detect_backend)"
}

save_env() {
	mkdir -p "$CONF_DIR"
	{
		printf 'BIN_DIR=%s\n' "$BIN_DIR"
		printf 'FLAVOR=%s\n' "$FLAVOR"
	} >"$ENVFILE"
}

detect_backend() {
	if [ -n "${XRAYW_BACKEND:-}" ]; then
		echo "$XRAYW_BACKEND"
	elif [ -d "$ROOT/run/systemd/system" ]; then
		echo systemd
	elif is_openwrt || [ -x "$ROOT/sbin/procd" ]; then
		echo procd
	elif command -v rc-service >/dev/null 2>&1 && [ -x "$ROOT/sbin/openrc-run" ]; then
		echo openrc
	else
		echo none
	fi
}

# elf_endian FILE prints l (little) or b (big) from the ELF header (EI_DATA,
# offset 5). `uname -m` does not tell MIPS endianness; OpenWRT has no `od`.
elf_endian() {
	[ -r "$1" ] || return 1
	_e="$(dd if="$1" bs=1 skip=5 count=1 2>/dev/null | tr '\001\002' 'lb')"
	case "$_e" in l | b)
		echo "$_e"
		return 0
		;;
	esac
	_e="$(hexdump -s 5 -n 1 -e '1/1 "%d"' "$1" 2>/dev/null || true)"
	case "$_e" in
	1)
		echo l
		return 0
		;;
	2)
		echo b
		return 0
		;;
	esac
	return 1
}

elf_probe_file() {
	if [ -n "${XRAYW_ELF_PROBE:-}" ]; then
		echo "$XRAYW_ELF_PROBE"
		return 0
	fi
	for _f in "$ROOT/bin/busybox" "$ROOT/bin/sh" "$ROOT/bin/ls"; do
		if [ -r "$_f" ]; then
			readlink -f "$_f" 2>/dev/null || echo "$_f"
			return 0
		fi
	done
	return 1
}

mips_arch() { # $1 = base name (mips|mips64)
	_f="$(elf_probe_file)" || die "无法判断 CPU 字节序（找不到可读的 /bin/busybox 或 /bin/sh）"
	_e="$(elf_endian "$_f")" || die "无法从 $_f 的 ELF 头判断字节序"
	if [ "$_e" = l ]; then
		case "$1" in
		mips) echo mipsle ;;
		*) echo mips64le ;;
		esac
	else
		echo "$1"
	fi
}

arm_variant() {
	_feat="$(grep -m1 -i '^Features' "${XRAYW_CPUINFO:-/proc/cpuinfo}" 2>/dev/null || true)"
	case " $_feat " in
	*" vfpv3 "* | *" vfpv3d16 "* | *" vfpv4 "*) echo armv7 ;;
	*" vfp "*) echo armv6 ;;
	*) echo armv5 ;;
	esac
}

# detect_arch prints the release architecture name (docs/PLAN-v5-v0.3.0.md).
detect_arch() {
	_m="${XRAYW_UNAME_M:-$(uname -m)}"
	case "$_m" in
	x86_64 | amd64) echo amd64 ;;
	i386 | i486 | i586 | i686) echo 386 ;;
	aarch64 | arm64) echo arm64 ;;
	armv7* | armv8l) arm_variant ;;
	armv6*)
		_v="$(arm_variant)"
		if [ "$_v" = armv5 ]; then echo armv5; else echo armv6; fi
		;;
	armv5*) echo armv5 ;;
	mips) mips_arch mips ;;
	mips64) mips_arch mips64 ;;
	riscv64) echo riscv64 ;;
	loongarch64) echo loong64 ;;
	*) die "不支持的 CPU 架构: $_m" ;;
	esac
}

# arch_fallbacks lists the architectures to try, best first: a CPU that lacks
# the FPU a GOARM level needs is detected by the binary's own `version` check.
arch_fallbacks() {
	case "$1" in
	armv7) echo "armv7 armv6 armv5" ;;
	armv6) echo "armv6 armv5" ;;
	*) echo "$1" ;;
	esac
}

default_flavor() {
	if is_openwrt; then echo lite; else echo full; fi
}

asset_name() { # arch flavor -> name of the .gz asset
	if [ "$2" = lite ]; then
		echo "XrayW-linux-$1-lite.gz"
	else
		echo "XrayW-linux-$1.gz"
	fi
}

# ---- downloads -------------------------------------------------------------

download() { # url dest
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 30 -O "$2" "$1"
	else
		die "需要 curl 或 wget"
	fi
}

fetch_text() { # url -> body on stdout
	_t="$(mktemp)"
	if download "$1" "$_t" >/dev/null 2>&1; then
		cat "$_t"
		rm -f "$_t"
		return 0
	fi
	rm -f "$_t"
	return 1
}

# latest_tag prints the newest release tag, pre-releases included
# (releases/latest skips them). The atom feed needs no API user agent.
latest_tag() {
	_tag=""
	_body="$(fetch_text "https://api.github.com/repos/$REPO/releases?per_page=1" 2>/dev/null)" || _body=""
	_tag="$(printf '%s\n' "$_body" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')" || _tag=""
	if [ -z "$_tag" ]; then
		_body="$(fetch_text "https://github.com/$REPO/releases.atom" 2>/dev/null)" || _body=""
		_tag="$(printf '%s\n' "$_body" | grep -m1 -o 'releases/tag/[^"<]*' | sed 's#releases/tag/##' | head -n1)" || _tag=""
	fi
	[ -n "$_tag" ] || return 1
	echo "$_tag"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# verify_sha256 FILE ASSET TAG checks FILE against the release SHA256SUMS.
verify_sha256() {
	if ! command -v sha256sum >/dev/null 2>&1; then
		yellow "未找到 sha256sum，跳过校验"
		return 0
	fi
	_sums="$(mktemp)"
	if ! download "https://github.com/$REPO/releases/download/$3/SHA256SUMS" "$_sums" >/dev/null 2>&1; then
		rm -f "$_sums"
		yellow "该版本没有 SHA256SUMS，跳过校验"
		return 0
	fi
	_want="$(awk -v n="$2" '{f=$2; sub(/^\*/, "", f); if (f == n) {print $1; exit}}' "$_sums")"
	rm -f "$_sums"
	[ -n "$_want" ] || die "SHA256SUMS 中没有 $2 的校验值"
	_got="$(sha256_of "$1")"
	[ "$_want" = "$_got" ] || die "SHA256 校验失败（期望 $_want，实际 $_got）"
	green "SHA256 校验通过: $2"
}

free_kb() { # directory -> free KiB of its filesystem
	_d="$1"
	while [ ! -d "$_d" ] && [ "$_d" != "/" ] && [ -n "$_d" ]; do
		_d="$(dirname "$_d")"
	done
	df -Pk "$_d" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_space() { # dir flavor
	if [ -n "${XRAYW_SKIP_SPACE_CHECK:-}" ]; then
		return 0
	fi
	_need="$NEED_KB_FULL"
	[ "$2" = lite ] && _need="$NEED_KB_LITE"
	_free="$(free_kb "$1")"
	case "$_free" in '' | *[!0-9]*) return 0 ;; esac
	if [ "$_free" -lt "$_need" ]; then
		red "$1 所在分区空间不足：可用 $((_free / 1024)) MB，需要约 $((_need / 1024)) MB（下载 + 解压 + 替换）。"
		if is_openwrt; then
			red "路由器内置闪存通常装不下：请挂载外部存储（extroot 或 USB/SD），再用 --prefix /mnt/xxx/XrayW 安装，并优先使用精简版（--lite）。"
		else
			red "请释放空间，或用 --prefix 指定空间更大的目录。"
		fi
		exit 1
	fi
}

# ---- binary ----------------------------------------------------------------

# fetch_binary SOURCE FLAVOR leaves the verified binary at $NEWBIN.
# SOURCE: latest | version:TAG | file:PATH | url:URL
fetch_binary() {
	_src="$1"
	_fl="$2"
	mkdir -p "$BIN_DIR"
	check_space "$BIN_DIR" "$_fl"
	TMPD="$BIN_DIR/.xrayw-dl.$$"
	mkdir -p "$TMPD"
	trap 'rm -rf "$TMPD"' EXIT INT TERM
	NEWBIN="$TMPD/XrayW"
	case "$_src" in
	file:*)
		_f="${_src#file:}"
		[ -f "$_f" ] || die "找不到文件: $_f"
		case "$_f" in
		*.gz) gunzip -c "$_f" >"$NEWBIN" ;;
		*) cp "$_f" "$NEWBIN" ;;
		esac
		;;
	url:*)
		download "${_src#url:}" "$TMPD/dl" || die "下载失败: ${_src#url:}"
		case "${_src#url:}" in
		*.gz) gunzip -c "$TMPD/dl" >"$NEWBIN" ;;
		*) mv "$TMPD/dl" "$NEWBIN" ;;
		esac
		;;
	*)
		if [ "$_src" = latest ]; then
			_tag="$(latest_tag)" || die "无法获取 $REPO 的发布版本（可用 --binary 指定本地文件）"
		else
			_tag="${_src#version:}"
		fi
		_arch="$(detect_arch)"
		_ok=0
		for _a in $(arch_fallbacks "$_arch"); do
			_asset="$(asset_name "$_a" "$_fl")"
			yellow "下载 XrayW $_tag ($_a, $_fl) ..."
			download "https://github.com/$REPO/releases/download/$_tag/$_asset" "$TMPD/dl.gz" || die "下载失败: $REPO $_tag $_asset"
			verify_sha256 "$TMPD/dl.gz" "$_asset" "$_tag"
			gunzip -c "$TMPD/dl.gz" >"$NEWBIN" || die "解压失败: $_asset"
			rm -f "$TMPD/dl.gz"
			chmod 755 "$NEWBIN"
			if "$NEWBIN" version >/dev/null 2>&1; then
				_ok=1
				break
			fi
			yellow "$_a 版本无法在此 CPU 上运行，尝试更低要求的版本"
		done
		[ "$_ok" -eq 1 ] || die "下载的程序无法运行（架构不符或文件损坏）"
		;;
	esac
	chmod 755 "$NEWBIN"
	"$NEWBIN" version >/dev/null 2>&1 || die "程序无法运行（架构不符或文件损坏）"
}

# ---- service backends ------------------------------------------------------
# Every backend defines be_<name>_<op>; `svc OP ARGS` dispatches. Units are
# named by the argument (XrayW, XrayR).

svc() {
	_op="$1"
	shift
	"be_${BACKEND}_${_op}" "$@"
}

# systemd ---------------------------------------------------------------------

be_systemd_install() {
	sed -e "s#@BIN@#$BIN#g" -e "s#@CONF@#$CONF#g" -e "s#@CONF_DIR@#$CONF_DIR#g" >"$ROOT/etc/systemd/system/XrayW.service" <<'EOF'
[Unit]
Description=XrayW Xboard node backend
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=@CONF_DIR@
ExecStart=@BIN@ -c @CONF@
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
Environment=XRAY_LOCATION_ASSET=@CONF_DIR@

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
}
be_systemd_remove() {
	rm -f "$ROOT/etc/systemd/system/XrayW.service"
	systemctl daemon-reload
}
be_systemd_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"; }
be_systemd_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
be_systemd_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }
be_systemd_start() { systemctl start "$1"; }
be_systemd_stop() { systemctl stop "$1"; }
be_systemd_restart() { systemctl restart "$1"; }
be_systemd_enable() { systemctl enable "$1" >/dev/null 2>&1; }
be_systemd_disable() { systemctl disable "$1" >/dev/null 2>&1; }
be_systemd_log() { journalctl -u "$1" -n "$2" --no-pager; }
be_systemd_follow() { journalctl -u "$1" -n 20 -f; }
be_systemd_levels() { :; }

# OpenRC (Alpine) -------------------------------------------------------------

be_openrc_install() {
	mkdir -p "$ROOT/etc/init.d"
	sed -e "s#@BIN@#$BIN#g" -e "s#@CONF@#$CONF#g" -e "s#@CONF_DIR@#$CONF_DIR#g" >"$ROOT/etc/init.d/XrayW" <<'EOF'
#!/sbin/openrc-run
# XrayW Xboard node backend (OpenRC)

name="XrayW"
description="XrayW Xboard node backend"

supervisor="supervise-daemon"
command="@BIN@"
command_args="-c @CONF@"
directory="@CONF_DIR@"

# Restart after a crash, forever, 10 s apart.
respawn_delay=10
respawn_max=0

rc_ulimit="-n 1048576"

output_log="/var/log/XrayW.log"
error_log="/var/log/XrayW.log"

supervise_daemon_args="--env XRAY_LOCATION_ASSET=@CONF_DIR@"

depend() {
	need localmount
	after net firewall
	use dns
}

start_pre() {
	# Keep the log from growing without bound.
	if [ -f "$output_log" ] && [ "$(wc -c <"$output_log")" -gt 10485760 ]; then
		: >"$output_log"
	fi
	return 0
}
EOF
	chmod 755 "$ROOT/etc/init.d/XrayW"
}
be_openrc_remove() { rm -f "$ROOT/etc/init.d/XrayW"; }
be_openrc_exists() { [ -x "$ROOT/etc/init.d/$1" ]; }
be_openrc_active() { rc-service "$1" status >/dev/null 2>&1; }
# Runlevels a service is enabled in (XrayR community scripts used a custom one).
be_openrc_levels() {
	for _d in "$ROOT"/etc/runlevels/*; do
		[ -e "$_d/$1" ] && printf '%s\n' "${_d##*/}"
	done
	return 0
}
be_openrc_enabled() { [ -n "$(be_openrc_levels "$1")" ]; }
be_openrc_start() { rc-service "$1" start; }
be_openrc_stop() { rc-service "$1" stop; }
be_openrc_restart() { rc-service "$1" restart; }
be_openrc_enable() {
	_lv="${2:-default}"
	rc-update add "$1" "$_lv" >/dev/null 2>&1
}
be_openrc_disable() {
	for _l in $(be_openrc_levels "$1"); do
		rc-update del "$1" "$_l" >/dev/null 2>&1 || true
	done
}
be_openrc_log() { tail -n "$2" "$ROOT/var/log/$1.log" 2>/dev/null || echo "（没有日志文件 /var/log/$1.log）"; }
be_openrc_follow() { tail -n 20 -f "$ROOT/var/log/$1.log"; }

# procd (OpenWRT) -------------------------------------------------------------

be_procd_install() {
	_env="XRAY_LOCATION_ASSET=$CONF_DIR"
	# Small routers: let Go collect garbage before memory runs out.
	_mem="$(awk '/^MemTotal:/ {print int($2 / 1024)}' "$ROOT/proc/meminfo" 2>/dev/null || true)"
	case "$_mem" in '' | *[!0-9]*) ;; *)
		if [ "$_mem" -lt 1024 ]; then
			_env="$_env GOMEMLIMIT=$((_mem * 40 / 100))MiB"
		fi
		;;
	esac
	mkdir -p "$ROOT/etc/init.d"
	sed -e "s#@BIN@#$BIN#g" -e "s#@CONF@#$CONF#g" -e "s#@ENV@#$_env#g" >"$ROOT/etc/init.d/XrayW" <<'EOF'
#!/bin/sh /etc/rc.common
# XrayW Xboard node backend (procd)

USE_PROCD=1
START=99
STOP=10

start_service() {
	procd_open_instance
	procd_set_param command "@BIN@" -c "@CONF@"
	procd_set_param env @ENV@
	procd_set_param limits nofile="1048576 1048576"
	# Restart after a crash, forever, 10 s apart.
	procd_set_param respawn 3600 10 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param term_timeout 10
	procd_close_instance
}
EOF
	chmod 755 "$ROOT/etc/init.d/XrayW"
}
be_procd_remove() { rm -f "$ROOT/etc/init.d/XrayW"; }
be_procd_exists() { [ -x "$ROOT/etc/init.d/$1" ]; }
# `status` reports "running" for a dead instance on OpenWRT <= 23.05; use `running`.
be_procd_active() {
	if "$ROOT/etc/init.d/$1" running >/dev/null 2>&1; then
		return 0
	fi
	return 1
}
be_procd_enabled() { "$ROOT/etc/init.d/$1" enabled >/dev/null 2>&1; }
be_procd_start() { "$ROOT/etc/init.d/$1" start; }
be_procd_stop() { "$ROOT/etc/init.d/$1" stop; }
be_procd_restart() { "$ROOT/etc/init.d/$1" restart; }
be_procd_enable() { "$ROOT/etc/init.d/$1" enable; }
be_procd_disable() { "$ROOT/etc/init.d/$1" disable; }
be_procd_log() { logread -e "$1" | tail -n "$2"; }
be_procd_follow() { logread -f -e "$1"; }
be_procd_levels() { :; }

# none ------------------------------------------------------------------------

no_backend() { die "没有检测到可用的服务管理器（systemd / OpenRC / procd）。可手动前台运行: $BIN -c $CONF"; }
be_none_install() { no_backend; }
be_none_remove() { :; }
be_none_exists() { return 1; }
be_none_active() { return 1; }
be_none_enabled() { return 1; }
be_none_start() { no_backend; }
be_none_stop() { no_backend; }
be_none_restart() { no_backend; }
be_none_enable() { no_backend; }
be_none_disable() { no_backend; }
be_none_log() { no_backend; }
be_none_follow() { no_backend; }
be_none_levels() { :; }

# daemon_pids prints the PIDs of the running program. busybox pidof also matches
# scripts by name, which would include this manager script itself.
daemon_pids() {
	_all="$(pidof XrayW 2>/dev/null || true)"
	_out=""
	for _p in $_all; do
		_exe="$(readlink "/proc/$_p/exe" 2>/dev/null || true)"
		case "$_exe" in
		"$BIN" | "$BIN "*) _out="$_out $_p" ;;
		esac
	done
	echo $_out
}

# stable_running UNIT SECONDS [STALE_PIDS]: running, and the same process the
# whole time (supervisors report a crash-looping service as started).
#
# A restart is not instantaneous, and the settling time is not bounded by
# SECONDS: systemd's pidof is empty for a moment after `restart` returns, and
# procd returns from `restart` while the old process is still shutting down
# (its init script allows term_timeout 10 s), so the very first poll can still
# see the process that is on its way out. So wait for exactly one process first
# (up to SECONDS + WAIT_SETTLE), then watch it for another SECONDS: still
# active and still that same PID.
#
# STALE_PIDS is the PID list the caller saw before it triggered the restart.
# Those processes are being replaced, so they are not a valid stability base:
# accepting one would make the (expected) handover look like a crash. They are
# only accepted once the settle budget is spent, which means the restart
# evidently did not replace the process at all. A crash-restart loop changes
# the PID and is still reported as unstable; a process that never appears
# still times out.
stable_running() {
	_unit="$1"
	_secs="$2"
	_stale="${3:-}"
	_settle=$((_secs + WAIT_SETTLE))
	_base=""
	_waited=0
	while :; do
		_base=""
		if svc active "$_unit"; then
			_pids="$(daemon_pids)"
			case "$_pids" in
			'' | *' '*) ;;
			*)
				case " $_stale " in
				*" $_pids "*)
					if [ "$_waited" -ge "$WAIT_SETTLE" ]; then
						_base="$_pids"
					fi
					;;
				*) _base="$_pids" ;;
				esac
				;;
			esac
		fi
		if [ -n "$_base" ]; then
			break
		fi
		if [ "$_waited" -ge "$_settle" ]; then
			return 1
		fi
		sleep 1
		_waited=$((_waited + 1))
	done
	_waited=0
	while :; do
		svc active "$_unit" || return 1
		_pids="$(daemon_pids)"
		[ "$_pids" = "$_base" ] || return 1
		if [ "$_waited" -ge "$_secs" ]; then
			return 0
		fi
		sleep 1
		_waited=$((_waited + 1))
	done
}

xrayr_present() {
	svc exists "$XRAYR_UNIT" || [ -f "$XRAYR_DIR/config.yml" ]
}

# ---- commands --------------------------------------------------------------

require_bin() {
	[ -x "$BIN" ] || die "XrayW 尚未安装（找不到 $BIN）。先执行: sh install.sh install"
}

run_check() {
	echo
	if "$BIN" check -c "$CONF" --online; then
		return 0
	fi
	red "配置检查未通过，请修改 $CONF 后执行: XrayW check"
	return 1
}

backup_conf() {
	if [ -d "$CONF_DIR" ]; then
		_b="$CONF_DIR.bak.$(date +%Y%m%d-%H%M%S)"
		cp -a "$CONF_DIR" "$_b"
		green "已备份 $CONF_DIR -> $_b"
	fi
}

# self_copy installs this script as the manager command and next to the binary.
self_copy() {
	_self=""
	if [ -f "${XRAYW_SELF:-$0}" ]; then
		_self="${XRAYW_SELF:-$0}"
	fi
	if [ -z "$_self" ]; then
		_self="$BIN_DIR/install.sh.dl"
		download "https://raw.githubusercontent.com/$REPO/main/install.sh" "$_self" || {
			yellow "未能保存安装脚本副本，管理命令 XrayW 不可用；请重新下载 install.sh 执行"
			rm -f "$_self"
			return 0
		}
	fi
	if [ "$_self" != "$BIN_DIR/install.sh" ]; then
		cp "$_self" "$BIN_DIR/install.sh.new"
		mv "$BIN_DIR/install.sh.new" "$BIN_DIR/install.sh"
	fi
	chmod 755 "$BIN_DIR/install.sh"
	mkdir -p "$(dirname "$MGR")"
	cp "$BIN_DIR/install.sh" "$MGR.new"
	chmod 755 "$MGR.new"
	mv "$MGR.new" "$MGR"
	[ "$_self" = "$BIN_DIR/install.sh.dl" ] && rm -f "$_self"
	return 0
}

ensure_geo() {
	for _f in geoip.dat geosite.dat; do
		if [ -s "$CONF_DIR/$_f" ]; then
			continue
		fi
		yellow "下载 $_f ..."
		if download "$GEO_BASE/$_f" "$CONF_DIR/$_f.tmp"; then
			mv "$CONF_DIR/$_f.tmp" "$CONF_DIR/$_f"
		else
			rm -f "$CONF_DIR/$_f.tmp"
			yellow "下载 $_f 失败；仅当路由使用 geosite:/geoip: 时需要，可稍后手动放入 $CONF_DIR"
		fi
	done
}

# OpenWRT's sysupgrade only keeps /etc/config and listed files.
keep_on_sysupgrade() {
	is_openwrt || return 0
	_sc="$ROOT/etc/sysupgrade.conf"
	touch "$_sc"
	for _p in "/etc/XrayW/" "/etc/init.d/XrayW"; do
		grep -qxF "$_p" "$_sc" 2>/dev/null || printf '%s\n' "$_p" >>"$_sc"
	done
}

# drop_sysupgrade_entries removes what keep_on_sysupgrade added; the config
# directory entry stays unless the config itself is purged.
drop_sysupgrade_entries() { # $1 = 1 to drop the config directory entry too
	is_openwrt || return 0
	_sc="$ROOT/etc/sysupgrade.conf"
	[ -f "$_sc" ] || return 0
	_tmp="$(mktemp)"
	grep -vxF "/etc/init.d/XrayW" "$_sc" >"$_tmp" || true
	if [ "$1" -eq 1 ]; then
		grep -vxF "/etc/XrayW/" "$_tmp" >"$_tmp.2" || true
		mv "$_tmp.2" "$_tmp"
	fi
	cat "$_tmp" >"$_sc"
	rm -f "$_tmp"
}

cmd_install() {
	_src="latest"
	_flavor=""
	_prefix=""
	_geo=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--binary)
			[ $# -ge 2 ] || die "--binary 需要文件路径"
			_src="file:$2"
			shift 2
			;;
		--url)
			[ $# -ge 2 ] || die "--url 需要地址"
			_src="url:$2"
			shift 2
			;;
		--version)
			[ $# -ge 2 ] || die "--version 需要版本号"
			_src="version:$2"
			shift 2
			;;
		--lite)
			_flavor=lite
			shift
			;;
		--full)
			_flavor=full
			shift
			;;
		--keep-flavor) shift ;;
		--prefix)
			[ $# -ge 2 ] || die "--prefix 需要目录"
			_prefix="$2"
			shift 2
			;;
		--with-geo)
			_geo=yes
			shift
			;;
		--no-geo)
			_geo=no
			shift
			;;
		-y | --yes)
			ASSUME_YES=1
			shift
			;;
		*) die "未知参数: $1" ;;
		esac
	done
	need_root

	[ -n "$_prefix" ] && BIN_DIR="$_prefix"
	BIN="$BIN_DIR/XrayW"
	# An upgrade keeps the flavor that was installed unless told otherwise.
	[ -z "$_flavor" ] && _flavor="$FLAVOR"
	[ -z "$_flavor" ] && _flavor="$(default_flavor)"
	FLAVOR="$_flavor"

	_was_active=0
	if [ -x "$BIN" ] && svc active XrayW 2>/dev/null; then
		_was_active=1
	fi

	fetch_binary "$_src" "$FLAVOR"
	mv "$NEWBIN" "$BIN"
	rm -rf "$TMPD"
	trap - EXIT INT TERM
	green "已安装 $("$BIN" version | head -n1)"

	mkdir -p "$CONF_DIR"
	save_env
	self_copy

	if [ ! -f "$CONF" ]; then
		if [ -f "$XRAYR_DIR/config.yml" ]; then
			green "检测到 XrayR 配置，开始迁移（XrayR 文件只读，不会被修改）"
			"$BIN" migrate --from "$XRAYR_DIR" --to "$CONF_DIR"
		else
			"$BIN" init --dir "$CONF_DIR"
			yellow "已生成默认配置，请编辑 $CONF 填写 ApiHost / ApiKey / NodeID（XrayW config）"
		fi
	else
		yellow "保留现有配置 $CONF（重新迁移请执行: XrayW migrate）"
	fi

	if [ "$_geo" = yes ] || { [ "$_geo" != no ] && ! is_openwrt; }; then
		ensure_geo
	elif is_openwrt; then
		yellow "OpenWRT 默认不下载 geo 文件（约 27 MB）；路由规则用到 geosite:/geoip: 时请加 --with-geo"
	fi

	if [ "$BACKEND" = none ]; then
		yellow "没有检测到可用的服务管理器（systemd / OpenRC / procd），程序与配置已就位但未注册为服务。"
		yellow "可手动前台运行: $BIN -c $CONF   （或 XrayW run）"
		return 0
	fi
	svc install
	keep_on_sysupgrade
	if is_openwrt; then
		yellow "提示：固件升级（sysupgrade）后配置会保留，但程序文件需要重新执行安装命令"
	fi

	if [ "$_was_active" -eq 1 ]; then
		svc restart XrayW
		green "XrayW 已重启（升级完成）"
		return 0
	fi
	_failed=0
	run_check || _failed=1
	if xrayr_present && { svc active "$XRAYR_UNIT" || svc enabled "$XRAYR_UNIT"; }; then
		yellow "XrayR 仍在运行/开机自启，为避免端口冲突，XrayW 暂未启动。"
		yellow "确认无误后执行: XrayW switch   （失败会自动回滚到 XrayR）"
	elif [ "$_failed" -eq 0 ]; then
		svc enable XrayW
		svc start XrayW
		green "XrayW 已启动并设为开机自启。管理命令: XrayW（菜单）、XrayW status、XrayW log"
	else
		yellow "服务尚未启动；编辑 $CONF（填写 ApiHost / ApiKey / NodeID）后执行 XrayW check，通过后执行 XrayW start，再执行 XrayW enable 设置开机自启。"
	fi
}

cmd_update() {
	require_bin
	# "XrayW update v1.2.3" is shorthand for "--version v1.2.3".
	case "${1:-}" in
	v[0-9]*)
		_v="$1"
		shift
		set -- --version "$_v" "$@"
		;;
	esac
	# Fetch the newest script first: it may know new platforms or flags.
	_new="$BIN_DIR/install.sh.latest"
	if download "https://raw.githubusercontent.com/$REPO/main/install.sh" "$_new" >/dev/null 2>&1 && [ -s "$_new" ]; then
		chmod 755 "$_new"
		mv "$_new" "$BIN_DIR/install.sh"
		exec sh "$BIN_DIR/install.sh" install "$@"
	fi
	rm -f "$_new"
	yellow "未能获取最新的安装脚本，使用当前脚本更新"
	cmd_install "$@"
}

cmd_migrate() {
	need_root
	require_bin
	[ -f "$XRAYR_DIR/config.yml" ] || die "未找到 $XRAYR_DIR/config.yml"
	backup_conf
	"$BIN" migrate --from "$XRAYR_DIR" --to "$CONF_DIR" --force
	run_check || true
	if svc active XrayW; then
		yellow "XrayW 正在运行，配置文件变更会自动重载"
	fi
}

cmd_check() {
	require_bin
	run_check
}

cmd_switch() {
	need_root
	require_bin
	run_check || die "检查未通过，未做切换"
	ask "将停止并禁用 XrayR、启用 XrayW，确认？" || die "已取消"
	if svc exists "$XRAYR_UNIT"; then
		# Remember where XrayR was enabled (OpenRC runlevel) for rollback.
		svc levels "$XRAYR_UNIT" >"$CONF_DIR/xrayr.levels" 2>/dev/null || true
		svc stop "$XRAYR_UNIT" || true
		svc disable "$XRAYR_UNIT" || true
	fi
	svc enable XrayW
	svc start XrayW
	if stable_running XrayW "$WAIT_SWITCH"; then
		green "切换完成，XrayW 运行中。回滚: XrayW rollback"
		svc log XrayW 20 || true
	else
		red "XrayW 启动失败，自动回滚到 XrayR"
		svc log XrayW 50 || true
		cmd_rollback
		exit 1
	fi
}

cmd_rollback() {
	need_root
	svc stop XrayW >/dev/null 2>&1 || true
	svc disable XrayW >/dev/null 2>&1 || true
	if svc exists "$XRAYR_UNIT"; then
		_lv="default"
		if [ -s "$CONF_DIR/xrayr.levels" ]; then
			_lv="$(head -n1 "$CONF_DIR/xrayr.levels")"
		fi
		svc enable "$XRAYR_UNIT" "$_lv"
		svc start "$XRAYR_UNIT" || true
		sleep 2
		if svc active "$XRAYR_UNIT"; then green "已恢复 XrayR"; else red "XrayR 未能启动，请查看它的日志"; fi
	else
		yellow "未找到 XrayR 服务，仅停止了 XrayW"
	fi
}

cmd_start() {
	need_root
	require_bin
	svc start XrayW
	if stable_running XrayW "$WAIT_START"; then
		green "已启动"
	else
		red "启动后未能保持运行，请查看日志: XrayW log"
		return 1
	fi
}
cmd_stop() {
	need_root
	svc stop XrayW
	green "已停止"
}
cmd_restart() {
	need_root
	require_bin
	# procd returns from `restart` while the old process is still exiting; the
	# old PID must not be mistaken for the new one (see stable_running).
	_old="$(daemon_pids)"
	svc restart XrayW
	if stable_running XrayW "$WAIT_START" "$_old"; then
		green "已重启"
	else
		red "重启后未能保持运行，请查看日志: XrayW log"
		return 1
	fi
}
cmd_enable() {
	need_root
	svc enable XrayW
	green "已设为开机自启"
}
cmd_disable() {
	need_root
	svc disable XrayW
	green "已取消开机自启"
}

cmd_log() {
	if [ "${1:-}" = "-n" ]; then
		svc log XrayW "${2:-100}"
	else
		svc follow XrayW
	fi
}

cmd_status() {
	if [ -x "$BIN" ]; then
		printf '版本:       %s\n' "$("$BIN" version 2>/dev/null | head -n1)"
	else
		printf '版本:       未安装（%s）\n' "$BIN"
	fi
	printf '服务管理器: %s\n' "$BACKEND"
	if svc exists XrayW; then
		if svc active XrayW; then
			_pid="$(daemon_pids)"
			printf '运行状态:   %s运行中%s（PID %s）\n' "$C_GREEN" "$C_OFF" "${_pid:-?}"
		else
			printf '运行状态:   %s未运行%s\n' "$C_RED" "$C_OFF"
		fi
		if svc enabled XrayW; then printf '开机自启:   是\n'; else printf '开机自启:   否\n'; fi
	else
		printf '运行状态:   服务未安装\n'
	fi
	if [ -f "$CONF" ]; then
		_n="$(grep -c '^[[:space:]]*ApiHost:' "$CONF" 2>/dev/null || true)"
		printf '配置:       %s（%s 个节点）\n' "$CONF" "${_n:-0}"
	fi
	if xrayr_present; then
		if svc active "$XRAYR_UNIT"; then
			printf 'XrayR:      %s仍在运行%s（可执行 XrayW switch 切换）\n' "$C_YELLOW" "$C_OFF"
		else
			printf 'XrayR:      已安装，未运行\n'
		fi
	fi
	if svc exists XrayW; then
		echo "--- 最近的 WebSocket 与错误日志"
		svc log XrayW 300 2>/dev/null | grep -E 'websocket|level=(error|warning)' | tail -n 8 || true
	fi
}

cmd_config() {
	need_root
	[ -f "$CONF" ] || die "找不到配置文件 $CONF"
	"${EDITOR:-vi}" "$CONF"
	if [ -x "$BIN" ] && ask "检查修改后的配置？"; then
		run_check || true
	fi
}

cmd_uninstall() {
	_purge=0
	for _a in "$@"; do
		case "$_a" in
		--purge) _purge=1 ;;
		-y | --yes) ASSUME_YES=1 ;;
		esac
	done
	need_root
	if [ "$_purge" -eq 1 ]; then
		ask "将卸载 XrayW 并删除配置目录 $CONF_DIR，确认？" || die "已取消"
	else
		ask "将卸载 XrayW（保留配置目录 $CONF_DIR），确认？" || die "已取消"
	fi
	svc stop XrayW >/dev/null 2>&1 || true
	svc disable XrayW >/dev/null 2>&1 || true
	svc remove XrayW || true
	rm -f "$BIN" "$BIN_DIR/install.sh" "$MGR"
	rmdir "$BIN_DIR" 2>/dev/null || true
	drop_sysupgrade_entries "$_purge"
	if [ "$_purge" -eq 1 ]; then
		case "$CONF_DIR" in
		*/etc/XrayW)
			rm -rf "$CONF_DIR"
			# cmd_migrate() backs the config directory up to
			# $CONF_DIR.bak.<timestamp> (a full copy, ApiKey included);
			# --purge removes those too. Only paths that keep the exact
			# $CONF_DIR prefix and the .bak. suffix are touched.
			for _b in "$CONF_DIR".bak.*; do
				[ -e "$_b" ] || continue
				case "$_b" in
				"$CONF_DIR".bak.*) rm -rf "$_b" ;;
				esac
			done
			;;
		*) die "拒绝删除异常的配置目录路径: $CONF_DIR" ;;
		esac
		# OpenRC writes its log to a file instead of the journal/syslog; the
		# script itself never rotates it, so remove just the file.
		rm -f "$ROOT/var/log/XrayW.log"
		green "已卸载并删除 $CONF_DIR"
	else
		green "已卸载（保留配置 $CONF_DIR）"
	fi
}

cmd_run() {
	require_bin
	exec "$BIN" -c "$CONF" "$@"
}

usage() {
	cat <<'EOF'
XrayW 管理命令

  XrayW                    打开管理菜单
  XrayW start|stop|restart 启动 / 停止 / 重启服务
  XrayW status             版本、运行状态、开机自启、WebSocket 与最近错误
  XrayW log [-n 行数]      实时查看日志（加 -n 只看最近若干行）
  XrayW check              检查配置并向面板验证每个节点
  XrayW config             编辑配置文件，保存后可立即检查
  XrayW enable|disable     开机自启 开 / 关
  XrayW update [版本号] [--lite|--full]  更新程序（默认保持当前的版本类型）
  XrayW migrate            重新迁移 XrayR 配置（先备份）
  XrayW switch [-y]        停用 XrayR、启用 XrayW（失败自动回滚）
  XrayW rollback           停用 XrayW、恢复 XrayR
  XrayW uninstall [--purge] [-y]  卸载（--purge 同时删除配置）
  XrayW run                前台运行（已有实例在运行时会被拒绝）
  XrayW version | x25519 | init ...  程序本体的命令

首次安装:
  sh install.sh install [--lite|--full] [--prefix DIR] [--with-geo]
                        [--binary 文件 | --url 地址 | --version vX.Y.Z]
EOF
}

menu() {
	while :; do
		echo
		echo "================ XrayW 管理菜单 ================"
		if [ -x "$BIN" ]; then
			printf '  版本: %s\n' "$("$BIN" version 2>/dev/null | head -n1)"
		fi
		_state="未安装服务"
		if svc exists XrayW; then
			if svc active XrayW; then _state="运行中"; else _state="未运行"; fi
			if svc enabled XrayW; then _state="$_state / 开机自启"; else _state="$_state / 未自启"; fi
		fi
		printf '  状态: %s    服务管理器: %s\n' "$_state" "$BACKEND"
		cat <<'EOF'
--------------------------------------------------
   1. 启动        2. 停止        3. 重启
   4. 查看状态    5. 实时日志    6. 检查配置
   7. 编辑配置    8. 开机自启开关    9. 更新程序
  10. 从 XrayR 迁移配置   11. 切换到 XrayW   12. 回滚到 XrayR
  13. 卸载
   0. 退出
==================================================
EOF
		printf '请选择: '
		read -r _c || return 0
		case "$_c" in
		1) cmd_start || true ;;
		2) cmd_stop ;;
		3) cmd_restart || true ;;
		4) cmd_status ;;
		5) cmd_log ;;
		6) cmd_check || true ;;
		7) cmd_config ;;
		8)
			if svc enabled XrayW; then cmd_disable; else cmd_enable; fi
			;;
		9) cmd_update ;;
		10) cmd_migrate ;;
		11) cmd_switch ;;
		12) cmd_rollback ;;
		13) cmd_uninstall ;;
		0 | q | Q | exit) return 0 ;;
		*) yellow "无效的选择" ;;
		esac
	done
}

# dispatch COMMAND [ARGS...]. Run as the `XrayW` command, anything that is
# not a management command goes to the program itself (XrayW migrate --from
# ..., XrayW x25519, XrayW -c config.yml); the installer script rejects it.
dispatch() {
	_cmd="${1:-}"
	[ $# -gt 0 ] && shift
	case "$_cmd" in
	install) cmd_install "$@" ;;
	update) cmd_update "$@" ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	restart) cmd_restart ;;
	enable) cmd_enable ;;
	disable) cmd_disable ;;
	status) cmd_status ;;
	log) cmd_log "$@" ;;
	check) if [ "$AS_MANAGER" = 1 ] && [ $# -gt 0 ]; then
		require_bin
		exec "$BIN" check "$@"
	else cmd_check; fi ;;
	config) cmd_config ;;
	migrate) if [ "$AS_MANAGER" = 1 ] && [ $# -gt 0 ]; then
		require_bin
		exec "$BIN" migrate "$@"
	else cmd_migrate; fi ;;
	switch)
		case "${1:-}" in -y | --yes) ASSUME_YES=1 ;; esac
		cmd_switch
		;;
	rollback) cmd_rollback ;;
	uninstall) cmd_uninstall "$@" ;;
	run) cmd_run "$@" ;;
	menu) menu ;;
	help | -h | --help) usage ;;
	"")
		if [ "$AS_MANAGER" = 1 ] && [ -t 0 ]; then menu; else usage; fi
		;;
	*)
		if [ "$AS_MANAGER" = 1 ]; then
			require_bin
			exec "$BIN" "$_cmd" "$@"
		fi
		usage
		exit 1
		;;
	esac
}

main() {
	ASSUME_YES=0
	AS_MANAGER=0
	case "${0##*/}" in XrayW) AS_MANAGER=1 ;; esac
	load_env
	dispatch "$@"
}

# Sourced by the tests (tests/install_test.sh) without running main.
if [ -z "${XRAYW_LIB:-}" ]; then
	main "$@"
fi

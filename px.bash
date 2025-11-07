#!/usr/bin/env bash
set -euo pipefail

VERSION="{{PX_VERSION_FROM_GIT}}"

usage() {
	cat <<'EOF'
usage: px <command> [args]
commands:
  init [dir]        Initialize px.yaml and requirements.txt (creates dir when provided)
  install           Resolve python, create venv, sync dependencies
  run               Run a px.yaml script, python file, or stdin
  start             Run scripts.start or entrypoint
  exec              Execute a command inside the virtualenv
  add [--latest|--compatible] <pkg[@spec]...>
                    Add dependencies (optionally pinned) and reinstall
  rm <pkg...>       Remove direct dependency and reinstall
  doctor            Show project + environment status
  gen completions   Generate shell completions
  gen autoactivate  Generate shell auto-activation hook
  --version         Show px version
  --help            Show this help
EOF
}

die() {
	echo "px: $*" >&2
	exit 1
}

warn() {
	echo "px: $*" >&2
}

px_root_optional() {
	local d="$PWD"
	while [ "$d" != "/" ]; do
		if [ -f "$d/px.yaml" ]; then
			printf '%s\n' "$d"
			return 0
		fi
		d="$(dirname "$d")"
	done
	return 1
}

px_root() {
	local root
	if root="$(px_root_optional)"; then
		printf '%s\n' "$root"
		return 0
	fi
	printf '%s\n' "$PWD"
	return 0
}

config_present() {
	px_root_optional >/dev/null 2>&1
}

config_file() {
	printf '%s/px.yaml\n' "$(px_root)"
}

_config_read() {
	ensure_python
	local file mode
	file="$(config_file)"
	mode="$1"
	shift
	python3 - "$file" "$mode" "$@" <<'PY'
import ast
import sys

path = sys.argv[1]
mode = sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""

def parse_value(raw):
	raw = raw.strip()
	if not raw:
		return ""
	if raw[0] in "\"'" and raw[-1] == raw[0]:
		try:
			return str(ast.literal_eval(raw))
		except Exception:
			return raw[1:-1]
	if " #" in raw:
		raw = raw.split(" #", 1)[0].rstrip()
	return raw

data = {}
scripts = {}
current = None

try:
	with open(path, "r", encoding="utf-8") as fh:
		for raw_line in fh:
			line = raw_line.rstrip("\n")
			stripped = line.lstrip(" \t")
			if not stripped or stripped.startswith("#"):
				continue
			indent = len(line) - len(stripped)
			if indent == 0:
				current = None
				if ":" not in line:
					continue
				key, value = line.split(":", 1)
				key = key.strip()
				value = value.strip()
				if key == "scripts":
					current = "scripts"
					continue
				data[key] = parse_value(value)
			else:
				if current == "scripts":
					if ":" not in stripped:
						continue
					subkey, subvalue = stripped.split(":", 1)
					subkey = subkey.strip()
					subvalue = subvalue.strip()
					scripts[subkey] = parse_value(subvalue)
except FileNotFoundError:
	pass

data["scripts"] = scripts

if mode == "value":
	print(data.get(arg, ""))
elif mode == "script":
	print(data.get("scripts", {}).get(arg, ""))
elif mode == "scripts":
	for name in data.get("scripts", {}):
		print(name)
PY
}

ensure_uv() {
	command -v uv >/dev/null 2>&1 || die "uv not found; install uv via 'pipx install uv' or see https://github.com/astral-sh/uv"
}

ensure_python() {
	command -v python3 >/dev/null 2>&1 || die "python3 not found; install Python 3 (e.g. via pyenv or your package manager)"
}

ensure_pip() {
	python3 -m pip --version >/dev/null 2>&1 || die "pip not found for python3; install pip (e.g. 'python3 -m ensurepip --upgrade')"
}

detect_python_constraint() {
	ensure_python
	python3 - <<'PY'
import sys
major = sys.version_info[0]
minor = sys.version_info[1]
print(f">={major}.{minor},<{major}.{minor + 1}")
PY
}

version_ge() {
	local v1="$1" v2="$2"
	IFS=. read -r a b c <<<"$v1"
	IFS=. read -r d e f <<<"$v2"
	a=${a:-0}; b=${b:-0}; c=${c:-0}; d=${d:-0}; e=${e:-0}; f=${f:-0}
	(( a > d )) && return 0
	(( a < d )) && return 1
	(( b > e )) && return 0
	(( b < e )) && return 1
	(( c >= f )) && return 0 || return 1
}

version_lt() {
	local v1="$1" v2="$2"
	IFS=. read -r a b c <<<"$v1"
	IFS=. read -r d e f <<<"$v2"
	a=${a:-0}; b=${b:-0}; c=${c:-0}; d=${d:-0}; e=${e:-0}; f=${f:-0}
	(( a < d )) && return 0
	(( a > d )) && return 1
	(( b < e )) && return 0
	(( b > e )) && return 1
	(( c < f )) && return 0 || return 1
}

version_satisfies() {
	local current="$1"
	local constraint="$2"
	local ok=0
	IFS=',' read -r -a parts <<<"$constraint"
	for part in "${parts[@]}"; do
		part="${part// /}"
		[ -z "$part" ] && continue
		case "$part" in
			">="*)
				local need="${part#>=}"
				version_ge "$current" "$need" || return 1
				ok=1
				;;
			"<"*)
				local limit="${part#<}"
				version_lt "$current" "$limit" || return 1
				ok=1
				;;
			*)
				# unsupported pattern; bail out so caller can handle
				return 1
				;;
		esac
	done
	[ "$ok" -eq 1 ] || return 1
	return 0
}

cfg() {
	local value
	value=$(_config_read value "$1")
	printf '%s\n' "$value"
}

venv_path() {
	local v
	v="$(cfg venv_path)"
	[ -z "$v" ] && v=".venv"
	printf '%s\n' "$v"
}

reqfile() {
	local r
	r="$(cfg requirements)"
	[ -z "$r" ] && r="requirements.txt"
	printf '%s\n' "$r"
}

lockfile() {
	local l
	l="$(cfg lockfile)"
	[ -z "$l" ] && l="requirements.lock"
	printf '%s\n' "$l"
}

venv_dir() {
	printf '%s/%s\n' "$(px_root)" "$(venv_path)"
}

to_number() {
	local s
	s=$(printf '%s' "$1" | tr -cd '0-9')
	[ -z "$s" ] && s=0
	printf '%s\n' "$s"
}

semver_from_tag_ahead() {
	local tag="$1"
	local ahead="$2"
	local cleaned major minor patch
	cleaned=${tag#v}
	cleaned=${cleaned#V}
	cleaned=${cleaned%%-*}
	IFS='.' read -r major minor patch <<EOF
$cleaned
EOF
	major=$(to_number "$major")
	minor=$(to_number "$minor")
	patch=$(to_number "$patch")
	ahead=$(to_number "$ahead")
	patch=$((patch + ahead))
	printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

git_short_version() {
	local root tag ahead
	command -v git >/dev/null 2>&1 || { echo "0.0.0"; return; }
	root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	[ -z "$root" ] && echo "0.0.0" && return
	tag=$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)
	[ -z "$tag" ] && echo "0.0.0" && return
	ahead=$(git -C "$root" rev-list --count "${tag}..HEAD" 2>/dev/null || echo 0)
	semver_from_tag_ahead "$tag" "$ahead"
}

set_current_version() {
	CURRENT_VERSION="$VERSION"
}

script_command() {
	local key="$2"
	local value
	value=$(_config_read script "$key")
	[ -z "$value" ] && return 1
	printf '%s\n' "$value"
}

has_version_spec() {
	local spec="$1"
	case "$spec" in
		*'<'*|*'>'*|*'='*|*'!'*|*'~'*|*'@'*)
			return 0
			;;
	esac
	return 1
}

normalize_add_arg() {
	local arg="$1"
	case "$arg" in
		*@*)
			local name="${arg%%@*}"
			local spec="${arg#*@}"
			[ -z "$name" ] && printf '%s\n' "$arg" && return
			[ -z "$spec" ] && printf '%s\n' "$arg" && return
			case "$spec" in
				*://*|git+*|ssh+*|file:*)
					printf '%s\n' "$arg"
					return
					;;
			esac
			case "$spec" in
				[\<\>\=\!\~]*)
					printf '%s%s\n' "$name" "$spec"
					;;
				*)
					printf '%s==%s\n' "$name" "$spec"
					;;
			esac
			return
			;;
	esac
	printf '%s\n' "$arg"
}

format_requirement_with_constraint() {
	local original="$1"
	local op="$2"
	local version="$3"
	local name extras
	name="${original%%[*}"
	extras=""
	case "$original" in
		*"["*)
			extras="${original#"$name"}"
			;;
	esac
	printf '%s%s%s%s\n' "$name" "$extras" "$op" "$version"
}

fetch_latest_version() {
	ensure_python
	local requirement="$1"
	local name
	name="${requirement%%[*}"
	if [ -z "$name" ]; then
		die "invalid package name: $requirement"
	fi
	python3 - "$name" <<'PY'
import json
import sys
import urllib.error
import urllib.request

name = sys.argv[1]
url = f"https://pypi.org/pypi/{name}/json"

try:
	with urllib.request.urlopen(url, timeout=15) as resp:
		if resp.status != 200:
			sys.stderr.write(f"px: unable to fetch version for {name} (status {resp.status})\n")
			sys.exit(1)
		data = json.load(resp)
except (urllib.error.URLError, urllib.error.HTTPError) as exc:
	sys.stderr.write(f"px: unable to fetch version for {name}: {exc}\n")
	sys.exit(1)

version = data.get("info", {}).get("version")
if not version:
	sys.stderr.write(f"px: unable to determine latest version for {name}\n")
	sys.exit(1)

print(version)
PY
}

list_project_scripts() {
	_config_read scripts | awk 'NF'
}

list_python_files() {
	local root="$1"
	if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$root" ls-files '*.py' 2>/dev/null
		return
	fi
	if command -v rg >/dev/null 2>&1; then
		(
			cd "$root" 2>/dev/null || return 0
			rg --files -g '*.py' 2>/dev/null
		)
		return
	fi
	(
		cd "$root" 2>/dev/null || return 0
		find . -type f -name '*.py' -print 2>/dev/null | sed 's|^\./||'
	)
}

complete_run_targets() {
	local root="$1"
	if [ -z "$root" ]; then
		return 0
	fi
	{
		list_project_scripts "$root"
		list_python_files "$root"
	} | awk 'NF && !seen[$0]++'
}

cmd_auto_complete() {
	local first="${1:-}"
	local root
	root="$(px_root)"
	if [ -z "$first" ]; then
		printf '%s\n' "init" "install" "run" "start" "exec" "add" "rm" "doctor" "gen"
		return
	fi
	case "$first" in
		run)
			complete_run_targets "$root"
			;;
		add)
			if [ $# -eq 1 ]; then
				printf '%s\n' "--latest" "--compatible"
				return
			fi
			local current="${@: -1}"
			if [ -z "$current" ] || [ "${current#-}" != "$current" ]; then
				printf '%s\n' "--latest" "--compatible"
			fi
			;;
		gen)
			local second="${2:-}"
			if [ -z "$second" ]; then
				printf '%s\n' "completions" "autoactivate"
				return
			fi
			case "$second" in
				completions)
					printf '%s\n' "bash" "fish" "zsh"
					;;
				autoactivate)
					printf '%s\n' "zsh"
					;;
			esac
			;;
	esac
}

_resolve_python() {
	local behavior="$1"
	ensure_python
	if ! config_present; then
		if path=$(command -v python3 2>/dev/null); then
			printf '%s\n' "$path"
			return 0
		fi
		[ "$behavior" = "quiet" ] && return 1
		die "python3 not found; install Python 3 (e.g. via pyenv or your package manager)"
	fi
	ensure_uv
	local constraint path
	constraint="$(cfg python)"
	[ -z "$constraint" ] && constraint="*"
	if path=$(uv python find "$constraint" 2>/dev/null); then
		printf '%s\n' "$path"
		return 0
	fi
	if [ "$constraint" = "*" ]; then
		printf '%s\n' "$(command -v python3)"
		return 0
	fi
	local current
	current="$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)"
	if [ -n "$current" ] && version_satisfies "$current" "$constraint"; then
		printf '%s\n' "$(command -v python3)"
		return 0
	fi
	if command -v pyenv >/dev/null 2>&1; then
		local py
		py=$(printf '%s\n' "$constraint" | grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)
		[ -z "$py" ] && py="3.11"
		pyenv install -s "$py" >/dev/null 2>&1 || true
		if path=$(PYENV_VERSION="$py" pyenv which python3 2>/dev/null); then
			printf '%s\n' "$path"
			return 0
		fi
	fi
	if [ "$behavior" = "quiet" ]; then
		return 1
	fi
	die "cannot satisfy python version constraint: $constraint (install pyenv or adjust python constraint)"
}

resolve_python() {
	_resolve_python "die"
}

try_resolve_python() {
	_resolve_python "quiet"
}

ensure_venv() {
	local py="$1"
	local venv
	venv="$(venv_dir)"
	if [ ! -d "$venv" ]; then
		echo "px: creating venv at $venv"
		"$py" -m venv "$venv"
	fi
}

compute_req_hash() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "no sha256sum or shasum available on PATH"
	fi
}

extract_lock_hash() {
	grep '^# px-lock-sha256:' "$1" 2>/dev/null | awk '{print $3}' || true
}

write_lock_with_hash() {
	local req="$1"
	local lock="$2"
	local tmp hash
	hash=$(compute_req_hash "$req")
	tmp=$(mktemp)
	uv pip compile "$req" -o "$tmp"
	{
		printf '# px-lock-sha256: %s\n' "$hash"
		cat "$tmp"
	} > "$lock"
	rm -f "$tmp"
}

with_venv_env() {
	local venv="$1"
	shift
	VIRTUAL_ENV="$venv" PATH="$venv/bin:$PATH" "$@"
}

detect_shell() {
	local shell="${PX_SHELL:-${SHELL:-}}"
	if [ -z "$shell" ]; then
		echo ""
		return 1
	fi
	shell=$(basename "$shell")
	printf '%s\n' "${shell,,}"
}

resolve_shell_arg() {
	local provided="$1"
	if [ -n "$provided" ]; then
		printf '%s\n' "${provided,,}"
	else
		detect_shell
	fi
}

cmd_init() {
	local target="${1:-.}"
	if [ "$target" != "." ]; then
		mkdir -p "$target"
	fi
	local px_path="$target/px.yaml"
	local req_path="$target/requirements.txt"
	local constraint
	if [ -f "$px_path" ]; then
		die "px.yaml already exists at $target"
	fi
	constraint=$(detect_python_constraint 2>/dev/null || true)
	[ -z "$constraint" ] && constraint=">=3.11,<3.12"
	cat > "$px_path" <<EOF
version: 1
python: "$constraint"
venv_path: ".venv"
requirements: "requirements.txt"
lockfile: "requirements.lock"

scripts:
  start: "python main.py"
EOF
	if [ ! -f "$req_path" ]; then
		touch "$req_path"
	fi
	echo "px: initialized project at $target"
}

cmd_install() {
	local root req lock venv py hash_req hash_lock
	root="$(px_root)"
	req="$root/$(reqfile)"
	lock="$root/$(lockfile)"
	ensure_python
	ensure_pip
	ensure_uv
	py="$(resolve_python)"
	ensure_venv "$py"
	venv="$(venv_dir)"
	if [ ! -f "$req" ]; then
		mkdir -p "$(dirname "$req")"
		touch "$req"
	fi
	if ! grep -q '[^[:space:]]' "$req"; then
		hash_req="$(compute_req_hash "$req")"
		printf '# px-lock-sha256: %s\n' "$hash_req" > "$lock"
		UV_PROJECT_ENVIRONMENT="$venv" UV_PYTHON="$venv/bin/python" uv pip sync --allow-empty-requirements "$lock"
		return
	fi
	hash_req=$(compute_req_hash "$req")
	hash_lock=""
	if [ -f "$lock" ]; then
		hash_lock=$(extract_lock_hash "$lock")
	fi
	if [ -f "$lock" ] && [ "$hash_req" = "$hash_lock" ]; then
		UV_PROJECT_ENVIRONMENT="$venv" UV_PYTHON="$venv/bin/python" uv pip sync "$lock"
		return
	fi
	write_lock_with_hash "$req" "$lock"
	UV_PROJECT_ENVIRONMENT="$venv" UV_PYTHON="$venv/bin/python" uv pip sync "$lock"
}

cmd_exec() {
	local venv
	venv="$(venv_dir)"
	[ $# -gt 0 ] || die "exec <command>"
	[ -d "$venv/bin" ] || die "environment not installed (run: px install)"
	with_venv_env "$venv" "$@"
}

cmd_run() {
	local root venv bin name target script entrypoint
	root="$(px_root)"
	venv="$root/$(venv_path)"
	bin="$venv/bin"
	[ -d "$bin" ] || die "environment not installed (run: px install)"
	[ $# -gt 0 ] || die "run <script-name|path.py|-> [args...]"
	name="$1"
	shift || true
	script=$(script_command "$root" "$name" || true)
	if [ -n "$script" ]; then
		PX_SCRIPT=$script with_venv_env "$venv" sh -c 'eval "$PX_SCRIPT" "$@"' "$name" "$@"
		return
	fi
	if [ "$name" = "-" ]; then
		with_venv_env "$venv" "$bin/python" - "$@"
		return
	fi
	target="$name"
	if [ ! -f "$target" ] && [ -f "$root/$target" ]; then
		target="$root/$target"
	fi
	if [ -f "$target" ]; then
		case "$target" in
			*.py)
				with_venv_env "$venv" "$bin/python" "$target" "$@"
				return
				;;
		esac
		if head -n 1 "$target" | grep -q '^#!.*python'; then
			with_venv_env "$venv" "$target" "$@"
			return
		fi
	fi
	if [ "$name" = "start" ]; then
		entrypoint=$(cfg entrypoint)
		if [ -n "$entrypoint" ]; then
			PX_ENTRYPOINT=$entrypoint with_venv_env "$venv" sh -c 'eval "$PX_ENTRYPOINT" "$@"' start "$@"
			return
		fi
		die "no scripts.start or entrypoint configured"
	fi
	die "unknown script or file: $name"
}

cmd_add() {
	local mode="raw"
	while [ $# -gt 0 ]; do
		case "$1" in
			--latest|--exact)
				mode="exact"
				shift
				;;
			--compatible)
				mode="compatible"
				shift
				;;
			--)
				shift
				break
				;;
			-*)
				die "unknown add flag: $1"
				;;
			*)
				break
				;;
		esac
	done
	[ $# -gt 0 ] || die "add [--latest|--compatible] <pkg...>"
	local root req pkg added entry version
	root="$(px_root)"
	req="$root/$(reqfile)"
	ensure_uv
	if [ ! -f "$req" ]; then
		mkdir -p "$(dirname "$req")"
		touch "$req"
	fi
	added=0
	for pkg in "$@"; do
		case "$pkg" in
			--latest|--exact|--compatible)
				die "add flags must appear before package names (move $pkg earlier)"
				;;
		esac
		entry="$(normalize_add_arg "$pkg")"
		if [ "$mode" != "raw" ] && ! has_version_spec "$entry"; then
			if ! version=$(fetch_latest_version "$entry"); then
				die "unable to determine latest version for $pkg"
			fi
			case "$mode" in
				exact)
					entry=$(format_requirement_with_constraint "$entry" "==" "$version")
					;;
				compatible)
					entry=$(format_requirement_with_constraint "$entry" "~=" "$version")
					;;
			esac
			echo "px: resolved $pkg -> $entry"
		fi
		if grep -Fxq -- "$entry" "$req"; then
			continue
		fi
		printf '%s\n' "$entry" >> "$req"
		added=1
	done
	if [ "$added" -eq 0 ]; then
		echo "px: dependencies already present in $(reqfile)" >&2
	fi
	cmd_install
}

cmd_rm() {
	[ $# -gt 0 ] || die "rm <pkg...>"
	local root req tmp pkg removed
	root="$(px_root)"
	req="$root/$(reqfile)"
	ensure_uv
	if [ ! -f "$req" ]; then
		mkdir -p "$(dirname "$req")"
		touch "$req"
	fi
	tmp=$(mktemp)
	cp "$req" "$tmp"
	removed=0
	for pkg in "$@"; do
		if grep -Fxq -- "$pkg" "$tmp"; then
			if ! grep -Fxv -- "$pkg" "$tmp" > "${tmp}.next"; then
				: > "${tmp}.next"
			fi
			mv "${tmp}.next" "$tmp"
			removed=1
		fi
	done
	if [ "$removed" -eq 0 ]; then
		rm -f "$tmp"
		die "no matching dependencies found in $(reqfile)"
	fi
	mv "$tmp" "$req"
	cmd_install
}

cmd_gen_completions_zsh() {
	cat <<'EOF'
# zsh completion for px
_px_complete_bridge() {
	local out
	out="$(px ---complete "$@")" || return 0
	local -a entries
	entries=(${(f)out})
	(( ${#entries[@]} )) || return 0
	compadd -a -- entries
}
_pxc() {
	zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
	_arguments '1: :->a1' '2: :->a2' '3: :->a3' '4: :->a4' '5: :->a5'
	case "$state" in
		a1) _px_complete_bridge ;;
		a2) _px_complete_bridge "$words[2]" ;;
		a3) _px_complete_bridge "$words[2]" "$words[3]" ;;
		a4) _px_complete_bridge "$words[2]" "$words[3]" "$words[4]" ;;
		a5) _px_complete_bridge "$words[2]" "$words[3]" "$words[4]" "$words[5]" ;;
	esac
}
compdef _pxc px
EOF
}

cmd_gen_completions_bash() {
	cat <<'EOF'
# bash completion for px
_px_complete() {
	local words=("${COMP_WORDS[@]:1}")
	local out
	out="$(px ---complete "${words[@]}")" || return 0
	COMPREPLY=()
	[ -n "$out" ] || return 0
	while IFS= read -r line; do
		COMPREPLY+=("$line")
	done <<<"$out"
}
complete -F _px_complete px
EOF
}

cmd_gen_completions_fish() {
	cat <<'EOF'
function __px_complete
	set -l tokens (commandline -opc)
	if test (count $tokens) -gt 0
		set -e tokens[1]
	end
	if test (count $tokens) -eq 0
		px ---complete
	else
		px ---complete $tokens
	end
end

complete -c px -f -a "(__px_complete)"
EOF
}

cmd_gen_autoactivate_zsh() {
	cat <<'EOF'
# auto-add .venv/bin to PATH when entering a directory with px.yaml
px_yaml_venv_path() {
	local file="$1/px.yaml"
	if [ ! -f "$file" ]; then
		printf '.venv\n'
		return
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		printf '.venv\n'
		return
	fi
	local value
	value=$(python3 - "$file" <<'PY'
import ast
import sys

path = sys.argv[1]

def parse(path):
	try:
		with open(path, "r", encoding="utf-8") as fh:
			for raw in fh:
				line = raw.rstrip("\n")
				if not line.strip() or line.lstrip().startswith("#"):
					continue
				if ":" not in line:
					continue
				key, val = line.split(":", 1)
				if key.strip() == "venv_path":
					val = val.strip()
					if not val:
						return ".venv"
					if val[0] in "\"'" and val[-1] == val[0]:
						try:
							return str(ast.literal_eval(val))
						except Exception:
							return val[1:-1]
					return val
	except FileNotFoundError:
		return ".venv"
	return ".venv"

print(parse(path))
PY
	)
	[ -z "$value" ] && value=".venv"
	printf '%s\n' "$value"
}

px_auto() {
	if [ -z "${PX_AUTO_ORIG_PATH:-}" ]; then
		PX_AUTO_ORIG_PATH="$PATH"
	fi
	local base="$PX_AUTO_ORIG_PATH"
	local d="$PWD"
	PATH="$base"
	unset VIRTUAL_ENV
	while [ "$d" != "/" ]; do
		if [ -f "$d/px.yaml" ]; then
			local venv
			venv=$(px_yaml_venv_path "$d")
			local envdir="$d/$venv"
			if [ -d "$envdir/bin" ]; then
				case ":$PATH:" in
					*":$envdir/bin:"*) ;;
					*) PATH="$envdir/bin:$PATH";;
				esac
				export VIRTUAL_ENV="$envdir"
				export PATH
			fi
			return
		fi
		d="$(dirname "$d")"
	done
	export PATH="$base"
	unset VIRTUAL_ENV
}
autoload -U add-zsh-hook
add-zsh-hook chpwd px_auto
px_auto
EOF
}

resolve_install_path() {
	local from_path
	from_path=$(command -v px 2>/dev/null || true)
	if [ -n "$from_path" ] && [ -w "$from_path" ]; then
		printf '%s\n' "$from_path"
		return 0
	fi
	local self="$0"
	case "$self" in
		/*) ;;
		*) self="$PWD/$self";;
	esac
	if [ -w "$self" ]; then
		printf '%s\n' "$self"
		return 0
	fi
	die "unable to determine writable px path (rerun make install)"
}

cmd_doctor() {
	local root req lock venv constraint resolved hash_req hash_lock cfg_path has_config sys_python
	root="$(px_root)"
	req="$root/$(reqfile)"
	lock="$root/$(lockfile)"
	venv="$(venv_dir)"
	cfg_path="$(config_file)"
	if [ -f "$cfg_path" ]; then
		has_config=1
	else
		has_config=0
	fi
	if [ "$has_config" -eq 1 ]; then
		constraint="$(cfg python)"
		[ -z "$constraint" ] && constraint="(not set)"
	else
		constraint="(px.yaml not found)"
	fi
	echo "root: $root"
	echo "python constraint: $constraint"
	if [ "$has_config" -eq 0 ]; then
		sys_python=$(command -v python3 2>/dev/null || true)
		if [ -n "$sys_python" ]; then
			echo "python resolved: using system python3 ($sys_python)"
		else
			echo "python resolved: using system python3 (unavailable)"
		fi
	elif resolved=$(try_resolve_python 2>/dev/null); then
		echo "python resolved: $resolved"
	else
		echo "python resolved: (unavailable)"
	fi
	if [ -d "$venv/bin" ]; then
		echo "venv: present ($venv)"
	else
		echo "venv: missing ($venv)"
	fi
	if [ -f "$req" ]; then
		hash_req=$(compute_req_hash "$req")
		echo "requirements: present ($(basename "$req"))"
	else
		hash_req=""
		echo "requirements: missing ($(reqfile))"
	fi
	if [ -f "$lock" ]; then
		hash_lock=$(extract_lock_hash "$lock")
		echo "lockfile: present ($(basename "$lock"))"
	else
		hash_lock=""
		echo "lockfile: missing ($(lockfile))"
	fi
	if [ -n "$hash_req" ] && [ -n "$hash_lock" ] && [ "$hash_req" = "$hash_lock" ]; then
		echo "sync: up-to-date"
	elif [ -n "$hash_req" ] && [ -n "$hash_lock" ]; then
		echo "sync: out-of-date (run: px install)"
	else
		echo "sync: unavailable (run: px install)"
	fi
}

cmd_start() {
	cmd_run start "$@"
}

main() {
	case "${1:-}" in
		---complete)
			shift || true
			cmd_auto_complete "$@"
			exit 0
			;;
		--help|-h)
			usage
			exit 0
			;;
		--version)
			echo "px $CURRENT_VERSION"
			exit 0
			;;
		init)
			shift
			cmd_init "$@"
			;;
		install)
			shift
			cmd_install "$@"
			;;
		run)
			shift
			cmd_run "$@"
			;;
		start)
			shift
			cmd_start "$@"
			;;
		exec)
			shift
			cmd_exec "$@"
			;;
		add)
			shift
			cmd_add "$@"
			;;
		rm)
			shift
			cmd_rm "$@"
			;;
		doctor)
			shift
			cmd_doctor "$@"
			;;
		gen)
			shift
			local sub="${1:-}"
			case "$sub" in
				completions)
					shift
					local shell
					shell=$(resolve_shell_arg "${1:-}")
				if [ -z "$shell" ]; then
					die "unable to detect shell; pass it explicitly (e.g. px gen completions zsh)"
				fi
				[ -n "${1:-}" ] && shift
				case "$shell" in
					bash) cmd_gen_completions_bash ;;
					fish) cmd_gen_completions_fish ;;
					zsh) cmd_gen_completions_zsh ;;
					*) die "completions for shell '$shell' not supported (supported: bash, fish, zsh)" ;;
				esac
				;;
				autoactivate)
					shift
					local shell
					shell=$(resolve_shell_arg "${1:-}")
					if [ -z "$shell" ]; then
						die "unable to detect shell; pass it explicitly (e.g. px gen autoactivate zsh)"
					fi
					[ -n "${1:-}" ] && shift
					case "$shell" in
						zsh) cmd_gen_autoactivate_zsh ;;
						*) die "autoactivate hook for shell '$shell' not supported (supported: zsh)" ;;
					esac
					;;
				*)
					die "gen <completions|autoactivate> [shell]"
					;;
			esac
			;;
		*)
			usage
			exit 1
			;;
	esac
}

set_current_version

main "$@"

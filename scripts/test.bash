#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
usage: scripts/test.bash [--dir <path>]

Options:
	--dir <path>	Directory to use for the test run (default: .dev/test-bench/workdir)
EOF
}

log() {
	printf '[px:test] %s\n' "$1"
}

run_cmd() {
	printf '>>> %s\n' "$*"
	"$@"
}

ensure_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "scripts/test.bash: missing required command: $1" >&2
		exit 1
	}
}

prepare_workdir() {
	workdir="$1"
	case "$workdir" in
		.dev/test-bench/*) ;;
		*)
			echo "scripts/test.bash: refusing to use unsafe directory: $workdir" >&2
			exit 1
			;;
	esac
	rm -rf "$workdir"
	mkdir -p "$workdir"
}

main() {
	workdir=".dev/test-bench/workdir"
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--dir)
				shift
				[ "$#" -gt 0 ] || { echo "scripts/test.bash: --dir requires a path" >&2; exit 1; }
				workdir="$1"
				shift
				;;
			--help|-h)
				usage
				exit 0
				;;
			*)
				echo "scripts/test.bash: unknown option: $1" >&2
				usage >&2
				exit 1
				;;
		esac
		done
	ensure_cmd python3
	python3 -m pip --version >/dev/null 2>&1 || { echo "scripts/test.bash: python3 -m pip not available" >&2; exit 1; }
	ensure_cmd pyenv
	ensure_cmd uv
	prepare_workdir "$workdir"
	cp px.bash "$workdir/px"
	chmod +x "$workdir/px"
	log "using workdir $workdir"
	(
		cd "$workdir"
		run_cmd ./px init
		cat > main.py <<'PY'
print("hello from px")
PY
		log "creating virtualenv and installing dependencies"
		run_cmd ./px install
		log "running px start"
		run_cmd ./px start
		log "running inline Python via px run -"
		run_cmd ./px run - <<'EOF'
print('inline run works')
EOF
		log "running px run with quoted script"
		cat >> px.yaml <<'EOF'
  inline: "python -c \"print('inline ok')\""
EOF
		run_cmd ./px run inline
		log "adding requests dependency"
		run_cmd ./px add requests
		log "verifying dependency lockfile"
		[ -s requirements.lock ] || { echo "lockfile not generated" >&2; exit 1; }
		log "executing python inside env"
		run_cmd ./px exec python -c "import requests, sys; sys.stdout.write('requests ok\n')"
		log "removing dependency"
		run_cmd ./px rm requests
	)
	log "tests completed"
}

main "$@"

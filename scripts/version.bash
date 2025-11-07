#!/usr/bin/env bash

set -eo pipefail
# set -e -> exit if any command has a non-zero exit status
# set -u -> reference to any undefined variable is an error
# set -x -> print all executed commands to the terminal
# set -o pipefail -> prevents errors in a pipeline from being masked

here="$(dirname "$(readlink -f "$0")")"

main() {
	if ! in_git_root; then
		throw "not in a git repository"
	fi

	local version="$(has_tag && get_tag_version || get_unknown_version)"
	local full_version="${version}$(has_changes && echo "++")"
	local short_version=$(echo "$full_version" | perl -pe 's/^(\d+\.\d+\.\d+)([^\d].*)?$/$1/')

	echo "$short_version"
}

throw() {
	echo "error: $1" >&2
	exit 1
}

in_git_root() {
	git rev-parse --is-inside-work-tree >/dev/null 2>/dev/null
}

has_tag() {
	git describe >/dev/null 2>&1
}

has_changes() {
	[ "$(git status --porcelain | wc -l)" -gt 0 ]
}

# get the version tag
#
# format:
#     <major>.<minor>.<patch>[-<label>][+<commits_ahead>-<last_commit>[++]]
#
# for 0.X version tags (without patch), the format is the following:
#     0.<dev_major>.<commits_ahead>[-<label>][+0-<last_commit>[++]]
#
get_tag_version() {
	git describe --always \
		| perl -pe 's/^v//' \
		| perl -pe 's/^0\.(\d+)(-[a-zA-Z]+[a-zA-Z0-9]*)?$/0.$1.0$2/' \
		| perl -pe 's/^0\.(\d+)(-[a-zA-Z]+[a-zA-Z0-9]*)?-(\d+)-/0.$1.$3$2-0-/' \
		| perl -pe 's/^(\d+\.\d+\.\d+)(-[a-zA-Z]+[a-zA-Z0-9]*)?-(\d+)-/$1$2+$3-/'
}

get_unknown_version() {
	git describe --always | perl -pe 's/^/0.0.0+unknown-/'
}

main "$@"

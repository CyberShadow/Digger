#!/bin/bash
set -euo pipefail

# Globals

uname="$(uname)"

# Setup / cleanup

function init() {
	cd "$(dirname "$0")"

	echo "local.workDir = work/" > ./digger.ini
	echo "local.cache = git" >> ./digger.ini
	echo "local.makeJobs = auto" >> ./digger.ini

	rm -rf digger work
	( shopt -s nullglob; rm -f ./*.lst )
}

# Common functions

function build() {
	DFLAGS=(-cov -debug -g '-version=test')
	rdmd --build-only "${DFLAGS[@]}" "$@" -of./digger ../digger.d
}

function clean() {
	pushd work/repo/
	git submodule foreach git reset --hard
	git submodule foreach git clean -fdx
	popd
}

function digger() {
	if [[ ! -x ./digger ]] ; then build ; fi
	./digger --config-file ./digger.ini "$@"
}

# Test building digger-web

function test_diggerweb() {
	rdmd --build-only -of./digger-web ../digger-web.d
}

# Run unittests

function test_unit() {
	rm -f ./digger
	build -unittest
	./digger build --help
	rm ./digger
}

# Simple build

function test_build() {
	digger build "master @ 2016-01-01 00:00:00"

	work/result/bin/dmd -run issue15914.d
}

# Run tests

function test_testsuite() {
	digger build "master @ 2016-01-01 00:00:00"

	clean # Clean everything to test correct test dependencies

	test_args=('--with=phobos' '--with=tools')
	if [[ "$uname" == "Darwin" ]]
	then
		# TODO, rdmd bug: https://travis-ci.org/CyberShadow/Digger/jobs/124429436
		test_args+=('--without=rdmd')
	fi
	if [[ "${APPVEYOR:-}" == "True" ]]
	then
		# MSYS downloads fail on AppVeyor (bandwidth quota exceeded?)
		test_args+=('--without=dmd')
		# TODO, Druntime tests segfault on AppVeyor
		test_args+=('--without=druntime')
	fi

	if [[ "$uname" == *_NT-* ]]
	then
		# Test 64-bit on Windows too
		digger test "${test_args[@]}" --model=64
		clean # Needed to rebuild zlib for correct model
		# Build 64-bit first so we leave behind 32-bit C++ object files,
		# so that the rebuild action below succeeds.
	fi

	digger test "${test_args[@]}"
}

# Caching

function test_cache() {
	digger build "master @ 2016-01-01 00:00:00"

	digger --offline build "master @ 2016-01-01 00:00:00" 2>&1 | tee digger.log
	! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
	grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log
}

# Caching unbuildable versions

function test_cache_error() {
	! digger build "master @ 2010-01-01 00:00:00"

	! digger --offline build "master @ 2010-01-01 00:00:00" 2>&1 | tee digger.log
	! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
	grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log
	grep --quiet --fixed-strings 'was cached as unbuildable' digger.log
}

# Rebuild

function test_rebuild() {
	digger checkout "master @ 2016-01-01 00:00:00"
	digger build "master @ 2016-01-01 00:00:00"

	# No changes

	digger rebuild
	work/result/bin/dmd -run issue15914.d

	# With changes

	pushd work/repo/phobos/
	git cherry-pick --no-commit ad226e92d5f092df233b90fd3fdedb8b71d728eb
	popd

	digger rebuild
	! work/result/bin/dmd -run issue15914.d

	rm work/repo/.git/modules/phobos/ae-sys-d-worktree.json
}

# Working tree state

function test_worktree() {
	digger checkout "master @ 2016-01-01 00:00:00"

	pushd work/repo/phobos/
	git cherry-pick --no-commit ad226e92d5f092df233b90fd3fdedb8b71d728eb
	popd

	! digger build "master @ 2016-04-01 00:00:00" # Worktree is dirty - should fail
	rm work/repo/.git/modules/phobos/ae-sys-d-worktree.json
	  digger build "master @ 2016-04-01 00:00:00" # Should work now
	! work/result/bin/dmd -run issue15914.d
}

# Merging

function test_merge() {
	digger build "master @ 2016-01-01 00:00:00 + phobos#3859"
	! work/result/bin/dmd -run issue15914.d

	# Test cache

	digger --offline build "master @ 2016-01-01 00:00:00 + phobos#3859" 2>&1 | tee digger.log
	! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
	! grep --quiet --fixed-strings --line-regexp 'digger: Merging phobos commit ad226e92d5f092df233b90fd3fdedb8b71d728eb' digger.log
	grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log
}

# Reverting

function test_revert() {
	digger --offline build "master @ 2016-04-01 00:00:00 + -phobos#3859"
	work/result/bin/dmd -run issue15914.d
}

# Bisecting

function test_bisect() {
	cat > bisect.ini <<EOF
bad  = master @ 2016-02-19 00:00:00
good = master @ 2016-02-18 00:00:00
tester = dmd -run issue15914.d
local.makeJobs = auto
EOF

	digger --offline bisect ./bisect.ini 2>&1 | tee digger.log

	if [[ "$uname" == *_NT-* ]]
	then
		# Digger outputs \r\n newlines in its log output on Windows, filter those out before diffing
		diff <(tail -n 19 digger.log | sed 's/\r//' | grep -v '^index ') issue15914-bisect.log
	else
		# OS X doesn't support the \r escape
		diff <(tail -n 19 digger.log                | grep -v '^index ') issue15914-bisect.log
	fi
}

# Test dmdModel

function test_dmdmodel() {
	if [[ "$uname" == *_NT-* ]]
	then
		digger -c build.components.dmd.dmdModel=64       build "master@2016-04-01+dmd#5694"
		digger -c build.components.dmd.dmdModel=32mscoff build "master@2016-04-01+dmd#5694"
	fi
}

# Build test - stable @ 2015-09-01 00:00:00 (Phobos can't find Druntime .a / .so by default)

function test_2015_09_01() {
	if [[ ! "$uname" == *_NT-* ]]
	then
		digger build "stable @ 2015-09-01 00:00:00"
	fi
}

# The test runner

function run_tests() {
	init

	for t in "$@"
	do
		echo "=== Running test $t ==="
		( set -x ; "test_$t" )
		echo "=== Test $t OK! ==="
	done

	echo -e "==================================================================\nAll tests OK!"
}

# Main function

function main() {
	all_tests=(
		diggerweb
		unit
		build
		testsuite
		cache
		cache_error
		rebuild
		worktree
		merge
		revert
		bisect
		dmdmodel
		2015_09_01
	)

	if [[ $# -eq 0 ]]
	then
		run_tests "${all_tests[@]}"
	else
		run_tests "$@"
	fi
}

main "$@"

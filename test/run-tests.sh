#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

uname="$(uname)"

echo "local.workDir = work/" > ./digger.ini
echo "local.cache = git" >> ./digger.ini
echo "local.makeJobs = auto" >> ./digger.ini

rm -rf work
( shopt -s nullglob; rm -f ./*.lst )

# Test building digger-web

rdmd --build-only -of./digger-web ../digger-web.d

# Run unittests

DFLAGS=(-cov -debug -g -version=test)

rdmd --build-only "${DFLAGS[@]}" -unittest -of./digger ../digger.d
./digger build --help

rdmd --build-only "${DFLAGS[@]}" -of./digger ../digger.d

# Simple build

./digger --config-file ./digger.ini build "master @ 2016-01-01 00:00:00"
work/result/bin/dmd -run issue15914.d

# Run tests

function clean {
	pushd work/repo/
	git submodule foreach git reset --hard
	git submodule foreach git clean -fdx
	popd
}
clean # Clean everything to test correct test dependencies

TEST_ARGS=('--with=phobos' '--with=tools')
if [[ "$uname" == "Darwin" ]]
then
	# TODO, rdmd bug: https://travis-ci.org/CyberShadow/Digger/jobs/124429436
	TEST_ARGS+=('--without=rdmd')
fi
if [[ "${APPVEYOR:-}" == "True" ]]
then
	# MSYS downloads fail on AppVeyor (bandwidth quota exceeded?)
	TEST_ARGS+=('--without=dmd')
	# TODO, Druntime tests segfault on AppVeyor
	TEST_ARGS+=('--without=druntime')
fi

if [[ "$uname" == *_NT-* ]]
then
	# Test 64-bit on Windows too
	./digger --config-file ./digger.ini test "${TEST_ARGS[@]}" --model=64
	clean # Needed to rebuild zlib for correct model
	# Build 64-bit first so we leave behind 32-bit C++ object files,
	# so that the rebuild action below succeeds.
fi

./digger --config-file ./digger.ini test "${TEST_ARGS[@]}"

# Caching

./digger --config-file ./digger.ini --offline build "master @ 2016-01-01 00:00:00" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Rebuild - no changes

./digger --config-file ./digger.ini rebuild
work/result/bin/dmd -run issue15914.d

# Rebuild - with changes

pushd work/repo/phobos/
git cherry-pick --no-commit ad226e92d5f092df233b90fd3fdedb8b71d728eb
popd

./digger --config-file ./digger.ini rebuild
! work/result/bin/dmd -run issue15914.d

# Working tree state

! ./digger --config-file ./digger.ini build "master @ 2016-04-01 00:00:00" # Worktree is dirty - should fail
rm work/repo/.git/modules/phobos/ae-sys-d-worktree.json
  ./digger --config-file ./digger.ini build "master @ 2016-04-01 00:00:00" # Should work now
! work/result/bin/dmd -run issue15914.d

# Merging

./digger --config-file ./digger.ini build "master @ 2016-01-01 00:00:00 + phobos#3859"
! work/result/bin/dmd -run issue15914.d

# Cached merging

./digger --config-file ./digger.ini --offline build "master @ 2016-01-01 00:00:00 + phobos#3859" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Merging phobos commit ad226e92d5f092df233b90fd3fdedb8b71d728eb' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Reverting

./digger --config-file ./digger.ini --offline build "master @ 2016-04-01 00:00:00 + -phobos#3859"
work/result/bin/dmd -run issue15914.d

# Bisecting

cat > bisect.ini <<EOF
bad  = master @ 2016-02-19 00:00:00
good = master @ 2016-02-18 00:00:00
tester = dmd -run issue15914.d
local.makeJobs = auto
EOF

./digger --config-file ./digger.ini --offline bisect ./bisect.ini 2>&1 | tee digger.log

if [[ "$uname" == *_NT-* ]]
then
	# Digger outputs \r\n newlines in its log output on Windows, filter those out before diffing
	diff <(tail -n 19 digger.log | sed 's/\r//' | grep -v '^index ') issue15914-bisect.log
else
	# OS X doesn't support the \r escape
	diff <(tail -n 19 digger.log                | grep -v '^index ') issue15914-bisect.log
fi

# Test dmdModel

if [[ "$uname" == *_NT-* ]]
then
	./digger --config-file ./digger.ini -c build.components.dmd.dmdModel=64       build "master@2016-04-01+dmd#5694"
	./digger --config-file ./digger.ini -c build.components.dmd.dmdModel=32mscoff build "master@2016-04-01+dmd#5694"
fi

# Build test - stable @ 2015-09-01 00:00:00 (Phobos can't find Druntime .a / .so by default)

if [[ ! "$uname" == *_NT-* ]]
then
	./digger --config-file ./digger.ini build "stable @ 2015-09-01 00:00:00"
fi

# Done!

echo -e "==================================================================\nAll tests OK!"

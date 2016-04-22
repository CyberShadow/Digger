#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

UNAME="$(uname)"

echo "workDir = work/" > ./digger.ini
echo "cache = git" >> ./digger.ini

rm -rf work
( shopt -s nullglob; rm -f ./*.lst )

# Run unittests

rdmd --build-only -cov -debug -g -unittest -of./digger ../digger.d
./digger build --help

rdmd --build-only -cov -debug -g -of./digger ../digger.d

# Simple build

./digger --config-file ./digger.ini build --jobs=auto "master @ 2016-01-01 00:00:00"
work/result/bin/dmd -run issue15914.d

# Run tests

pushd work/repo/ # Clean everything to test correct test dependencies
git submodule foreach git reset --hard
git submodule foreach git clean -fdx
popd

TEST_ARGS=('--without=dmd') # Without DMD as that takes too long and is too fragile
if [[ "$UNAME" == "Darwin" ]]
then
	# TODO, rdmd bug: https://travis-ci.org/CyberShadow/Digger/jobs/124429436
	TEST_ARGS+=('--without=rdmd')
fi
if [[ "${APPVEYOR:-}" == "True" ]]
then
	# TODO, Druntime tests segfault on AppVeyor
	TEST_ARGS+=('--without=druntime')
fi
./digger --config-file ./digger.ini test "${TEST_ARGS[@]}" --jobs=auto

if [[ "$UNAME" == *_NT-* ]]
then
	# Test 64-bit on Windows too
	./digger --config-file ./digger.ini test "${TEST_ARGS[@]}" --model=64
fi

# Caching

./digger --config-file ./digger.ini --offline build --jobs=auto "master @ 2016-01-01 00:00:00" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Rebuild - no changes

./digger --config-file ./digger.ini rebuild --jobs=auto
work/result/bin/dmd -run issue15914.d

# Rebuild - with changes

pushd work/repo/phobos/
git cherry-pick --no-commit ad226e92d5f092df233b90fd3fdedb8b71d728eb
popd

./digger --config-file ./digger.ini rebuild --jobs=auto
! work/result/bin/dmd -run issue15914.d

# Working tree state

! ./digger --config-file ./digger.ini build --jobs=auto "master @ 2016-04-01 00:00:00" # Worktree is dirty - should fail
rm work/repo/.git/modules/phobos/ae-sys-d-worktree.json
  ./digger --config-file ./digger.ini build --jobs=auto "master @ 2016-04-01 00:00:00" # Should work now
! work/result/bin/dmd -run issue15914.d

# Merging

./digger --config-file ./digger.ini build --jobs=auto "master @ 2016-01-01 00:00:00 + phobos#3859"
! work/result/bin/dmd -run issue15914.d

# Cached merging

./digger --config-file ./digger.ini --offline build --jobs=auto "master @ 2016-01-01 00:00:00 + phobos#3859" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Merging phobos commit ad226e92d5f092df233b90fd3fdedb8b71d728eb' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Reverting

./digger --config-file ./digger.ini --offline build --jobs=auto "master @ 2016-04-01 00:00:00 + -phobos#3859"
work/result/bin/dmd -run issue15914.d

# Bisecting

cat > bisect.ini <<EOF
bad  = master @ 2016-02-19 00:00:00
good = master @ 2016-02-18 00:00:00
tester = dmd -run issue15914.d
build.components.common.makeJobs = auto
EOF

./digger --config-file ./digger.ini --offline bisect ./bisect.ini 2>&1 | tee digger.log

if [[ "$UNAME" == *_NT-* ]]
then
	# Digger outputs \r\n newlines in its log output on Windows, filter those out before diffing
	diff <(tail -n 19 digger.log | sed 's/\r//') issue15914-bisect.log
else
	# OS X doesn't support the \r escape
	diff <(tail -n 19 digger.log) issue15914-bisect.log
fi

# Done!

echo -e "==================================================================\nAll tests OK!"

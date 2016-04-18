#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

CPUCOUNT="$(getconf _NPROCESSORS_ONLN)"

echo "workDir = $(pwd)/work/" > ./digger.ini
echo "cache = git" >> ./digger.ini

rm -rf work
find -maxdepth 1 -name '*.lst' -delete

# Run unittests

rdmd --build-only -cov -debug -g -unittest -of./digger ../digger.d
./digger build --help

rdmd --build-only -cov -debug -g -of./digger ../digger.d

# Simple build

./digger --config-file ./digger.ini build --make-args=-j"$CPUCOUNT" "master @ 2016-01-01 00:00:00"
work/result/bin/dmd -run issue15914.d

# Caching

./digger --config-file ./digger.ini --offline build --make-args=-j"$CPUCOUNT" "master @ 2016-01-01 00:00:00" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Merging

./digger --config-file ./digger.ini build --make-args=-j"$CPUCOUNT" "master @ 2016-01-01 00:00:00 + phobos#3859"
! work/result/bin/dmd -run issue15914.d

# Cached merging

./digger --config-file ./digger.ini build --make-args=-j"$CPUCOUNT" "master @ 2016-01-01 00:00:00 + phobos#3859" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Merging phobos commit ad226e92d5f092df233b90fd3fdedb8b71d728eb' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Reverting

./digger --config-file ./digger.ini --offline build --make-args=-j"$CPUCOUNT" "master @ 2016-04-01 00:00:00 + -phobos#3859"
work/result/bin/dmd -run issue15914.d

# Bisecting

cat > bisect.ini <<EOF
bad  = master @ 2016-04-01
good = master @ 2016-01-01
tester = dmd -run issue15914.d
build.components.common.makeArgs = ["-j$CPUCOUNT"]
EOF

./digger --config-file ./digger.ini --offline bisect ./bisect.ini 2>&1 | tee digger.log
diff <(tail -n 19 digger.log) issue15914-bisect.log

# Done!

echo -e "==================================================================\nAll tests OK!"
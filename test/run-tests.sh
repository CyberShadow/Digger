#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

echo "workDir = $(pwd)/work/" > ./digger.ini
echo "cache = git" >> ./digger.ini

rm -rf work
find -maxdepth 1 -name '*.lst' -delete

# Run unittests

rdmd --build-only -cov -g -unittest -of./digger ../digger.d
./digger build --help

rdmd --build-only -cov -g -of./digger ../digger.d

# Simple build

./digger --config-file ./digger.ini build "master @ 2016-01-01 00:00:00"
work/result/bin/dmd -run issue15914.d

# Caching

./digger --config-file ./digger.ini --offline build "master @ 2016-01-01 00:00:00" 2>&1 | tee digger.log
! grep --quiet --fixed-strings --line-regexp 'digger: Cache miss.' digger.log
grep --quiet --fixed-strings --line-regexp 'digger: Cache hit!' digger.log

# Merging

./digger --config-file ./digger.ini --offline build "master @ 2016-01-01 00:00:00 + phobos#3859"
! work/result/bin/dmd -run issue15914.d

# Reverting

./digger --config-file ./digger.ini --offline build "master @ 2016-04-01 00:00:00 + -phobos#3859"
work/result/bin/dmd -run issue15914.d

# Bisecting

echo 'bad  = master @ 2016-04-01' >  bisect.ini
echo 'good = master @ 2016-01-01' >> bisect.ini
echo 'tester = dmd -run issue15914.d' >> bisect.ini

./digger --config-file ./digger.ini --offline bisect ./bisect.ini 2>&1 | tee digger.log
diff <(tail -n 19 digger.log) issue15914-bisect.log

# Done!

echo -e "==================================================================\nAll tests OK!"

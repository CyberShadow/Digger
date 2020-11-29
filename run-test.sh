#!/bin/bash
set -eu

echo 'run-test.sh  start'
c++ -ldl test.cpp
echo 'run-test.sh  end'
ls -al

#!/bin/bash
set -eu

echo 'run-test.sh  start'
c++ test.cpp
echo 'run-test.sh  end'
ls -al

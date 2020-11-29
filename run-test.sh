#!/bin/bash
set -x

cc -ldl test.c
cc test.c
ls -al

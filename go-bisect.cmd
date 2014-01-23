@echo off

call go-bisect-conf.cmd

cd repo

call git bisect reset
if errorlevel 1 exit 1
call git bisect start "%BAD%" "%GOOD%"
if errorlevel 1 exit 1
call git bisect run cmd /c "%CD%\..\_bisect-run-test.cmd %TESTER%"
if errorlevel 1 exit 1

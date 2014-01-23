@echo off

cd /D %~dp0
cd repo
call git submodule update
cd ..

call build-all
if errorlevel 1 exit /B 125

call %*

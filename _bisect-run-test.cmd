@echo off

cd /D %~dp0
cd repo
call git submodule update
cd ..

call build-all
if errorlevel 1 exit /B 125

set PATH=C:\Windows;C:\Windows\System32;C:\Soft\Tools
set PATH=%~dp0\out\windows\bin;\dm\bin;%PATH%
cd %~dp1
call %*

@echo on

cd /D %~dp1
%~dp0\out\windows\bin\dmd.exe -m%DMODEL% %*

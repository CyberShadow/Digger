@echo on

cd /D %~dp1
%~dp0\current\windows\bin\dmd.exe -m%DMODEL% %*

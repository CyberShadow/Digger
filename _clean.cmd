@echo off

rm -rf out

cd repo

for /D %%a in (*) do (
  cd %%a
  git clean -fxd
  cd ..
)

cd ..

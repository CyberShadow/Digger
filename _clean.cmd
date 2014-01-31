@echo off

rm -rf build

cd repo

for /D %%a in (*) do (
  cd %%a
  git clean -fxd
  cd ..
)

cd ..

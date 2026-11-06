@echo off
rem bin\veritas-dev.bat — the operator's entry point in a **checkout**, on
rem Windows.
rem
rem The commands themselves are Mix tasks (`mix veritas.cli`, `mix veritas.bench`,
rem `mix veritas.store.spec`, `mix veritas.store.install`), and Mix finds an
rem umbrella's tasks from the repository root, so `mix veritas.cli` already
rem works in a checkout.
rem
rem This script is the Windows twin of `bin/veritas-dev`, and it is the stable
rem path: it works from any directory, and every argument is passed straight
rem through.
rem
rem     bin\veritas-dev doctor
rem     bin\veritas-dev ci list --workspace default
rem
rem A first argument of `cli`, `bench`, `store-install` or `store-spec` names
rem the task; anything else is passed to the command line.
rem
rem The name says **dev** on purpose. `bin\veritas.bat` is the release's own
rem start script — `start`, `stop`, `rpc`, `eval`, `remote` — and one name must
rem mean one thing (docs/10 §Release Artifact Layout).

setlocal
pushd "%~dp0.."

set TASK=veritas.cli
if "%~1"=="cli"       set TASK=veritas.cli && shift
if "%~1"=="bench"     set TASK=veritas.bench && shift
if "%~1"=="store-install" set TASK=veritas.store.install && shift
if "%~1"=="store-spec"    set TASK=veritas.store.spec && shift

mix %TASK% %*
set EXITCODE=%ERRORLEVEL%

popd
exit /b %EXITCODE%

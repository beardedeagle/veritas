@echo off
rem The Veritas process reaper on Windows.
rem
rem The same Mix task macOS and Linux run: one implementation, in Elixir, over
rem the facts a platform adapter gathers (docs/12 Process Hygiene). The
rem adapter is the only thing that differs, and it has not yet been run on
rem Windows: the CI matrix is where that is proven.
setlocal
set "PATH=%USERPROFILE%\.local\share\mise\shims;C:\Program Files\Elixir\bin;%PATH%"
rem The ports this host's live instances serve. A process holding one of these
rem is never stopped, whatever else is true of it. The operator's list.
if "%VERITAS_KEEP_PORTS%"=="" set "VERITAS_KEEP_PORTS=4000,8010"
cd /d "%~dp0..\.."
call mix veritas.reap --go

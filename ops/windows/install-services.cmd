@echo off
rem Registers the three Veritas services with the Windows Service Control
rem Manager. The datastore is a child of the server process, not a service of
rem its own: ADR-048 puts it in the node's supervision tree, so it starts
rem with the node and stops with it.
rem
rem Runbook: ops/RUNBOOK.md
rem
rem The install must be run from an elevated prompt. "%ProgramFiles%\Veritas"
rem is where the release is installed.

set VERITAS_HOME=%ProgramFiles%\Veritas
set VERITAS_DATA=%ProgramData%\Veritas

if not exist "%VERITAS_HOME%\bin\veritas.bat" (
  echo There is no release at %VERITAS_HOME%. Install it first.
  exit /b 1
)

if not exist "%VERITAS_DATA%" mkdir "%VERITAS_DATA%"

sc.exe create veritas binPath= "%VERITAS_HOME%\bin\veritas.bat server" start= auto DisplayName= "Veritas Server"
sc.exe description veritas "Veritas ITSM and CMDB server. Owns its datastore as a supervised child process."
sc.exe failure veritas reset= 86400 actions= restart/60000/restart/60000/restart/60000/""/3600000
sc.exe failureflag veritas 1

sc.exe create veritas-scheduler binPath= "%VERITAS_HOME%\bin\veritas.bat scheduler" start= auto DisplayName= "Veritas Scheduler"
sc.exe description veritas-scheduler "Veritas scheduler node."

sc.exe create veritas-agent binPath= "%VERITAS_HOME%\bin\veritas.bat agent" start= auto DisplayName= "Veritas Endpoint Agent"
sc.exe description veritas-agent "Veritas endpoint agent. Not a cluster member."

sc.exe failure veritas-agent reset= 86400 actions= restart/60000/restart/60000/""/3600000
sc.exe failureflag veritas-agent 1

echo.
echo Registered. Start them with:
echo   sc.exe start veritas
echo   sc.exe start veritas-scheduler
echo   sc.exe start veritas-agent

@echo off
rem Goobies: collect logs into a zip on the Desktop, then send it or open the crash-report page.
rem Double-click it. Optional: "Report a problem.bat" "<issue page URL>"
rem Runs CollectCrashReport.ps1 from this same folder with no window and closes at once; a popup
rem asks before anything is sent. Nothing is sent unless a report_webhook.txt sits next to it AND
rem you answer Yes. If the report cannot be made, Goobies_crash_report_FAILED.txt opens in Notepad.
setlocal
set "GOOBIES_ISSUE_URL=%~1"
if not defined GOOBIES_ISSUE_URL goto run_default
start "" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0CollectCrashReport.ps1" -Gui -IssueUrl "%GOOBIES_ISSUE_URL%"
exit /b 0
:run_default
start "" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0CollectCrashReport.ps1" -Gui
exit /b 0

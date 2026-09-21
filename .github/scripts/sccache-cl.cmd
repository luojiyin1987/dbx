@echo off
if not defined SCCACHE_PATH (
  echo SCCACHE_PATH is not set. 1>&2
  exit /b 1
)

"%SCCACHE_PATH%" cl.exe %*
exit /b %ERRORLEVEL%

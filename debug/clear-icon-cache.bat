@echo off
echo Clearing Windows icon cache...

:: Kill Explorer first
taskkill /f /im explorer.exe >nul 2>&1

:: Delete icon cache files
del /f /s /q "%LocalAppData%\IconCache.db" >nul 2>&1
del /f /s /q "%LocalAppData%\Microsoft\Windows\Explorer\iconcache_*.db" >nul 2>&1
del /f /s /q "%LocalAppData%\Microsoft\Windows\Explorer\thumbcache_*.db" >nul 2>&1

:: Restart Explorer
start explorer.exe

echo Done. Icon cache cleared and Explorer restarted.
pause

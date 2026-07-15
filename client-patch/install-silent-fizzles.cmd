@echo off
rem Copies the silent fizzle sounds into the Ascension game root so the
rem engine stops playing the cast-deny fizzle. Run from inside
rem Interface\AddOns\Refactor\client-patch\ (double-click is fine).
setlocal
set "GAMEROOT=%~dp0..\..\..\.."
if not exist "%GAMEROOT%\Interface\AddOns" (
    echo Could not find the game root ^(expected this folder to live under
    echo ^<game^>\Interface\AddOns\Refactor\client-patch^). Nothing copied.
    pause
    exit /b 1
)
xcopy /s /y /i "%~dp0Sound" "%GAMEROOT%\Sound" >nul
if errorlevel 1 (
    echo Copy failed.
) else (
    echo Silent fizzle sounds installed. Restart the game to apply.
    echo In-game, the "Mute cast-deny sounds" checkbox on the Tweaks page
    echo now controls the sound instantly.
)
pause

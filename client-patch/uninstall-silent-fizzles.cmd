@echo off
rem Removes the silent fizzle sounds from the Ascension game root,
rem restoring the stock cast-deny fizzle sound.
setlocal
set "GAMEROOT=%~dp0..\..\..\.."
set "FIZZLE=%GAMEROOT%\Sound\Spells\Fizzle"
if not exist "%FIZZLE%" (
    echo Nothing to remove - the silent sounds are not installed.
    pause
    exit /b 0
)
del /q "%FIZZLE%\FizzleFireA.wav" "%FIZZLE%\FizzleFrostA.wav" "%FIZZLE%\FizzleHolyA.wav" "%FIZZLE%\FizzleNatureA.wav" "%FIZZLE%\FizzleShadowA.wav" 2>nul
rd "%FIZZLE%" 2>nul
rd "%GAMEROOT%\Sound\Spells" 2>nul
rd "%GAMEROOT%\Sound" 2>nul
echo Silent fizzle sounds removed. Restart the game to apply.
pause

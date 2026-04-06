@echo off
echo === GUIVision Windows DISM Install ===
echo This bypasses Windows Setup hardware checks entirely.

REM Find the drive containing this script (helpers ISO)
set HELPERSDRIVE=
for %%d in (D E F G H I J) do (
    if exist %%d:\install-windows.cmd set HELPERSDRIVE=%%d:
)

REM Load vioscsi driver so Windows PE can see the virtio-scsi disk
if "%HELPERSDRIVE%"=="" (
    echo ERROR: Could not find helpers drive
    pause
    exit /b 1
)
echo Loading viostor driver from %HELPERSDRIVE%\drivers...
drvload %HELPERSDRIVE%\drivers\viostor.inf
if errorlevel 1 (
    echo WARNING: drvload failed, disk may not be visible
) else (
    echo viostor driver loaded successfully.
)
REM Give the driver a moment to enumerate devices
ping -n 3 127.0.0.1 >nul

REM Find the drive containing install.wim (USB Windows ISO)
set ISODRIVE=
for %%d in (D E F G H I J) do (
    if exist %%d:\sources\install.wim set ISODRIVE=%%d:
)
if "%ISODRIVE%"=="" (
    echo ERROR: Could not find sources\install.wim on any drive
    echo Available drives:
    wmic logicaldisk get name,description
    pause
    exit /b 1
)
echo Found install.wim on %ISODRIVE%

REM Find the drive containing this script (for unattend.xml)
set SCRIPTDRIVE=
for %%d in (D E F G H I J) do (
    if exist %%d:\unattend.xml set SCRIPTDRIVE=%%d:
)

REM Partition the NVMe disk (Disk 0)
echo.
echo --- Partitioning disk ---
(
echo select disk 0
echo clean
echo convert gpt
echo create partition efi size=260
echo format fs=fat32 quick label=System
echo assign letter=S
echo create partition msr size=16
echo create partition primary
echo format fs=ntfs quick label=Windows
echo assign letter=W
echo exit
) | diskpart

if errorlevel 1 (
    echo ERROR: Disk partitioning failed
    pause
    exit /b 1
)

REM Apply Windows image via DISM
echo.
echo --- Applying Windows image (10-20 minutes) ---
dism /apply-image /imagefile:%ISODRIVE%\sources\install.wim /index:1 /applydir:W:\
if errorlevel 1 (
    echo ERROR: DISM image apply failed
    pause
    exit /b 1
)

REM Set up UEFI boot files
echo.
echo --- Setting up boot files ---
bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 (
    echo ERROR: bcdboot failed
    pause
    exit /b 1
)

REM Copy unattend.xml for OOBE automation (multiple locations for reliability)
echo.
echo --- Copying unattend.xml for OOBE ---
mkdir W:\Windows\Panther\Unattend 2>nul
copy %HELPERSDRIVE%\unattend.xml W:\Windows\Panther\unattend.xml
copy %HELPERSDRIVE%\unattend.xml W:\Windows\Panther\Unattend\unattend.xml

REM Inject viostor driver into the installed Windows so it persists after reboot
echo.
echo --- Injecting viostor driver ---
dism /image:W:\ /add-driver /driver:%HELPERSDRIVE%\drivers\viostor.inf

REM Set BypassNRO so OOBE shows "I don't have internet" option
echo.
echo --- Setting BypassNRO in offline registry ---
reg load HKLM\OFFLINE_SOFTWARE W:\Windows\System32\config\SOFTWARE
reg add "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f
reg unload HKLM\OFFLINE_SOFTWARE

REM Create SetupComplete.cmd — runs after OOBE, before first user login.
REM This creates the admin account and installs OpenSSH Server.
echo.
echo --- Creating SetupComplete.cmd ---
mkdir W:\Windows\Setup\Scripts 2>nul
(
echo @echo off
echo net user admin admin /add
echo net localgroup Administrators admin /add
echo reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /d 1 /f
echo reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /d admin /f
echo reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /d admin /f
echo reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f
echo powershell -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
echo powershell -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd"
echo powershell -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue"
) > W:\Windows\Setup\Scripts\SetupComplete.cmd
echo SetupComplete.cmd created.

echo.
echo === Installation complete ===
echo Reboot the VM now (the host script will handle this).

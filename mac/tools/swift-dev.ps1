# Runs swift on the Windows PC for the Foundation-only packages (InkvoltPrintKit's PrintCore):
#   pwsh -File mac/tools/swift-dev.ps1 test --package-path mac/InkvoltPrintKit --build-system native
# Needs the Swift toolchain (winget Swift.Toolchain) and Visual Studio's C++ ARM64 tools and Windows SDK. Loads the
# Visual Studio developer environment (link.exe, the SDK headers) and the toolchain's SDKROOT, which a shell opened before
# the install doesn't have. --build-system native: the default (Swift Build) loses the SDK's C headers on this setup.
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=arm64 -host_arch=arm64' | Out-Null
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
foreach ($name in 'SDKROOT', 'DEVELOPER_DIR') {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($value) { Set-Item "env:$name" $value }
}
swift @args
exit $LASTEXITCODE

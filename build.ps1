#!/usr/bin/env pwsh

<#

.SYNOPSIS
This is a Powershell script to bootstrap a Cake build.

.DESCRIPTION
This Powershell script will ensure cake.tool and gitversion.tool are installed,
and execute your Cake build script with the parameters you provide.

.PARAMETER Target
The task/target to run.
.PARAMETER Configuration
The build configuration to use.
.PARAMETER Verbosity
Specifies the amount of information to be displayed.
.PARAMETER NuGetVersion
The version of nuget.exe to be downloaded.
.PARAMETER ScriptArgs
Remaining arguments are added here.

.LINK
http://cakebuild.net

#>

[CmdletBinding()]
Param(
  [string]$Target = "Default",
  [ValidateSet("Release", "Debug")]
  [string]$Configuration = "Release",
  [ValidateSet("Quiet", "Minimal", "Normal", "Verbose", "Diagnostic")]
  [string]$Verbosity = "Verbose",
  [string]$NuGetVersion = "latest",
  [Parameter(Position = 0, Mandatory = $false, ValueFromRemainingArguments = $true)]
  [string[]]$ScriptArgs
)

$PSScriptRoot = split-path -parent $MyInvocation.MyCommand.Definition
$TOOLS_DIR = Join-Path $PSScriptRoot "tools"

# Make sure tools folder exists
if ((Test-Path $PSScriptRoot) -and (-not (Test-Path $TOOLS_DIR))) {
  Write-Verbose -Message "Creating tools directory..."
  New-Item -Path $TOOLS_DIR -Type directory | out-null
}

###########################################################################
# LOAD versions from build.config
###########################################################################

[string] $DotNetSdkVersion = ''
[string] $CakeVersion = ''
[string] $CakeScriptsVersion = ''
[string] $GitVersionVersion = ''
[string] $GitReleaseManagerVersion = ''
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'build.config')) {
  if ($line -like 'DOTNET_VERSION=*') {
    $DotNetSdkVersion = $line.SubString(15)
  }
  elseif ($line -like 'CAKE_VERSION=*') {
    $CakeVersion = $line.SubString(13)
  }
  elseif ($line -like 'CAKESCRIPTS_VERSION=*') {
    $CakeScriptsVersion = $line.SubString(20)
  }
  elseif ($line -like 'GITVERSION_VERSION=*') {
    $GitVersionVersion = $line.SubString(19)
  }
  elseif ($line -like 'GITRELEASEMANAGER_VERSION=*') {
    $GitReleaseManagerVersion = $line.SubString(26)
  }
}
if ([string]::IsNullOrEmpty($DotNetSdkVersion)) {
  'Failed to parse .NET Core SDK version'
  exit 1
}
if ([string]::IsNullOrEmpty($CakeVersion)) {
  'Failed to parse Cake version'
  exit 1
}
if ([string]::IsNullOrEmpty($CakeScriptsVersion)) {
  'Failed to parse CakeScripts version'
  exit 1
}
if ([string]::IsNullOrEmpty($GitVersionVersion)) {
  'Failed to parse GitVersion version'
  exit 1
}
if ([string]::IsNullOrEmpty($GitReleaseManagerVersion)) {
  'Failed to parse GitReleaseManager version'
  exit 1
}

# This will force the use of TLS 1.2 (you can also make it use 1.1 if you want for some reason).
# To avoid the exception: "The underlying connection was closed: An unexpected error occurred on a send."
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($PSVersionTable.PSEdition -ne 'Core') {
  # Attempt to set highest encryption available for SecurityProtocol.
  # PowerShell will not set this by default (until maybe .NET 4.6.x). This
  # will typically produce a message for PowerShell v2 (just an info
  # message though)
  try {
    # Set TLS 1.2 (3072), then TLS 1.1 (768), then TLS 1.0 (192), finally SSL 3.0 (48)
    # Use integers because the enumeration values for TLS 1.2 and TLS 1.1 won't
    # exist in .NET 4.0, even though they are addressable if .NET 4.5+ is
    # installed (.NET 4.5 is an in-place upgrade).
    [System.Net.ServicePointManager]::SecurityProtocol = 3072 -bor 768 -bor 192 -bor 48
  }
  catch {
    Write-Output 'Unable to set PowerShell to use TLS 1.2 and TLS 1.1 due to old .NET Framework installed. If you see underlying connection closed or trust errors, you may need to upgrade to .NET Framework 4.5+ and PowerShell v3'
  }
}

function ParseSdkVersion([string]$version) {
  $major, $minor, $featureAndPatch = $version.split('.')
  $feature = $featureAndPatch.SubString(0, 1)
  $patch = $featureAndPatch.SubString(1)
  return [PsCustomObject] @{
    Major   = [int]$major
    Minor   = [int]$minor
    Feature = [int]$feature
    Patch   = [int]$patch
  }
}

function createDummySdkProject($cakeScriptVersion) {
  "<Project Sdk=""Microsoft.NET.Sdk"">

    <PropertyGroup>
        <OutputType>Exe</OutputType>
        <TargetFramework>net6.0</TargetFramework>
        <!--
            Path to the user packages folder. All downloaded packages are extracted here.
            Equivalent to -packages in dotnet restore.

            The RestorePackagesPath MSBuild property can be used to override the
            global packages folder location when a project uses a PackageReference.

            Changes the global packages folder
        -->
        <RestorePackagesPath>tools</RestorePackagesPath>
        <!--
            If a package is resolved to a fallback folder, it may not be downloaded.
        -->
        <DisableImplicitNuGetFallbackFolder>true</DisableImplicitNuGetFallbackFolder>
        <!--
            We don't want to build this project, so we do not need the reference assemblies
            for the framework we chose.
        -->
        <AutomaticallyUseReferenceAssemblyPackages>false</AutomaticallyUseReferenceAssemblyPackages>
    </PropertyGroup>

     <ItemGroup>
        <!--
            PackageDownload items are not part of the packages lock file.
            That is PackageDownload will not affect the project graph in any way.
            Dependencies need not be downloaded.
            Only the exactly specified version is downloaded.
            PackageDownload is not transitive, the PrivateAssets metadata is irrelevant.
            PackageDownload does not involve any assets selection, so the ExcludeAssets/IncludeAssets is irrelevant.
        -->
        <PackageDownload Include=""Maxfire.CakeScripts"" Version=""[${cakeScriptVersion}]"" />
    </ItemGroup>

</Project>" | out-file "./tools/Dummy.csproj" -encoding "UTF8"
}

# Create Dummy.csproj in order to download Maxfire.CakeScripts (See https://github.com/NuGet/Home/issues/12513)
createDummySdkProject $CakeScriptsVersion

###########################################################################
# Install .NET Core SDK
###########################################################################

$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 1 # Caching packages on a temporary build machine is a waste of time.
$env:DOTNET_CLI_TELEMETRY_OPTOUT = 1       # opt out of telemetry

$DotNetChannel = 'LTS'

Function Remove-PathVariable([string]$VariableToRemove) {
  $path = [Environment]::GetEnvironmentVariable("PATH", "User")
  if ($path -ne $null) {
    $newItems = $path.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -inotlike $VariableToRemove }
    [Environment]::SetEnvironmentVariable("PATH", [System.String]::Join(';', $newItems), "User")
  }

  $path = [Environment]::GetEnvironmentVariable("PATH", "Process")
  if ($path -ne $null) {
    $newItems = $path.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -inotlike $VariableToRemove }
    [Environment]::SetEnvironmentVariable("PATH", [System.String]::Join(';', $newItems), "Process")
  }
}

$FoundDotNetSdkVersion = $null
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
  # dotnet --version will use version found in global.json, but the SDK will error if the
  # global.json version is not found on the machine.
  $FoundDotNetSdkVersion = & dotnet --version 2>&1
  if ($LASTEXITCODE -ne 0) {
    # Extract the first line of the message without making powershell write any error messages
    Write-Host ($FoundDotNetSdkVersion | ForEach-Object { "$_" } | select-object -first 1)
    Write-Host "That is not problem, we will install the SDK version below."
    $FoundDotNetSdkVersion = "0.0.000" # Force installation of .NET Core SDK via dotnet-install script
  }
  else {
    Write-Host ".NET Core SDK version $FoundDotNetSdkVersion found."
  }
}

Write-Host ".NET Core SDK version $DotNetSdkVersion is required (with roll forward to latest patch policy)"

# Parse the sdk versions into major, minor, feature and patch (x.y.znn)
$ParsedFoundDotNetSdkVersion = ParseSdkVersion($FoundDotNetSdkVersion)
$ParsedDotNetSdkVersion = ParseSdkVersion($DotNetSdkVersion)

# latestPatch rollforward policy
if (($ParsedFoundDotNetSdkVersion.Major -ne $ParsedDotNetSdkVersion.Major) -or `
  ($ParsedFoundDotNetSdkVersion.Minor -ne $ParsedDotNetSdkVersion.Minor) -or `
  ($ParsedFoundDotNetSdkVersion.Feature -ne $ParsedDotNetSdkVersion.Feature) -or `
  ($ParsedFoundDotNetSdkVersion.Patch -lt $ParsedDotNetSdkVersion.Patch)) {

  Write-Verbose -Message "Installing .NET Core SDK version $DotNetSdkVersion ..."

  $InstallPath = Join-Path $PSScriptRoot ".dotnet"
  if (-not (Test-Path $InstallPath)) {
    mkdir -Force $InstallPath | Out-Null
  }

  (New-Object System.Net.WebClient).DownloadFile("https://dot.net/v1/dotnet-install.ps1", "$InstallPath\dotnet-install.ps1")

  & $InstallPath\dotnet-install.ps1 -Channel $DotNetChannel -Version $DotNetSdkVersion -InstallDir $InstallPath -NoPath

  Remove-PathVariable "$InstallPath"
  $env:PATH = "$InstallPath;$env:PATH"
  $env:DOTNET_ROOT = $InstallPath
}

###########################################################################
# Install CakeScripts
###########################################################################

if (-not (Test-Path (Join-Path $TOOLS_DIR 'Maxfire.CakeScripts'))) {
  # latest or empty string is interpreted as 'just use the latest' (floating version, not determinsitic)
  if ( ($CakeScriptsVersion -eq "latest") -or [string]::IsNullOrWhitespace($CakeScriptsVersion) ) {
    & dotnet add tools/Dummy.csproj package Maxfire.CakeScripts --package-directory "$TOOLS_DIR" `
      --source 'https://nuget.pkg.github.com/maxild/index.json' | Out-Null
  }
  else {
    & dotnet add tools/Dummy.csproj package Maxfire.CakeScripts --version $CakeScriptsVersion --package-directory "$TOOLS_DIR" `
      --source 'https://nuget.pkg.github.com/maxild/index.json' | Out-Null
  }
  if ($LASTEXITCODE -ne 0) {
    Throw "An error occured while downloading Maxfire.CakeScripts."
  }
}
else {
  # Maxfire.CakeScripts is already installed, check what version is installed
  # FIXME: Does not work unless version is not part of download path
  $versionTxtPath = Join-Path $TOOLS_DIR "Maxfire.CakeScripts" | Join-Path -ChildPath "content" | Join-Path -ChildPath "version.txt"
  $CakeScriptsInstalledVersion = '0.0.0'
  if (Test-Path $versionTxtPath) {
    $CakeScriptsInstalledVersion = "$(Get-Content -Path $versionTxtPath -TotalCount 1 -Encoding ascii)".Trim()
  }
  Write-Host "Maxfire.CakeScripts version $CakeScriptsInstalledVersion found."
  Write-Host "Maxfire.CakeScripts version $CakeScriptsVersion is required."

  if ($CakeScriptsVersion -ne $CakeScriptsInstalledVersion) {
    Write-Host "Upgrading to version $CakeScriptsVersion of Maxfire.CakeScripts..."
    & dotnet add tools/Dummy.csproj package Maxfire.CakeScripts --version $CakeScriptsVersion --package-directory "$TOOLS_DIR" `
      --source 'https://nuget.pkg.github.com/maxild/index.json' | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Throw "An error occured while downloading Maxfire.CakeScripts."
    }
  }
}

###########################################################################
# INSTALL .NET Core 3.x tools
###########################################################################

# To see list of packageid, version and commands
#      dotnet tool list --tool-path ./tools
Function Install-NetCoreTool {
  param
  (
    [string]$PackageId,
    [string]$ToolCommandName,
    [string]$Version
  )

  $ToolPath = Join-Path $TOOLS_DIR '.store' | Join-Path -ChildPath $PackageId.ToLower() | Join-Path -ChildPath $Version
  $ToolPathExists = Test-Path -Path $ToolPath -PathType Container

  $ExePath = (Get-ChildItem -Path $TOOLS_DIR -Filter "${ToolCommandName}*" -File | ForEach-Object FullName | Select-Object -First 1)
  $ExePathExists = (![string]::IsNullOrEmpty($ExePath)) -and (Test-Path $ExePath -PathType Leaf)

  if ((!$ToolPathExists) -or (!$ExePathExists)) {

    if ($ExePathExists) {
      & dotnet tool uninstall --tool-path $TOOLS_DIR $PackageId | Out-Null
    }

    & dotnet tool install --tool-path $TOOLS_DIR --version $Version $PackageId | Out-Null
    if ($LASTEXITCODE -ne 0) {
      "Failed to install $PackageId"
      exit $LASTEXITCODE
    }

    $ExePath = (Get-ChildItem -Path $TOOLS_DIR -Filter "${ToolCommandName}*" -File | ForEach-Object FullName | Select-Object -First 1)
  }

  return $ExePath
}

[string] $CakeExePath = Install-NetCoreTool -PackageId 'Cake.Tool' -ToolCommandName 'dotnet-cake' -Version $CakeVersion
Install-NetCoreTool -PackageId 'GitVersion.Tool' -ToolCommandName 'dotnet-gitversion' -Version $GitVersionVersion | Out-Null
Install-NetCoreTool -PackageId 'GitReleaseManager.Tool' -ToolCommandName 'dotnet-gitreleasemanager' -Version $GitReleaseManagerVersion | Out-Null

###########################################################################
# RUN BUILD SCRIPT
###########################################################################

# When using modules we have to add this
& "$CakeExePath" ./build.cake --bootstrap

# Build the argument list.
$Arguments = @{
  target        = $Target;
  configuration = $Configuration;
  verbosity     = $Verbosity;
}.GetEnumerator() | ForEach-Object { "--{0}=`"{1}`"" -f $_.key, $_.value }

Write-Host "Running build script..."
& "$CakeExePath" ./build.cake $Arguments $ScriptArgs
exit $LASTEXITCODE

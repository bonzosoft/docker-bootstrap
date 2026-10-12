#!/usr/bin/env pwsh


#using namespace System.Collections.Generic   # List[T]
using namespace System.Management.Automation # OrderedHashtable


[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter()]
    [switch]$KeepCredential
)

try {
    # Command line setup -------------------------------------------------------
    Set-StrictMode -Version 'Latest'
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'


    # Script start -------------------------------------------------------------
    [Collections.Generic.List[IO.FileInfo]]$thisScript = @()
    $thisScript.Insert(0, $PSCommandPath)
    Write-Information -MessageData "Loading script '$($thisScript[0])'."


    # Script-wide Variables ----------------------------------------------------
    [hashtable]$splat = @{}


    # Configuration file path --------------------------------------------------
    [IO.FileInfo]$configFile = Join-Path -Path ([IO.DirectoryInfo]$PWD.Path) -ChildPath @(".config", "config.json")
    [IO.DirectoryInfo]$ghDirectory = Join-Path -Path $configFile.Directory -ChildPath @("gh")
    

    # Repository configuration -------------------------------------------------
    [pscustomobject]$repository = [pscustomobject]@{}
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Domain"       -Value ([uri]"https://github.com")
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Organization" -Value ([string]"bonzosoft")
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Name"         -Value ([string]"docker-deploy")
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Branch"       -Value ([string]"main")
    Add-Member -InputObject $repository -MemberTYpe 'NoteProperty'   -Name "BasePath"     -Value ([IO.DirectoryInfo]$PWD.Path)
    Add-Member -InputObject $repository -MemberType 'ScriptProperty' -Name "Path"         -Value ([scriptblock]{
        return [IO.DirectoryInfo](Join-Path -Path $this.Directory -ChildPath @($this.Name))
    })

    # Disable stdout y stderr --------------------------------------------------
    [hashtable]$disableRedirect = @{
        RedirectStandardOutput = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        RedirectStandardError  = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    }
    

    #Region - Main logic -------------------------------------------------------
    Write-Information -MessageData "Loading local configuration."
    [OrderedHashtable]$configData = [ordered]@{}
    
    $configFile.Refresh()
    if ($configFile.Length -ne 0) {
        $configData = Get-Content -Path $configFile -ErrorAction 'Stop' |
            ConvertFrom-Json -Depth 9 -AsHashtable -ErrorAction 'Stop'
    }
    if ($configData -isnot [hahstable]) {
        [OrderedHashtable]$configData = [ordered]@{}
    }
    if ((-not $configData.ContainsKey("Git")) -or ($configData.Git -isnot [hashtable])) {
        [OrderedHashtable]$configData.Git = [ordered]@{}
    }
    if (-not $configData.Git.ContainsKey("Token")) {
        [string]$configData.Git.Token = ""
    }


    Write-Information -MessageData "Runing command: apt update."
    $splat = @{
        FilePath     = "apt"
        ArgumentList = @("update")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    if (-not $Debug.IsPresent) {
        $splat += $disableRedirect
    }
    $process = Start-Process @splat -ErrorAction 'Stop'
    if ($process.ExitCode -ne 0) {
        throw "Command finished with exit code: $($pocess.ExitCode)."
    }
    

    Write-Information -MessageData "Runing command: apt install gh."
    $splat = @{
        FilePath = "apt"
        ArgumentList = @("install", "gh", "--yes")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @splat -ErrorAction 'Stop'
    if ($process.ExitCode -ne 0) {
        throw "Command finished with exit code: $($pocess.ExitCode)."
    }
    

    Write-Information -MessageData "Runing command: apt config set prompt disabled."
    $splat = @{
        FilePath     = "gh"
        ArgumentList = @("config", "set", "prompt", "disabled")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @splat -ErrorAction 'Stop'
    if ($process.ExitCode -ne 0) {
        throw "Command finished with exit code: $($pocess.ExitCode)."
    }


    do {
        Write-Information -MessageData "Runing command: gh auth status."
        $splat = @{
            FilePath = "gh"
            ArgumentList = @("auth", "status")
            Environment  = @{
                GH_TOKEN      = $configData.Git.Token
                GH_CONFIG_DIR = $ghDirectory.FullName
            }
            NoNewWindow  = $true
            Wait         = $true
            PassThru     = $true
        }
        $process = Start-Process @splat -ErrorAction 'Stop'
        if ($process.ExitCode -ne 0) {
            Write-Information -MessageData "Runing command: gh auth login."
            $splat = @{
                FilePath     = "gh"
                ArgumentList = @(
                    "auth"
                    "login"
                    "--web" # --web | --with-token
                    "--git-protocol", $repository.Domain.Scheme
                    "--hostname", $repository.Domain.Host
                )
                Environment  = @{
                    GH_PROMPT_DISABLED = $true
                    GH_TOKEN      = $configData.Git.Token
                    GH_CONFIG_DIR = $ghDirectory.FullName
                }
                NoNewWindow  = $true
                Wait         = $true
                PassThru     = $true
            }
            $process = Start-Process @splat -ErrorAction 'Stop'
            if ($process.ExitCode -ne 0) {
                throw "Command finished with exit code: $($pocess.ExitCode)."
            }
        }
        else {
            break
        }
    }
    while ($true)
    

    if (Test-Path -Path $repository.Path -PathType 'Any') {
        Write-Information -MessageData "Removing local repository."
        Remove-Item -Path $repository.Path -Recurse -Force
    }
    

    Write-Information -MessageData "Runing command: gh repo clone."
    $splat = @{
        FilePath     = "gh"
        ArgumentList = @(
            "repo"
            "clone"
           ($repository.Organization) + "/" + $($repository.Name)
            $repository.Path.FullName
            "--"
            "--branch", $repository.Branch
            "--single-branch"
            "--depth", 1
            "--recurse-submodules"
        )
        Environment  = @{
            GH_TOKEN      = $configData.Git.Token
            GH_CONFIG_DIR = $ghDirectory.FullName
        }
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @splat -ErrorAction 'Stop'
    if ($process.ExitCode -ne 0) {
        throw "Command finished with exit code: $($pocess.ExitCode)."
    }


    foreach ($item in @("pwsh")) {
        [IO.FIleInfo]$source = Join-Path -Path ([IO.FileInfo]$PWD.Path) -ChildPath @($repository.Name, "${item}.sh")
        [IO.FIleInfo]$target = Join-Path -Path ([IO.FileInfo]$PWD.Path) -ChildPath @($item)
    
        if (Test-Path -Path $source -PathType 'Leaf') {
            Write-Information -MessageData "Creating link for '$item'."
            New-Item -Path $target -Value $source -ItemType 'SymbolicLink' -Force | Out-Null
        
            Write-Information -MessageData "Setting '$item' as executable."
            $splat = @{
                FilePath     = "chmod"
                ArgumentList = @("+x", $source.FullName)
                Environment  = @{}
                NoNewWindow  = $true
                Wait         = $true
                PassThru     = $true
            }
            $process = Start-Process @splat -ErrorAction 'Stop'
            if ($process.ExitCode -ne 0) {
                throw "Command finished with exit code: $($pocess.ExitCode)."
            }
        }
    }
    #Endregion
}
catch {
    Write-Error -ErrorRecord $PSItem
    Write-Error -Exception $PSItem.Exception
    Write-Error -Message $PSItem.ScriptStackTrace
}
finally {
    if (-not $KeepCredential.IsPresent) {
        Write-Information -MessageData "Removing cached credentials."
        Remove-Item -Path $ghDirectory -Recurse -Force
    }

    # Script end ---------------------------------------------------------------
    Write-Information -MessageData "Completed script execution '$($thisScript[0])'."
    $thisScript.RemoveAt(0)
}

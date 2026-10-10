#!/usr/bin/env pwsh

[CmdletBinding()]
[OutputType([void])]
param()

try {
    # Command line setup -------------------------------------------------------
    Set-StrictMode -Version 'Latest'
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'


    # Script start -------------------------------------------------------------
    [Collections.Generic.List[IO.FileInfo]]$thisScript = @()
    $thisScript.Insert(0, $PSCommandPath)
    Write-Information -MessageData "Loading script '$($thisScript[0])'."


    # Configuration file path --------------------------------------------------
    [IO.FileInfo]$configFile = Join-Path -Path ([IO.FileInfo]$PWD.Path) -ChildPath @(".config", "config.json")
    [IO.DirectoryInfo]$ghDirectory = Join-Path -Path $configFile.Directory -ChildPath @("gh")

    # Repository configuration -------------------------------------------------
    [hashtable]$repository = [pscustomobject]@{}
    $repository | Add-Member -MemberType 'NoteProperty'   -Name "Domain"       -Value ([uri]"https://github.com")
    $repository | Add-Member -MemberType 'NoteProperty'   -Name "Organization" -Value "bonzosoft"
    $repository | Add-Member -MemberType 'NoteProperty'   -Name "Name"         -Value "docker-deploy"
    $repository | Add-Member -MemberType 'NoteProperty'   -Name "Branch"       -Value "main"
    $repository | Add-Member -MemberTYpe 'NoteProperty'   -Name "Directory"    -Value ([IO.DirectoryInfo]$PWD.Path)
    $repository | Add-Member -MemberType 'ScriptProperty' -Name "Path"         -Value ([scriptblock]{
        return [IO.FileInfo](Join-Path -Path $this.Directory -ChildPath @($this.Name))
    })

    # Script -------------------------------------------------------------------
    Write-Information -MessageData "Runing command: apt update."
    $splat = @{
        FilePath     = "apt"
        ArgumentList = @("update")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    $process = Start-Process @splat
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
        ErrorAction  = 'Stop'
    }
    $process = Start-Process @splat
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
        ErrorAction  = 'Stop'
    }
    $process = Start-Process @splat
    if ($process.ExitCode -ne 0) {
        throw "Command finished with exit code: $($pocess.ExitCode)."
    }
    
    Write-Information -MessageData "Checking local configuration."
    [hashtable]$configData = Get-Content -Path $configFile -ErrorAction 'SilentlyContinue' |
        ConvertFrom-Json -Depth 9 -AsHashtable -ErrorAction 'SilentlyContinue'

    if ($null -eq $configData) {
        [hashtable]$configData = @{}
    }
    if (-not $configData.ContainsKey("Git")) {
        [hashtable]$configData.Git = @{}
    }
    if (-not $configData.Git.ContainsKey("Token")) {
        [string]$configData.Git.Token = ""
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
            ErrorAction  = 'Stop'
        }
        $process = Start-Process @splat
        if ($process.ExitCode -ne 0) {
            Write-Information -MessageData "Runing command: gh auth login."
            $splat = @{
                FilePath     = "gh"
                ArgumentList = @(
                    "auth"
                    "login"
                    "--git-protocol", $repository.Domain.Scheme
                    "--hostname", $repository.Domain.Host
                )
                Environment  = @{
                    #GH_TOKEN      = $configData.Git.Token
                    GH_CONFIG_DIR = $ghDirectory.FullName
                }
                NoNewWindow  = $true
                Wait         = $true
                PassThru     = $true
                ErrorAction  = 'Stop'
            }
            $exitCode = Start-Process @splat
            if ($exitCode -ne 0) {
                throw "Command finished with exit code: ${LASTEXITCODE}."
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
        ErrorAction  = 'Stop'
    }
    $process = Start-Process @splat
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
                ErrorAction  = 'Stop'
            }
            $process = Start-Process @splat
            if ($process.ExitCode -ne 0) {
                throw "Command finished with exit code: $($pocess.ExitCode)."
            }
        }
    }
}
catch {
    Write-Error -ErrorRecord $PSItem
    Write-Error -Exception $PSItem.Excetpion
    Write-Error -Message $PSItem.ScriptStackTrace
}
finally {
    Write-Information -MessageData "Completed script execution '$($thisScript[0])'."
    $thisScript.RemoveAt(0)
}

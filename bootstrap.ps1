#!/usr/bin/env pwsh

[CmdletBinding()]
[OutputType([void])]
param()

begin {
    # Command line setup =======================================================
    Set-StrictMode -Version 'Latest'
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'

    # Script start =============================================================
    [Collections.Generic.List[IO.FileInfo]]$thisScript = $PSCommandPath
    Write-Information -MessageData "Loading script '$($thisScript[0])'."
    
    [IO.FIleInfo]$configFile = Join-Path -Path $PWD -ChildPath @(".config", "config.json")

    [hashtable]$repository             = @{}
    [uri]$repository.Domain            = "https://github.com"
    [string]$repository.Organization   = "bonzosoft"
    [string]$repository.Name           = "docker-deploy"
    [string]$repository.Branch         = "main"
    [IO.DirectoryInfo]$repository.Path = Join-Path -Path $PWD -ChildPath @($repository.Name)
}

process {
    Write-Information -MessageData "Runing: apt update."
    $splat = @{
        FilePath     = "apt"
        ArgumentList = @("update")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        ErrorAction  = 'Stop'
    }
    Start-Process @splat
    if ($LASTEXITCODE -ne 0) {
        throw "ERROR."
    }
    
    Write-Information -MessageData "Runing: apt install gh."
    $splat = @{
        FilePath = "apt"
        ArgumentList = @("install", "gh", "--yes")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        ErrorAction  = 'Stop'
    }
    Start-Process @splat
    if ($LASTEXITCODE -ne 0) {
        throw "ERROR."
    }
    
    Write-Information -MessageData "Runing: apt config set prompt disabled."
    $splat = @{
        FilePath     = "gh"
        ArgumentList = @("config", "set", "prompt", "disabled")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        ErrorAction  = 'Stop'
    }
    Start-Process @splat
    if ($LASTEXITCODE -ne 0) {
        throw "ERROR."
    }
    
    Write-Information -MessageData "Checking local configuration."
    [hashtable]$configData = Get-Content -Path $configFile -ErrorAction 'SilentlyContinue' | ConvertFrom-Json -Depth 9 -AsHashtable -ErrorAction 'SilentlyContinue'
    if ($null -eq $configData) {
        [hashtable]$configData = @{}
    }
    if (-not $configData.ContainsKey("Git")) {
        [hashtable]$configData.Git = @{}
    }
    if (-not $configData.Git.ContainsKey("Token")) {
        [string]$configData.Git.Token = ""
    }
    
    [bool]$successLogin = $false
    do {
        if (-not ($configData.Git.Token)) {
            Write-Information -MessageData "Runing: gh auth login."
            $splat = @{
                FilePath = "gh"
                ArgumentList = @(
                    "auth"
                    "login"
                    "--git-protocol", $repository.Domain.Scheme
                    "--hostname", $repository.Domain.Host
                )
                Environment  = @{}
                NoNewWindow  = $true
                Wait         = $true
                ErrorAction  = 'Stop'
            }
            Start-Process @splat
            if ($LASTEXITCODE -ne 0) {
                throw "ERROR."
            }
        }

        Write-Information -MessageData "Runing: gh auth status."
        $splat = @{
            FilePath = "gh"
            ArgumentList = @("auth", "status")
            Environment  = @{GH_TOKEN = $configData.Git.Token}
            NoNewWindow  = $true
            Wait         = $true
            ErrorAction  = 'Stop'
        }
        Start-Process @splat
        Write-Information -MessageData "LastExitCode= $LASTEXITCODE."
        $successLogin = -not $LASTEXITCODE
    }
    while (-not $successLogin)
    
    if (Test-Path -Path $repository.Path) {
        Write-Information -MessageData "Removing local repository."
        Remove-Item -Path $repository.Path -Recurse -Force
    }
    
    Write-Information -MessageData "Runing: gh repo clone."
    $splat = @{
        FilePath     = "gh"
        ArgumentList = @(
            "repo"
            "clone"
           ($repository.Organization) + "/" + $($repository.Name)
            $repository.Path
            "--"
            "--branch", $repository.Branch
            "--single-branch"
            "--depth", 1
            "--recurse-submodules"
        )
        Environment = @{GH_TOKEN = $configData.Git.Token}
        NoNewWindow  = $true
        Wait         = $true
        ErrorAction  = 'Stop'
    }
    Start-Process @splat
    if ($LASTEXITCODE -ne 0) {
        throw "ERROR."
    }

    foreach ($item in @("pwsh")) {
        [IO.FIleInfo]$source = Join-Path -Path $PWD -ChildPath @($($repository.Name), "${item}.sh")
        [IO.FIleInfo]$target = Join-Path -Path $PWD -ChildPath @($item)
    
        if (Test-Path -Path $source) {
            Write-Information -MessageData "Creating link for '${item}'."
            New-Item -Path $target -Value $source -ItemType 'SymbolicLink' -Force | Out-Null
        
            Write-Information -MessageData "Setting '${item}' as executable."
            $splat = @{
                FilePath = "chmod"
                ArgumentList = @("+x", $source.FullName)
                Environment = @{GH_TOKEN = $configData.Git.Token}
                NoNewWindow  = $true
                Wait         = $true
                ErrorAction  = 'Stop'
            }
            Start-Process @splat
            if ($LASTEXITCODE -ne 0) {
                throw "ERROR."
            }
        }
    }
}

end {
    # Script end ===============================================================
    Write-Information -MessageData "Completed script execution '$($thisScript[0])'."
    $thisScript.RemoveAt(0)
}

clean {
    # nop
}

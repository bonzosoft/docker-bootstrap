#!/usr/bin/env pwsh


#using namespace System.Collections.Generic   # List[T]
using namespace System.Management.Automation # OrderedHashtable, PSCredential


[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter()]
    [switch]$KeepCredential
)

try {
    # Command line setup -------------------------------------------------------
    Clear-Host
    Set-StrictMode -Version 'Latest'
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'


    # Script start -------------------------------------------------------------
    [Collections.Generic.List[IO.FileInfo]]$thisScript = @()
    $thisScript.Insert(0, $PSCommandPath)
    Write-Information -MessageData "Loading script '$($thisScript[0])'."


    # Script-wide variables ----------------------------------------------------
    [hashtable]$splat = @{}


    # Configuration file path --------------------------------------------------
    [IO.FileInfo]$configFile = Join-Path -Path ([IO.DirectoryInfo]$PWD.Path) -ChildPath @(".config", "config.json")


    # Vault configuration ------------------------------------------------------
    [pscustomobject]$vaultSplat = [pscustomobject]@{}
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Credential"   -Value $null
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Domain"       -Value ([uri]"https://eu.infisical.com")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Organization" -Value ([guid]"8008422a-830a-4a7c-8472-ab56f0172560")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Project"      -Value ([guid]"8a484bc8-4a18-468e-842c-7a264394781e")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Environment"  -Value ([string]"dev")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Token"        -Value $null


    # Repository configuration -------------------------------------------------
    [pscustomobject]$repositorySplat = [pscustomobject]@{}
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Domain"       -Value ([uri]"https://github.com")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Organization" -Value ([string]"bonzosoft")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Name"         -Value ([string]"docker-deploy")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Branch"       -Value ([string]"main")
    Add-Member -InputObject $repositorySplat -MemberTYpe 'NoteProperty'   -Name "BasePath"     -Value ([IO.DirectoryInfo]$PWD.Path)
    Add-Member -InputObject $repositorySplat -MemberType 'ScriptProperty' -Name "Path"         -Value ([scriptblock]{
        return [IO.DirectoryInfo](Join-Path -Path $this.BasePath -ChildPath @($this.Name))
    })


    # Disable stdout y stderr display for native commands ----------------------
    [hashtable]$disableRedirect = @{
        RedirectStandardOutput = [System.IO.Path]::GetTempFileName()
        RedirectStandardError  = [System.IO.Path]::GetTempFileName()
    }
    

    #Region - Main -------------------------------------------------------------


    # Configuration validation -------------------------------------------------
    Write-Information -MessageData "Loading local configuration."
    [OrderedHashtable]$configData = [ordered]@{}
    
    $configFile.Refresh()
    if (-not $configFile.Directory.Exists) {
        $configFile.Directory.Create()
    }
    if (-not $configFile.Exists) {
        $configFile.Create().Dispose()
    }
    if ($configFile.Length -ne 0) {
        $configData = Get-Content -Path $configFile -ErrorAction 'SilentlyContinue' |
            ConvertFrom-Json -Depth 9 -AsHashtable -ErrorAction 'SilentlyContinue'
    }

    $configData
    $configData.Vault.ClientId
    $configData.Vault.ClientSecret

    if ($configData -isnot [hashtable]) {
        [OrderedHashtable]$configData = [ordered]@{}
    }
    if ((-not $configData.ContainsKey("Vault")) -or ($configData.Vault -isnot [hashtable])) {
        [OrderedHashtable]$configData.Vault = [ordered]@{}
    }
    if ((-not $configData.ContainsKey("ClientId"))) {
        [string]$configData.Vault.ClientId = ""
        #[string]$configData.Vault.ClientId = "user"
    }
    if ((-not $configData.ContainsKey("ClientSecret"))) {
        [securestring]$configData.Vault.ClientSecret = $null
        #[securestring]$configData.Vault.ClientSecret = ("pass" | ConvertTo-SecureString -AsPlainText)
    }
    else {
        [securestring]($configData.Vault.ClientSecret | ConvertTo-SecureString -AsPlainText)
    }
    if ((-not $configData.ContainsKey("Git")) -or ($configData.Git -isnot [hashtable])) {
        [OrderedHashtable]$configData.Git = [ordered]@{}
    }
    if (-not $configData.Git.ContainsKey("Token")) {
        [string]$configData.Git.Token = ""
    }

    write-host "credenciales leidas: $($configData.Vault.ClientId)`n$($configData.Vault.ClientSecret)"
 return
    do {
        if (-not ([string]::IsNullOrWhiteSpace($configData.Vault.ClientId) -and [string]::IsNullOrWhiteSpace($configData.Vault.ClientSecret))) {
            $splat = @{
                TypeName = "System.Management.Automation.PSCredential"
                ArgumentList = @(
                    $configData.Vault.ClientId
                    ($configData.Vault.ClientSecret | ConvertTo-SecureString -AsPlainText)
                )
            }
            $vaultSplat.Credential = New-Object @splat -ErrorAction 'Stop'
    
            $splat = @{
                FilePath     = "infisical"
                ArgumentList = @(
                    "login"
                    "--domain",        $vaultSplat.Domain.AbsoluteUri
                    "--method=universal-auth"
                    "--client-id",     $vaultSplat.Credential.GetNetworkCredential().UserName
                   #"--client-secret", $vaultSplat.Credential.GetNetworkCredential().Password
                    "--telemetry=false"
                    "--plain"
                    "--silent"
                )
                Environment  = @{
                    INFISICAL_DISABLE_UPDATE_CHECK         = $true
                    INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET = $vaultSplat.Credential.GetNetworkCredential().Password
                }
                NoNewWindow  = $true
                Wait         = $true
                PassThru     = $true
            }
            $processResult = Start-Process @splat -ErrorAction 'Stop'
            if ($processResult.ExitCode -ne 0) {
                throw "Command finished with exit code: $($process.ExitCode)."
            }
    
            Write-Host "habemus token"
        }
    } while ($true)
 

    
return




    Write-Information -MessageData "Runing command: apt update."
    $splat = @{
        FilePath     = "apt"
        ArgumentList = @("update")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    if ($VerbosePreference -ne 'Continue') {
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
    if ($VerbosePreference -ne 'Continue') {
        $splat += $disableRedirect
    }
    $process = Start-Process @splat -ErrorAction 'Stop'
    if ($process.ExitCode -ne 0) {
        throw "Command finished with exit code: $($pocess.ExitCode)."
    }
    

    Write-Information -MessageData "Runing command: gh config set prompt disabled."
    $splat = @{
        FilePath     = "gh"
        ArgumentList = @("config", "set", "prompt", "disabled")
        Environment  = @{}
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    if ($VerbosePreference -ne 'Continue') {
        $splat += $disableRedirect
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
        if ($VerbosePreference -ne 'Continue') {
            $splat += $disableRedirect
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
    if ($VerbosePreference -ne 'Continue') {
        $splat += $disableRedirect
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
            if ($VerbosePreference -ne 'Continue') {
                $splat += $disableRedirect
            }
            if ($process.ExitCode -ne 0) {
                throw "Command finished with exit code: $($pocess.ExitCode)."
            }
        }
    }
    #Endregion
}
catch {
    Write-Error -ErrorRecord $PSItem -ErrorAction 'Continue'
    Write-Error -Exception $PSItem.Exception -ErrorAction 'Continue'
    Write-Error -Message $PSItem.ScriptStackTrace -ErrorAction 'Continue'
    return
}
finally {
    #if (-not $KeepCredential.IsPresent) {
    #    Write-Information -MessageData "Removing cached credentials."
    #    Remove-Item -Path $ghDirectory -Recurse -Force
    #}

    # Script end ---------------------------------------------------------------
    Write-Information -MessageData "Completed script execution '$($thisScript[0])'."
    $thisScript.RemoveAt(0)
}

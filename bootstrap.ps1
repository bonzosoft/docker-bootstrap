#!/usr/bin/env pwsh


#using namespace System.Collections.Generic   # List[T]
using namespace System.Management.Automation # OrderedHashtable, PSCredential


[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter()]
    [switch]$Refresh, # force logind data (vault clientid, vault clientsecret and git token) refresh

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
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Credential"   -Value ([pscredential]$null)
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Domain"       -Value ([uri]"https://eu.infisical.com")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Organization" -Value ([guid]"8008422a-830a-4a7c-8472-ab56f0172560")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Project"      -Value ([guid]"8a484bc8-4a18-468e-842c-7a264394781e")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Environment"  -Value ([string]"dev")
    Add-Member -InputObject $vaultSplat -MemberType 'NoteProperty' -Name "Token"        -Value ([securestring]$null)


    # Repository configuration -------------------------------------------------
    [pscustomobject]$repositorySplat = [pscustomobject]@{}
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Domain"       -Value ([uri]"https://github.com")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Organization" -Value ([string]"bonzosoft")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Name"         -Value ([string]"docker-deploy")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Branch"       -Value ([string]"main")
    Add-Member -InputObject $repositorySplat -MemberType 'NoteProperty'   -Name "Token"        -value ([securestring]$null)
    Add-Member -InputObject $repositorySplat -MemberTYpe 'NoteProperty'   -Name "BasePath"     -Value ([IO.DirectoryInfo]$PWD.Path)
    Add-Member -InputObject $repositorySplat -MemberType 'ScriptProperty' -Name "Path"         -Value ([scriptblock]{
        return [IO.DirectoryInfo](Join-Path -Path $this.BasePath -ChildPath @($this.Name))
    })
    Add-Member -InputObject $repositorySplat -MemberType 'ScriptProperty' -Name "Uri"          -Value ([scriptblock]{
        return [uri]::new($this.Domain, @($this.Organization, $this.Name) -join "/")
    })
   

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
        $configData = Get-Content -Path $configFile -Raw -ErrorAction 'SilentlyContinue' |
            ConvertFrom-Json -Depth 9 -AsHashtable -ErrorAction 'SilentlyContinue'
    }

    if ($configData -isnot [hashtable]) {
        [OrderedHashtable]$configData = [ordered]@{}
    }
    if ((-not $configData.ContainsKey("Vault")) -or ($configData.Vault -isnot [hashtable])) {
        [OrderedHashtable]$configData.Vault = [ordered]@{}
    }
    if ((-not $configData.Vault.ContainsKey("UserName"))) {
        $configData.Vault.UserName = [string]""
    }
    if ((-not $configData.Vault.ContainsKey("Password")) -or [string]::IsNullOrWhiteSpace($configData.Vault.Password)) {
        $configData.Vault.Password = [securestring]$null
    }
    else {
        $configData.Vault.Password = [securestring](ConvertTo-SecureString -String $configData.Vault.Password -AsPlainText -ErrorAction 'Continue')
    }
    if ((-not $configData.ContainsKey("Git")) -or ($configData.Git -isnot [hashtable])) {
        [OrderedHashtable]$configData.Git = [ordered]@{}
    }
    if ((-not $configData.Git.ContainsKey("Token")) -or [string]::IsNullOrWhiteSpace($configData.Git.Token)) {
        $configData.Git.Token = [securestring]$null
    }
    else {
        $configData.Git.Token = [securestring](ConvertTo-SecureString -String $configData.Git.Token -AsPlainText -ErrorAction 'Continue')
    }


    if ([string]::IsNullOrWhiteSpace($configData.Vault.UserName) -or 
        ($null -eq $configData.Vault.Password)) {

        do {
            # Infisical manual login
            infisical `
                login `
                --domain $vaultSplat.Domain.AbsoluteUri
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Unable to login. Press anykey to continue or 'n' to abort login."
                switch (Read-Host) {
                    {@("no", "n") -icontains $PSItem} {
                        throw "Login canceled by user."
                    }
                    default {
                        continue
                    }
                }
            }
            else {
                break
            }
        }
        while ($true)

        [string]$configData.Vault.UserName = infisical `
            sm secrets get "INFISICAL_CLIENT_ID_DEPLOYMENT_READONLY" `
            --domain $vaultSplat.Domain.AbsoluteUri `
            --projectId $vaultSplat.Project `
            --path "/" `
            --telemetry=false `
            --plain `
            --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to retrieve UserName from vault. Please check vault configuration."
        }
        if ([string]::IsNullOrWhiteSpace($configData.Vault.UserName)) {
            throw "Empty UserName. Please check vault configuration."
        }

        [string]$configData.Vault.Password = infisical `
            sm secrets get "INFISICAL_CLIENT_SECRET_DEPLOYMENT_READONLY" `
            --domain $vaultSplat.Domain.AbsoluteUri `
            --projectId $vaultSplat.Project `
            --path "/" `
            --telemetry=false `
            --plain `
            --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to retrieve Password from vault. Please check vault configuration."
        }
        if ([string]::IsNullOrWhiteSpace($configData.Vault.Password)) {
            throw "Empty Password. Please check vault configuration."
        }
        else {
            [securestring]$configData.Vault.Password = ConvertTo-SecureString -String $configData.Vault.Password -AsPlainText
        }

        # Infisical logout
        infisical `
            logout
        if ($LASTEXITCODE -ne 0) {
            throw "Command finished with exit code: $LASTEXITCODE."
        }
    }

    $splat = @{
        TypeName     = "System.Management.Automation.PSCredential"
        ArgumentList = @(
            $configData.Vault.UserName
            $configData.Vault.Password
        )
    }
    [pscredential]$vaultSplat.Credential = New-Object @splat -ErrorAction 'Stop'


    # Infisical machine login
    New-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -Value $true -Force | Out-Null
    New-Item -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" -Value $vaultSplat.Credential.GetNetworkCredential().Password -Force | Out-Null
    try {
        [string]$configData.Vault.Token = infisical login `
                --domain $vaultSplat.Domain.AbsoluteUri `
                --method=universal-auth `
                --client-id $vaultSplat.Credential.GetNetworkCredential().UserName `
                --telemetry=false `
                --plain `
                --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to login using machine credentials. Please check vault configuration."
        }
        if ([string]::IsNullOrWhiteSpace($configData.Vault.Token)) {
            throw "Unexpected error: empty vault token."
        }
        else {
            [securestring]$configData.Vault.Token = ConvertTo-SecureString -String $configData.Vault.Token -AsPlainText
            [securestring]$vaultSplat.Token = $configData.Vault.Token.Copy()
        }
    }
    finally {
        Remove-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -ErrorAction 'SilentlyContinue'
        Remove-Item -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" -ErrorAction 'SilentlyContinue'
    }


    # Get/Update Github Token
    New-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -Value $true -Force | Out-Null
    New-Item -Path "Env:\INFISICAL_TOKEN" -Value (ConvertFrom-SecureString -SecureString $vaultSplat.Token -AsPlainText) -Force | Out-Null
    try {
        [string]$configData.Git.Token = infisical sm secrets get "GITHUB_TOKEN_AST_BONZOSOFT_READONLY_ALL" `
                --domain $vaultSplat.Domain.AbsoluteUri `
                --projectId $vaultSplat.Project `
                --path "/" `
                --telemetry=false `
                --plain `
                --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to retrieve Github token. Please check vault configuration."
        }
        if ([string]::IsNullOrWhiteSpace($configData.Git.Token)) {
            throw "Empty Git token. Please check vault configuration."
        }
        else {
            [securestring]$configData.Git.Token = ConvertTo-SecureString -String $configData.Git.Token -AsPlainText
            [securestring]$repositorySplat.Token = $configData.Git.Token.Copy()
        }
    }
    finally {
        Remove-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -ErrorAction 'SilentlyContinue'
        Remove-Item -Path "Env:\INFISICAL_TOKEN" -ErrorAction 'SilentlyContinue'
    }

    if ($null -ne $repositorySplat.Token) {
        @(
                ("protocol=" + $repositorySplat.Domain.Scheme)
                ("host=" + $repositorySplat.Domain.Authority)
                ("username=" + "x-access-token")
                ("password=" + (ConvertFrom-SecureString -SecureString $repositorySplat.Token -AsPlainText))
            ) |
            git `
                -c credential.helper=cache `
                -c credential.interactive=false `
                credential `
                approve
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to approve Git credentials. Command finished with exit code: $LASTEXITCODE."
        }
    }

    if (Test-Path -Path $repositorySplat.Path -PathType 'Any') {
        Write-Information -MessageData "Removing local repository."
        Remove-Item -Path $repositorySplat.Path -Recurse -Force
    }

    git `
        -c credential.helper=cache `
        -c credential.interactive=false `
        clone `
        --branch $repositorySplat.Branch `
        --depth 1 `
        --recurse-submodules `
        --shallow-submodules `
        $repositorySplat.Uri.AbsoluteUri
    if ($LASTEXITCODE -ne 0) {
        throw "An error occurred while cloning $($repositorySplat.Name). Command finished with exit code: $LASTEXITCODE."
    }



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

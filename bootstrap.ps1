#!/usr/bin/env pwsh


#using namespace System.Collections.Generic   # List[T]
using namespace System.Management.Automation # OrderedHashtable, PSCredential


[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter()]
    [switch]$Refresh, # force refresh of login data (vault clientid and vault clientsecret)

    [Parameter()]
    [switch]$KeepCredential # keep git crednetials cache
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
   
    [IO.FileInfo]$repositoryBackup = ($repositorySplat.Path.FullName + ".bak")

    #Region - Main -------------------------------------------------------------

    # Configuration validation -------------------------------------------------
    Write-Information -MessageData "Reading local configuration."
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
    if (-not $configData.Vault.ContainsKey("UserName")) {
        $configData.Vault.UserName = [string]""
    }
    if (-not $configData.Vault.ContainsKey("Password")) {
        $configData.Vault.Password = [string]""
    }
    if ((-not $configData.ContainsKey("Git")) -or ($configData.Git -isnot [hashtable])) {
        [OrderedHashtable]$configData.Git = [ordered]@{}
    }
    if (-not $configData.Git.ContainsKey("Token")) {
        $configData.Git.Token = [string]""
    }


    if ($Refresh.IsPresent -or
        [string]::IsNullOrWhiteSpace($configData.Vault.UserName) -or 
        [string]::IsNullOrWhiteSpace($configData.Vault.Password)) {

        do {
            # Infisical manual login
            Write-Information -MessageData "Insufficient login information. Please complete manual login:"
            infisical `
                login `
                --domain $vaultSplat.Domain.AbsoluteUri `
                --silent
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

        Write-Information -MessageData "Successfull login."

        Write-Information -MessageData "Retrieving client id from vault."
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

        Write-Information -MessageData "Retrieving client secret from vault."
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

        # Infisical logout
        Write-Information -MessageData "Discarding manual login session."
        infisical `
            logout `
            --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Command finished with exit code: $LASTEXITCODE."
        }
    }

    $splat = @{
        TypeName     = "System.Management.Automation.PSCredential"
        ArgumentList = @(
            $configData.Vault.UserName
            ConvertTo-SecureString -String $configData.Vault.Password -AsPlainText
        )
    }
    [pscredential]$vaultSplat.Credential = New-Object @splat -ErrorAction 'Stop'


    # Infisical machine login
    Write-Information -MessageData "Connecting with vault."
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
            [securestring]$vaultSplat.Token = ConvertTo-SecureString -String $configData.Vault.Token -AsPlainText
        }
    }
    finally {
        Remove-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -ErrorAction 'SilentlyContinue'
        Remove-Item -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" -ErrorAction 'SilentlyContinue'
    }


    # Get/Update Github Token
    Write-Information -MessageData "Retrieving repository access token."
    New-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -Value $true -Force | Out-Null
    New-Item -Path "Env:\INFISICAL_TOKEN" -Value (ConvertFrom-SecureString -SecureString $vaultSplat.Token -AsPlainText) -Force | Out-Null
    try {
        [string]$configData.Git.Token = infisical `
                sm secrets `
                get "GITHUB_TOKEN_AST_BONZOSOFT_READONLY_ALL" `
                --domain $vaultSplat.Domain.AbsoluteUri `
                --projectId $vaultSplat.Project `
                --path "/" `
                --env $vaultSplat.Environment `
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
            [securestring]$repositorySplat.Token = ConvertTo-SecureString -String $configData.Git.Token -AsPlainText
        }
    }
    finally {
        Remove-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -ErrorAction 'SilentlyContinue'
        Remove-Item -Path "Env:\INFISICAL_TOKEN" -ErrorAction 'SilentlyContinue'
    }

    # add login information to credential helper
    Write-Information -MessageData "Adding credential data to cache."
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
        throw "Unable to validate repository credentials. Command finished with exit code: $LASTEXITCODE."
    }

    # check repository credential
    Write-Information -MessageData "Checking obtained credential."
    git `
        -c credential.helper=cache `
        -c credential.interactive=false `
        ls-remote `
        --exit-code `
        $repositorySplat.Uri.AbsoluteUri
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid repository credential. Please Check vault configuration."
    }
    else {
        # write correct cofiguration to config file
        Write-Information -MessageData "Persisting access information."
        Set-Content -Path $configFile -Value (ConvertTo-Json -InputObject $configData -Depth 9) -ErrorAction 'Continue'
    }

    
    # prepare for repository clonning
    if (Test-Path -Path $repositorySplat.Path -PathType 'Any') {
        Write-Information -MessageData "Backup up local resources."
        if (Test-Path -Path $repositoryBackup -PathType 'Any') {
            Remove-Item -Path $repositoryBackup -Force -Recurse
        }
        Move-Item -Path $repositorySplat.Path -Destination $repositoryBackup -Force
    }

    # clone repository
    Write-Information -MessageData "Cloning repository."
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
        if (Test-Path -Path $repositorySplat.Path -PathType 'Any') {
            Remove-Item -Path $repositorySplat.Path -Force -Recurse
        }
        Move-Item -Path $repositoryBackup -Destination $repositorySplat.Path -Force
        throw "An error occurred while cloning $($repositorySplat.Name). Command finished with exit code: $LASTEXITCODE."
    }
    else {
        if (Test-Path -Path $repositoryBackup -PathType 'Any') {
            Remove-Item -Path $repositoryBackup -Force -Recurse
        }
    }

    foreach ($item in @("pwsh")) {
        [IO.FIleInfo]$source = Join-Path -Path ([IO.FileInfo]$PWD.Path) -ChildPath @($repositorySplat.Name, "${item}.sh")
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
                throw "Command finished with exit code: $($process.ExitCode)."
            }
        }
    }
    #Endregion

    exit 0
}
catch {
    Write-Error -ErrorRecord $PSItem -ErrorAction 'Continue'
    Write-Error -Exception $PSItem.Exception -ErrorAction 'Continue'
    Write-Error -Message $PSItem.ScriptStackTrace -ErrorAction 'Continue'
    exit 1
}
finally {
    # Remove cached repository credentials.
    if (-not $KeepCredential.IsPresent) {
        Write-Information -MessageData "Removing cached repository credentials."
        @(
            ("protocol=" + $repositorySplat.Domain.Scheme)
            ("host=" + $repositorySplat.Domain.Authority)
            #""
        ) |
        git `
            -c credential.helper=cache `
            -c credential.interactive=false `
            credential `
            reject
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Unable to remove cached repository credentials."
        }
    
    } 

    # Script end ---------------------------------------------------------------
    Write-Information -MessageData "Completed script execution '$($thisScript[0])'."
    $thisScript.RemoveAt(0)
}

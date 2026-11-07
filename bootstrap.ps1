#!/usr/bin/env pwsh


using namespace System.Management.Automation # OrderedHashtable, PSCredential

<#
    .NOTES
        Author: bonzosoft © 2026
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [Parameter()]
    [switch]$Force,

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
    [OrderedHashtable]$splat = @{}


    # Configuration file path --------------------------------------------------
    [IO.FileInfo]$configFile = Join-Path -Path ([IO.DirectoryInfo]$PWD.Path) -ChildPath @(".config", "config.json")


    # Vault information --------------------------------------------------------
    [OrderedHashtable]$vaultSplat = [OrderedHashtable]@{
        Domain      = [uri]"https://eu.infisical.com"
        ProjectName = [string]"containers"
        Environment = [string]"dev"
    }


    # Repository information ---------------------------------------------------
    [OrderedHashtable]$repositorySplat = [OrderedHashtable]@{
        Domain       = [uri]"https://github.com"
        Organization = [string]"bonzosoft"
        Name         = [string]"docker-deploy"
        Branch       = [string]"main"
    }


    # Configuration validation -------------------------------------------------
    Write-Information -MessageData "Reading local configuration."
   
    $configFile.Refresh()
    if (-not $configFile.Directory.Exists) {
        $configFile.Directory.Create()
    }
    if (-not $configFile.Exists) {
        $configFile.Create().Dispose()
    }

    [OrderedHashtable]$configData = [OrderedHashtable]@{}
    if ($configFile.Length -ne 0) {
        $configData = `
            Get-Content `
                -Path $configFile `
                -Raw `
                -ErrorAction 'Continue' |
            ConvertFrom-Json `
                -Depth 9 `
                -AsHashtable `
                -ErrorAction 'Continue'
    }

    if ($configData -isnot [hashtable]) {
        [OrderedHashtable]$configData = [OrderedHashtable]@{}
    }
    if ((-not $configData.ContainsKey("Vault")) -or ($configData.Vault -isnot [hashtable])) {
        [OrderedHashtable]$configData.Vault = [OrderedHashtable]@{}
    }
    if (-not $configData.Vault.ContainsKey("UserName")) {
        [string]$configData.Vault.UserName = ""
    }
    if (-not $configData.Vault.ContainsKey("Password")) {
        [string]$configData.Vault.Password = ""
    }
    if ((-not $configData.ContainsKey("Git")) -or ($configData.Git -isnot [hashtable])) {
        [OrderedHashtable]$configData.Git = [OrderedHashtable]@{}
    }
    if (-not $configData.Git.ContainsKey("Token")) {
        [string]$configData.Git.Token = ""
    }

    
    # Vault object creation ----------------------------------------------------
    [pscustomobject]$vault = [pscustomobject]@{}
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Domain"       -Value ([uri]$vaultSplat.Domain)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Project"      -Value ([OrderedHashtable]@{
        Id   = [guid]::Empty
        Name = [string]$vaultSplat.ProjectName
    })
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Environment"  -Value ([string]$vaultSplat.Environment)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Credential"   -Value ([pscredential]$null)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Token"        -Value ([securestring]$null)
    

    # Repository object creation -----------------------------------------------
    [pscustomobject]$repository = [pscustomobject]@{}
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Domain"       -Value ([uri]$repositorySplat.Domain)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Organization" -Value ([string]$repositorySplat.Organization)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Name"         -Value ([string]$repositorySplat.Name)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Branch"       -Value ([string]$repositorySplat.Branch)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Token"        -Value ([securestring]$null)
    Add-Member -InputObject $repository -MemberTYpe 'NoteProperty'   -Name "Path"         -Value ([IO.DirectoryInfo]$PWD.Path)
    Add-Member -InputObject $repository -MemberType 'ScriptProperty' -Name "FullName"     -Value ([scriptblock]{
        [IO.DirectoryInfo]$output = [IO.Path]::Join( [string[]]@($this.Directory, $this.Name) )
        return $output
    })
    Add-Member -InputObject $repository -MemberType 'ScriptProperty' -Name "Uri"          -Value ([scriptblock]{
        [uri]$output = [uri]::new($this.Domain, @($this.Organization, $this.Name) -join "/")
        return $output
    })
   

    # Manual login -------------------------------------------------------------
    if ($Force.IsPresent -or
        [string]::IsNullOrWhiteSpace($configData.Vault.UserName) -or 
        [string]::IsNullOrWhiteSpace($configData.Vault.Password)) {

        do {
            Write-Information -MessageData "Please complete manual login to $($vault.Domain.Host):"
            $vault.Token = `
                infisical `
                    login `
                    --domain $vault.Domain.AbsoluteUri `
                    --silent `
                    --plain
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Unable to login. Press any key to continue or 'n' to abort login."

                if (( Read-Host ) -iin @("no", "n")) {
                    throw "Login canceled by user request."
                }
            }
            else {
                Write-Information -MessageData "Successful login."
                break
            }
        }
        while ($true)

        Write-Information -MessageData "Retrieving project id from vault."
        $vault.Project.Id = `
            infisical `
                sm `
                projects `
                list `
                --output=json |
            ConvertFrom-Json `
                -Depth 9 `
                -AsHashtable |
            ForEach-Object -Process {
                if ($PSItem.name -eq $vault.Project.Name) {
                    return $PSItem.id
                }
            }
        if ($vault.Project.Id -eq [guid]::Empty) {
            throw "Project name not found in Vault."
        }

        Write-Information -MessageData "Retrieving client id from vault."
        infisical `
            sm secrets get `
            "INFISICAL_CLIENT_ID_DEPLOYMENT_READONLY" `
            "INFISICAL_CLIENT_SECRET_DEPLOYMENT_READONLY" `
            --domain $vault.Domain.AbsoluteUri `
            --projectId $vault.Project.Id `
            --path "/" `
            --telemetry=false `
            --plain `
            --silent |
        ForEach-Object `
            -Process {
                switch ($PSItem.secretKey) {
                    "INFISICAL_CLIENT_ID_DEPLOYMENT_READONLY" {
                        $configData.Vault.UserName = $PSItem.secretValue
                    }
                    "INFISICAL_CLIENT_SECRET_DEPLOYMENT_READONLY" {
                        $configData.Vault.Password = `
                            ConvertTo-SecureString `
                                -String $PSItem.secretValue `
                                -AsPlainText
                    }
                    default {
                        throw "Unexpected secret."
                    }
                }
            }
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to retrieve UserName from vault. Please check vault configuration."
        }
        #if ([string]::IsNullOrWhiteSpace($configData.Vault.UserName)) {
        #    throw "Empty UserName. Please check vault configuration."
        #}

        #Write-Information -MessageData "Retrieving client secret from vault."
        #[string]$configData.Vault.Password = infisical `
        #    sm secrets get "INFISICAL_CLIENT_SECRET_DEPLOYMENT_READONLY" `
        #    --domain $vault.Domain.AbsoluteUri `
        #    --projectId $vault.Project.Id `
        #    --path "/" `
        #    --telemetry=false `
        #    --plain `
        #    --silent
        #if ($LASTEXITCODE -ne 0) {
        #    throw "Unable to retrieve Password from vault. Please check vault configuration."
        #}
        #if ([string]::IsNullOrWhiteSpace($configData.Vault.Password)) {
        #    throw "Empty Password. Please check vault configuration."
        #}

        # Infisical logout
        Write-Information -MessageData "Discarding manual login session."
        infisical `
            logout `
            --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Command finished with exit code: $LASTEXITCODE."
        }
    }
    
    # Vault credential ---------------------------------------------------------
    $vault.Credential = `
        New-Object `
            -TypeName "System.Management.Automation.PSCredential" `
            -ArgumentList @(
                $configData.Vault.UserName
                ConvertTo-SecureString -String $configData.Vault.Password -AsPlainText
            ) `
            -ErrorAction 'Stop'


    # Infisical machine login --------------------------------------------------
    Write-Information -MessageData "Connecting with vault."
    New-Item `
        -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" `
        -Value $true `
        -Force |
    Out-Null

    New-Item `
        -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" `
        -Value $vault.Credential.GetNetworkCredential().Password -Force |
    Out-Null
    try {
        [string]$configData.Vault.Token = infisical `
                login `
                --domain $vault.Domain.AbsoluteUri `
                --method=universal-auth `
                --client-id $vault.Credential.GetNetworkCredential().UserName `
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
            [securestring]$vault.Token = ConvertTo-SecureString -String $configData.Vault.Token -AsPlainText
        }
    }
    finally {
        Remove-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -ErrorAction 'SilentlyContinue'
        Remove-Item -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" -ErrorAction 'SilentlyContinue'
    }


    # Get/Update Github Token
    Write-Information -MessageData "Retrieving repository access token."
    New-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -Value $true -Force | Out-Null
    New-Item -Path "Env:\INFISICAL_TOKEN" -Value (ConvertFrom-SecureString -SecureString $vault.Token -AsPlainText) -Force | Out-Null
    try {
        [string]$configData.Git.Token = infisical `
                sm secrets `
                get "GITHUB_TOKEN_AST_BONZOSOFT_READONLY_ALL" `
                --domain $vault.Domain.AbsoluteUri `
                --projectId $vault.Project.Id `
                --path "/" `
                --env $vault.Environment `
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
            [securestring]$repository.Token = ConvertTo-SecureString -String $configData.Git.Token -AsPlainText
        }
    }
    finally {
        Remove-Item -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" -ErrorAction 'SilentlyContinue'
        Remove-Item -Path "Env:\INFISICAL_TOKEN" -ErrorAction 'SilentlyContinue'
    }

    # add login information to credential helper
    Write-Information -MessageData "Adding credential data to cache."
    @(
        ("protocol=" + $repository.Domain.Scheme)
        ("host=" + $repository.Domain.Authority)
        ("username=" + "x-access-token")
        ("password=" + (ConvertFrom-SecureString -SecureString $repository.Token -AsPlainText))
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
        $repository.Uri.AbsoluteUri
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid repository credential. Please Check vault configuration."
    }
    else {
        # write correct cofiguration to config file
        Write-Information -MessageData "Persisting access information."
        Set-Content -Path $configFile -Value (ConvertTo-Json -InputObject $configData -Depth 9) -ErrorAction 'Continue'
    }

    [IO.FileInfo]$repositoryBackup = ($repository.FullName.FullName + ".bak")
    # prepare for repository clonning
    if (Test-Path -Path $repository.Path -PathType 'Any') {
        Write-Information -MessageData "Backup up local resources."
        if (Test-Path -Path $repositoryBackup -PathType 'Any') {
            Remove-Item -Path $repositoryBackup -Force -Recurse
        }
        Move-Item -Path $repository.Path -Destination $repositoryBackup -Force
    }

    # clone repository
    Write-Information -MessageData "Cloning repository."
    git `
        -c credential.helper=cache `
        -c credential.interactive=false `
        clone `
        --branch $repository.Branch `
        --depth 1 `
        --recurse-submodules `
        --shallow-submodules `
        $repository.Uri.AbsoluteUri
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -Path $repository.Path -PathType 'Any') {
            Remove-Item -Path $repository.Path -Force -Recurse
        }
        Move-Item -Path $repositoryBackup -Destination $repository.Path -Force
        throw "An error occurred while cloning $($repository.Name). Command finished with exit code: $LASTEXITCODE."
    }
    else {
        if (Test-Path -Path $repositoryBackup -PathType 'Any') {
            Remove-Item -Path $repositoryBackup -Force -Recurse
        }
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

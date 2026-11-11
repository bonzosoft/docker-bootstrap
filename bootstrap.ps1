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
    [OrderedHashtable]$splat = [OrderedHashtable]@{}


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
    Write-Information -MessageData "Reading stored information."
   
    [OrderedHashtable]$configData = [OrderedHashtable]@{}

    $configFile.Refresh()

    if (-not $configFile.Directory.Exists) {
        $configFile.Directory.Create()
    }
    if (-not $configFile.Exists) {
        $configFile.Create().Dispose()
    }

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
    [bool]$invalidCredentials = $false
    [pscustomobject]$vault = [pscustomobject]@{}

    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Domain"       -Value ([uri]$vaultSplat.Domain)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "ProjectName"  -Value ([string]$vaultSplat.ProjectName)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "ProjectId"    -Value ([guid]::Empty)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Environment"  -Value ([string]$vaultSplat.Environment)
    Add-Member -InputObject $vault -MemberType 'NoteProperty' -Name "Credential"   -Value ([pscustomobject]@{
        UserName = `
            if ([string]::IsNullOrWhiteSpace($configData.Vault.UserName)) {
                $invalidCredentials = $true
                [guid]::Empty
            }
            else {
                [guid]::Parse($configData.Vault.UserName)
            }
        Password = `
            if ([string]::IsNullOrWhiteSpace($configData.Vault.Password)) {
                $invalidCredentials = $true
                [securestring]@{}
            }
            else {
                ConvertTo-SecureString -String $configData.Vault.Password -AsPlainText
            }
        Token = [securestring]@{}
    })


    # Repository object creation -----------------------------------------------
    [pscustomobject]$repository = [pscustomobject]@{}

    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Domain"       -Value ([uri]$repositorySplat.Domain)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Organization" -Value ([string]$repositorySplat.Organization)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Name"         -Value ([string]$repositorySplat.Name)
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Branch"       -Value ([string]$repositorySplat.Branch)
    Add-Member -InputObject $repository -MemberTYpe 'NoteProperty'   -Name "Path"         -Value ([IO.DirectoryInfo]$PWD.Path)
    Add-Member -InputObject $repository -MemberType 'ScriptProperty' -Name "FullName"     -Value ([scriptblock]{
        [IO.DirectoryInfo][IO.Path]::Join( [string[]]@($this.Path.FullName, $this.Name) )
    })
    Add-Member -InputObject $repository -MemberType 'ScriptProperty' -Name "Uri"          -Value ([scriptblock]{
        [uri]::new($this.Domain, @($this.Organization, $this.Name) -join "/")
    })
    Add-Member -InputObject $repository -MemberType 'NoteProperty'   -Name "Token"        -Value ([pscustomobject]@{
        Token = `
            if ([string]::IsNullOrWhiteSpace($configData.Git.Token)) {
                [securestring]@{}
            }
            else {
                ConvertTo-SecureString -String $configData.Git.Token -AsPlainText
            }
    })
    

    enum AuthenticationState {
        Start
        ManualLogin
        RetrieveProject
        RetrieveCredentials
        Logout
        InitialUniversalAuth
        FinalUniversalAuth
        Authenticated
        Failed
    }


    New-Item `
        -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" `
        -Value $true `
        -Force |
    Out-Null


    # Authentication state machine ---------------------------------------------
    $state = [AuthenticationState]::Start
    $failure = $null

    while ($state -notin @([AuthenticationState]::Authenticated, [AuthenticationState]::Failed)) {
        try {
            switch ($state) {

                # Initial state ------------------------------------------------
                Start {
                    if ($invalidCredentials -or $Force.IsPresent) {
                        $state = [AuthenticationState]::ManualLogin
                    }
                    else {
                        $state = [AuthenticationState]::InitialUniversalAuth
                    }
                }


                # Manual login ---------------------------------------------------
                ManualLogin {
                    do {
                        Clear-Host

                        Write-Information -MessageData "Please complete manual login to $($vault.Domain.Host):"

                        $vault.Credential.Token = `
                            infisical `
                                login `
                                --domain $vault.Domain.AbsoluteUri `
                                --silent `
                                --plain |
                            ConvertTo-SecureString `
                                -AsPlainText

                        if ($LASTEXITCODE -ne 0) {
                            Clear-Host

                            Write-Host "Unable to login. Press any key to continue or 'n' to abort login."

                            if ((Read-Host) -iin @("no", "n")) {
                                throw "Login canceled by user request."
                            }
                        }
                        else {
                            Write-Information -MessageData "Login successful."
                            break
                        }
                    }
                    while ($true)

                    $state = [AuthenticationState]::RetrieveProject
                }


                # Retrieve project id -------------------------------------------
                RetrieveProject {
                    Write-Information -MessageData "Retrieving project id from vault."

                    $vault.ProjectId = `
                        infisical `
                            sm projects list `
                            --domain $vault.Domain.AbsoluteUri `
                            --output=json `
                            --telemetry=false |
                        ConvertFrom-Json `
                            -Depth 9 `
                            -AsHashtable |
                        ForEach-Object -Process {
                            if ($PSItem.name -eq $vault.ProjectName) {
                                return [guid]::Parse($PSItem.id)
                            }
                        }

                    if ($LASTEXITCODE -ne 0) {
                        throw "Unable to retrieve project id from vault. Please check vault configuration."
                    }

                    if ($null -eq $vault.ProjectId -or $vault.ProjectId -eq [guid]::Empty) {
                        throw "Project not found in vault."
                    }

                    if ($vault.ProjectId -ne [guid]::Empty) {
                        $state = [AuthenticationState]::Authenticated
                    }
                    else {
                        $state = [AuthenticationState]::RetrieveCredentials
                    }
                }


                # Retrieve Universal Auth credentials --------------------------
                RetrieveCredentials {
                    Write-Information -MessageData "Retrieving access information from vault."

                    infisical `
                        sm secrets get `
                        "INFISICAL_CLIENT_ID_DEPLOYMENT_READONLY" `
                        "INFISICAL_CLIENT_SECRET_DEPLOYMENT_READONLY" `
                        --domain $vault.Domain.AbsoluteUri `
                        --projectId $vault.ProjectId `
                        --env $vault.Environment `
                        --path "/" `
                        --output json `
                        --telemetry=false `
                        6> $null 5> $null 4> $null 3> $null 2> $null |
                    ConvertFrom-Json `
                        -AsHashtable |
                    ForEach-Object -Process {
                        $item = $PSItem

                        switch ($item.secretKey) {
                            "INFISICAL_CLIENT_ID_DEPLOYMENT_READONLY" {
                                $vault.Credential.UserName = [guid]::Parse($item.secretValue)
                            }

                            "INFISICAL_CLIENT_SECRET_DEPLOYMENT_READONLY" {
                                $vault.Credential.Password = $item.secretValue |
                                    ConvertTo-SecureString -AsPlainText
                            }

                            default {
                                throw "Unexpected secret."
                            }
                        }
                    }

                    if ($LASTEXITCODE -ne 0) {
                        throw "Unable to retrieve access data from vault. Please check vault configuration."
                    }

                    if ($vault.Credential.UserName -eq [guid]::Empty) {
                        throw "Unable to retrieve client id from vault."
                    }

                    if ($vault.Credential.Password.Length -eq 0) {
                        throw "Unable to retrieve client secret from vault."
                    }

                    $state = [AuthenticationState]::Logout
                }


                # Discard manual login session -------------------------------
                Logout {
                    Write-Information -MessageData "Discard manual login session."

                    infisical `
                        logout `
                        --silent `
                        6> $null 5> $null 4> $null 3> $null 2> $null 1> $null

                    if ($LASTEXITCODE -ne 0) {
                        throw "Unable to end vault session."
                    }

                    $state = [AuthenticationState]::FinalUniversalAuth
                }


                # Universal Auth -------------------------------------------------
                {$PSItem -in @([AuthenticationState]::InitialUniversalAuth, [AuthenticationState]::FinalUniversalAuth)} {

                    # Check vault credentials -----------------------------------
                    New-Item `
                        -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" `
                        -Value (
                            ConvertFrom-SecureString `
                                -SecureString $vault.Credential.Password `
                                -AsPlainText
                        ) `
                        -Force |
                    Out-Null

                    try {
                        # Vault machine login ------------------------------------
                        Write-Information -MessageData "Connecting with vault."

                        $vault.Credential.Token = `
                            infisical `
                                login `
                                --domain $vault.Domain.AbsoluteUri `
                                --method=universal-auth `
                                --client-id $vault.Credential.UserName `
                                --telemetry=false `
                                --plain `
                                --silent |
                            ConvertTo-SecureString `
                                -AsPlainText

                        if ($LASTEXITCODE -ne 0) {
                            if ($state -eq [AuthenticationState]::FinalUniversalAuth) {
                                throw "Machine authentication failed."
                            }

                            Write-Information -MessageData "Machine authentication failed. Falling back to manual login."

                            $state = [AuthenticationState]::ManualLogin
                        }
                        else {
                            $state = [AuthenticationState]::RetrieveProject
                        }
                    }
                    finally {
                        Remove-Item `
                            -Path "Env:\INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" `
                            -ErrorAction 'SilentlyContinue'
                    }
                }
            }
        }
        catch {
            $failure = $PSItem
            $state = [AuthenticationState]::Failed
        }
    }


    # Terminal states -------------------------------------------------------------

    if ($state -eq [AuthenticationState]::Failed) {
        throw $failure
    }

    Write-Information -MessageData "Authentication successful."


    # Vault credential ---------------------------------------------------------
    $configData.Vault.UserName = $vault.Credential.UserName
    $configData.Vault.Password = $vault.Credential.Password | ConvertFrom-SecureString -AsPlainText
    Set-Content -Path $configFile -Value (ConvertTo-Json -InputObject $configData -Depth 9) -ErrorAction 'Continue'

    
        # Retrieve git token ---------------------------------------------------
        Write-Information -MessageData "Retrieving repository access token."


        New-Item `
        -Path "Env:\INFISICAL_TOKEN" `
        -Value (
            ConvertFrom-SecureString `
                -SecureString $vault.Credential.Token `
                -AsPlainText
        ) `
        -Force |
    Out-Null
        try {
            $repository.Token = `
                infisical `
                    sm secrets `
                    get "GITHUB_TOKEN_AST_BONZOSOFT_READONLY_ALL" `
                    --domain $vault.Domain.AbsoluteUri `
                    --projectId $vault.ProjectId `
                    --path "/" `
                    --env $vault.Environment `
                    --telemetry=false `
                    --plain `
                    --silent |
                ConvertTo-SecureString `
                    -AsPlainText
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to retrieve Github token. Please check vault configuration."
            }
            if ($repository.Token.Length -eq 0) {
                throw "Empty Git token. Please check vault configuration."
            }
        }
        finally {
            Remove-Item `
            -Path "Env:\INFISICAL_TOKEN" `
            -ErrorAction 'SilentlyContinue'
        }



    # add login information to credential helper -------------------------------
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


    # check repository credential ----------------------------------------------
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
        [string]$configData.Git.Token = ConvertFrom-SecureString -SecureString $repository.Token -AsPlainText
        Set-Content -Path $configFile -Value (ConvertTo-Json -InputObject $configData -Depth 9) -ErrorAction 'Continue'
    }

    
    # prepare for repository clonning ------------------------------------------
    [IO.FileInfo]$repositoryBackup = ($repository.FullName.FullName + ".bak")

    if (Test-Path -Path $repository.Path -PathType 'Any') {
        Write-Information -MessageData "Backup up local resources."
        if (Test-Path -Path $repositoryBackup -PathType 'Any') {
            Remove-Item -Path $repositoryBackup -Force -Recurse
        }
        Move-Item -Path $repository.Path -Destination $repositoryBackup -Force
    }
    

    # clone repository ---------------------------------------------------------
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

    exit 0
}
catch {
    Write-Error -ErrorRecord $PSItem -ErrorAction 'Continue'
    #Write-Error -Exception $PSItem.Exception -ErrorAction 'Continue'
    Write-Error -Message $PSItem.ScriptStackTrace -ErrorAction 'Continue'
    exit 1
}
finally {
    # Remove update check configuration ----------------------------------------
    Remove-Item `
        -Path "Env:\INFISICAL_DISABLE_UPDATE_CHECK" `
        -ErrorAction 'SilentlyContinue'


    # Remove cached repository credentials -------------------------------------
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

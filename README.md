
# Bootstrap

Para iniciar el procedimiento se puede iniciar desde ``bash`` con el comando:

````bash
docker run --rm -it -v ${PWD}:${PWD}:rw -w ${PWD} ghcr.io/bonzosoft/pwsh pwsh -NoLogo -NoProfile -NoExit -Command '$name = "bootstrap"; $branch = "main"; $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid()); git clone --branch $branch --single-branch --depth 1 https://github.com/bonzosoft/$name.git $path; & (Join-Path -Path $path -ChildPath bootstrap.ps1); Remove-Item -Path $path -Recurse -Force'
````

Si ya está iniciado el contenedor con ``pwsh`` se puede usar el comando:
````powershell
$name = "bootstrap"; $branch = "main"; $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid()); git clone --branch $branch --single-branch --depth 1 https://github.com/bonzosoft/$name.git $path; & (Join-Path -Path $path -ChildPath bootstrap.ps1); Remove-Item -Path $path -Recurse -Force
````
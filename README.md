
# Bootstrap

Para iniciar el procedimiento se puede iniciar desde ``bash`` con el comando:

````bash
docker run --rm -it -v ${PWD}:${PWD}:rw -w ${PWD} ghcr.io/bonzosoft/pwsh pwsh -NoLogo -NoProfile -NoExit -Command '$name = "docker-bootstrap"; $branch = "main"; $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid()); git clone --branch $branch --single-branch --depth 1 https://github.com/bonzosoft/$name.git $path; & (Join-Path -Path $path -ChildPath bootstrap.ps1); Remove-Item -Path $path -Recurse -Force; exit'
````

Si se desea mantener las credenciales usadas para descargar el repositorio (entorno de desarrollo) se puede usar:

````bash
docker run --rm -it -v ${PWD}:${PWD}:rw -w ${PWD} ghcr.io/bonzosoft/pwsh pwsh -NoLogo -NoProfile -NoExit -Command '$name = "docker-bootstrap"; $branch = "main"; $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid()); git clone --branch $branch --single-branch --depth 1 https://github.com/bonzosoft/$name.git $path; & (Join-Path -Path $path -ChildPath bootstrap.ps1) -KeepCredential; Remove-Item -Path $path -Recurse -Force; exit'
````
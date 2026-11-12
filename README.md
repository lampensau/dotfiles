# dotfiles bootstrap

A bootstrap for a fresh machine. It installs the prerequisites that need no secrets, waits until an SSH agent with a key is available, then clones a private dotfiles repo and hands over to that repo's install script. The private repo's URL is asked at run time; nothing about it is stored here.

On Linux (Arch, Debian and Fedora families) `bootstrap.sh` installs git, curl, fish, the OpenSSH client tools and chezmoi (from the distro, or the upstream installer where there is no package), and optionally the Bitwarden desktop app (distro package on Arch, Flatpak elsewhere). For an SSH URL it waits for the Bitwarden SSH agent to hold a key, shows the forge's host key fingerprints for you to confirm, clones into `~/.dotfiles` and runs its `install.sh`. On Windows `bootstrap.ps1` does the equivalent with winget.

Linux: `curl -fsSLO https://raw.githubusercontent.com/lampensau/dotfiles/main/bootstrap.sh && bash bootstrap.sh`

Windows (PowerShell 5.1): `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing https://github.com/lampensau/dotfiles/archive/refs/heads/main.zip -OutFile dotfiles.zip; Expand-Archive -Force dotfiles.zip -DestinationPath dotfiles-src; powershell -ExecutionPolicy Bypass -File .\dotfiles-src\dotfiles-main\bootstrap.ps1`

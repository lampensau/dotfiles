#!/usr/bin/env bash
# Runs bootstrap.sh in throwaway containers. Needs docker on the host.
# usage: bash test/container.sh [image...]
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
images=("$@")
[ "${#images[@]}" -gt 0 ] || images=(archlinux:latest debian:trixie fedora:latest)

# Runs inside the container. $1 is "file" (full run against a local bare repo)
# or "ssh" (quit at the agent prompt).
inner=$(
    cat <<'EOF'
set -u
if [ "$1" = file ]; then
    # Fixture only: the bare repo needs git before bootstrap.sh has installed it.
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm git
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y git
    else
        dnf install -y git
    fi >/dev/null 2>&1
    git init -q -b main /tmp/w
    cat >/tmp/w/install.sh <<'INSTALL'
for c in git curl fish chezmoi; do
    command -v "$c" >/dev/null 2>&1 || echo "MISSING $c"
done
echo "handover ok"
INSTALL
    git -C /tmp/w add install.sh
    git -C /tmp/w -c user.name=t -c user.email=t@t commit -q -m fixture
    git clone -q --bare /tmp/w /srv/private.git
    printf 'n\nfile:///srv/private.git\n' | bash /bootstrap/bootstrap.sh
    exit $?
fi
printf 'n\nssh://git@example.invalid/x.git\nq\n' | bash /bootstrap/bootstrap.sh
rc=$?
PATH=$HOME/.local/bin:$PATH
for c in git curl fish chezmoi ssh-keyscan; do
    command -v "$c" >/dev/null 2>&1 || echo "MISSING $c"
done
exit $rc
EOF
)

fail=0
report() { # report STATUS NAME [DETAIL]
    echo "$1 $2${3:+: $3}"
    [ "$1" = PASS ] || fail=1
}

for image in "${images[@]}"; do
    out=$(docker run --rm -v "$root:/bootstrap:ro" "$image" bash -c "$inner" _ file 2>&1)
    rc=$?
    last=${out##*$'\n'}
    if [ "$rc" -eq 0 ] && [ "$last" = "handover ok" ] && [[ $out != *MISSING* ]]; then
        report PASS "$image file clone and handover"
    else
        report FAIL "$image file clone and handover" "rc=$rc"
        echo "$out" | tail -n 25
    fi

    out=$(docker run --rm -v "$root:/bootstrap:ro" "$image" bash -c "$inner" _ ssh 2>&1)
    rc=$?
    if [ "$rc" -eq 1 ] && [[ $out == *"No SSH agent with a key found"* ]] &&
        [[ $out == *"Bitwarden"* ]] && [[ $out != *MISSING* ]]; then
        report PASS "$image ssh url quits at agent prompt"
    else
        report FAIL "$image ssh url quits at agent prompt" "rc=$rc"
        echo "$out" | tail -n 25
    fi
done

exit "$fail"

#!/bin/bash
set -e
# create a sudo user 'kali' (password: kali) and make it the WSL default
if ! id kali >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo kali
fi
echo "kali:kali" | chpasswd
echo "kali ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/kali
chmod 440 /etc/sudoers.d/kali
printf '[user]\ndefault=kali\n[boot]\nsystemd=true\n' > /etc/wsl.conf
echo "WHOAMI=$(whoami)"
id kali
echo "--- routes ---"
ip route 2>/dev/null | head -5 || true

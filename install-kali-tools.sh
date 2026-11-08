#!/bin/bash
# PJPT attacker toolset for Kali WSL. Logs to /root/kali-tools.log
exec > >(tee -a /root/kali-tools.log) 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  netexec impacket-scripts responder enum4linux enum4linux-ng \
  smbclient nmap ldap-utils krb5-user python3-impacket \
  evil-winrm hydra john hashcat seclists bloodhound neo4j \
  dnsutils mingw-w64 2>&1 || true
echo "TOOLS_INSTALL_DONE rc=$?"

#!/usr/bin/env bash
# Meridian lab: deploy MFG-DC01 (Windows Server 2022) with the Azure CLI.
# Run from your Mac:  brew install azure-cli && az login && bash lab/00-Deploy-LabVM.sh
#
# Same result as the portal steps in docs/WALKTHROUGH.md, Phase 1. RDP is only
# opened to your current public IP, and the VM shuts itself down every night.
set -euo pipefail

RG="${RG:-rg-meridian-iam-lab}"
LOCATION="${LOCATION:-centralus}"
VM="${VM:-MFG-DC01}"
SIZE="${SIZE:-Standard_B2ms}"
ADMIN_USER="${ADMIN_USER:-mfgadmin}"
SHUTDOWN_UTC="${SHUTDOWN_UTC:-0400}"   # 11 PM US Central (CDT)

MY_IP="$(curl -s https://api.ipify.org)"
echo "Your public IP: ${MY_IP} (RDP will be allowed from this address only)"
read -r -s -p "Local admin password for ${ADMIN_USER} (12+ chars, complex): " ADMIN_PW; echo

az group create -n "$RG" -l "$LOCATION" -o none

az network vnet create -g "$RG" -n vnet-meridian --address-prefix 10.20.0.0/16 \
  --subnet-name snet-identity --subnet-prefix 10.20.1.0/24 -o none

az network nsg create -g "$RG" -n nsg-identity -o none
az network nsg rule create -g "$RG" --nsg-name nsg-identity -n Allow-RDP-MyIP --priority 100 \
  --source-address-prefixes "${MY_IP}/32" --destination-port-ranges 3389 --protocol Tcp --access Allow -o none
az network vnet subnet update -g "$RG" --vnet-name vnet-meridian -n snet-identity --network-security-group nsg-identity -o none

az network public-ip create -g "$RG" -n pip-mfg-dc01 --sku Standard --allocation-method Static -o none
az network nic create -g "$RG" -n nic-mfg-dc01 --vnet-name vnet-meridian --subnet snet-identity \
  --private-ip-address 10.20.1.4 --public-ip-address pip-mfg-dc01 -o none

az vm create -g "$RG" -n "$VM" --nics nic-mfg-dc01 --size "$SIZE" \
  --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest \
  --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PW" \
  --os-disk-name osdisk-mfg-dc01 --storage-sku StandardSSD_LRS -o none

az vm auto-shutdown -g "$RG" -n "$VM" --time "$SHUTDOWN_UTC" -o none

# After the VM is promoted to a DC it becomes the DNS server for the VNet.
az network vnet update -g "$RG" -n vnet-meridian --dns-servers 10.20.1.4 -o none

echo
echo "Done. Public IP: $(az network public-ip show -g "$RG" -n pip-mfg-dc01 --query ipAddress -o tsv)"
echo "Connect with the Windows App on your Mac as ${ADMIN_USER}."

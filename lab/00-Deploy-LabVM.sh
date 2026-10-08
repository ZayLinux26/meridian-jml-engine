#!/usr/bin/env bash
# Meridian lab: deploy the two lab servers with the Azure CLI.
#   MFG-DC01    Windows Server 2022 Server Core, the domain controller (10.20.0.4)
#   MFG-MGMT01  Windows Server 2022 with Desktop, the management server that runs
#               RSAT, the Entra Cloud Sync agent and the JML engine (10.20.0.5)
#
# Run from your Mac:  brew install azure-cli && az login && bash lab/00-Deploy-LabVM.sh
#
# Same result as the portal steps in docs/WALKTHROUGH.md, Phase 1. RDP is only
# opened to your current public IPv4 address, and both VMs shut down every night.
set -euo pipefail

RG="${RG:-rg-meridian-iam-lab}"
LOCATION="${LOCATION:-centralus}"
SIZE="${SIZE:-Standard_B2ms}"          # B-series v1; use a Bsv2 size if your region has quota
ADMIN_USER="${ADMIN_USER:-mfgadmin}"
SHUTDOWN_UTC="${SHUTDOWN_UTC:-0400}"   # 11 PM US Central (CDT)

# -4 matters: iCloud Private Relay and some ISPs hand out IPv6 or relay
# addresses that will never match the NSG rule.
MY_IP="$(curl -4 -s https://api.ipify.org)"
echo "Your public IP: ${MY_IP} (RDP will be allowed from this address only)"
read -r -s -p "Local admin password for ${ADMIN_USER} (12+ chars, complex): " ADMIN_PW; echo

az group create -n "$RG" -l "$LOCATION" -o none

az network vnet create -g "$RG" -n vnet-meridian --address-prefix 10.20.0.0/16 \
  --subnet-name snet-identity --subnet-prefix 10.20.0.0/24 -o none

az network nsg create -g "$RG" -n nsg-identity -o none
az network nsg rule create -g "$RG" --nsg-name nsg-identity -n Allow-RDP-MyIP --priority 100 \
  --source-address-prefixes "${MY_IP}/32" --destination-port-ranges 3389 --protocol Tcp --access Allow -o none
az network vnet subnet update -g "$RG" --vnet-name vnet-meridian -n snet-identity --network-security-group nsg-identity -o none

deploy_vm () {
  local name="$1" ip="$2" image="$3" lower
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  az network public-ip create -g "$RG" -n "pip-${lower}" --sku Standard --allocation-method Static -o none
  az network nic create -g "$RG" -n "nic-${lower}" --vnet-name vnet-meridian --subnet snet-identity \
    --private-ip-address "$ip" --public-ip-address "pip-${lower}" -o none
  az vm create -g "$RG" -n "$name" --nics "nic-${lower}" --size "$SIZE" --image "$image" \
    --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PW" \
    --os-disk-name "osdisk-${lower}" --storage-sku StandardSSD_LRS -o none
  az vm auto-shutdown -g "$RG" -n "$name" --time "$SHUTDOWN_UTC" -o none
}

echo "Deploying MFG-DC01 (Server Core)..."
deploy_vm MFG-DC01 10.20.0.4 MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition-core:latest

# The DC becomes the DNS server for the VNet. MFG-MGMT01 needs this to join the domain.
az network vnet update -g "$RG" -n vnet-meridian --dns-servers 10.20.0.4 -o none

echo "Deploying MFG-MGMT01 (Desktop Experience)..."
deploy_vm MFG-MGMT01 10.20.0.5 MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest

echo
echo "Done."
echo "  MFG-DC01   public IP: $(az network public-ip show -g "$RG" -n pip-mfg-dc01 --query ipAddress -o tsv)"
echo "  MFG-MGMT01 public IP: $(az network public-ip show -g "$RG" -n pip-mfg-mgmt01 --query ipAddress -o tsv)"
echo "Connect with the Windows App on your Mac as ${ADMIN_USER}. Promote MFG-DC01 first (Phase 3)."

#!/bin/bash

# SQL Server HA Setup using VM Extensions
# This script deploys SQL Server HA configuration using Custom Script Extensions

set -e

# Load deployment variables
source ./scripts/deployment-variables.sh

# Variables for AG setup
AG_NAME="SQLAG"
LISTENER_NAME="sqlhagrp"
LB_NAME="lb-sqlha"
PROBE_PORT=59999
LISTENER_IP="10.0.0.10"
LOG_FILE="ag-setup-$(date +%s).log"

# Function for logging
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ${message}" | tee -a "${LOG_FILE}"
}

log "Starting SQL Server Availability Group setup with VM Extensions"

# Retrieve SQL credentials from Key Vault
log "Retrieving credentials from Key Vault..."
ADMIN_USERNAME=$(az keyvault secret show --vault-name $KV_NAME --name SqlAdminUsername --query value -o tsv)
ADMIN_PASSWORD=$(az keyvault secret show --vault-name $KV_NAME --name SqlAdminPassword --query value -o tsv)

# 1. Create Internal Load Balancer
log "Creating internal load balancer for SQL AG..."
SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --query id -o tsv)

az network lb create \
  --name $LB_NAME \
  --resource-group $RESOURCE_GROUP \
  --sku Standard \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --frontend-ip-name "FrontendIP" \
  --backend-pool-name "BackendPool" \
  --private-ip-address $LISTENER_IP

# 2. Create health probe and load balancing rule for SQL traffic
log "Creating health probe and load balancing rules..."
az network lb probe create \
  --resource-group $RESOURCE_GROUP \
  --lb-name $LB_NAME \
  --name "SQLProbe" \
  --protocol tcp \
  --port $PROBE_PORT

az network lb rule create \
  --resource-group $RESOURCE_GROUP \
  --lb-name $LB_NAME \
  --name "SQLRule" \
  --protocol tcp \
  --frontend-port 1433 \
  --backend-port 1433 \
  --frontend-ip-name "FrontendIP" \
  --backend-pool-name "BackendPool" \
  --probe-name "SQLProbe" \
  --floating-ip true \
  --disable-outbound-snat true

# 3. Add SQL VMs to the backend pool
log "Adding SQL VMs to the load balancer backend pool..."
for i in 1 2; do
  VM_NAME="${VM_PREFIX}${i}"
  NIC_NAME="${VM_NAME}-nic"
  
  az network nic ip-config address-pool add \
    --resource-group $RESOURCE_GROUP \
    --nic-name $NIC_NAME \
    --ip-config-name "ipconfig1" \
    --lb-name $LB_NAME \
    --address-pool "BackendPool"
done

# 4. Create a storage account for the script
RANDOM_SUFFIX=$(date +%s | tail -c 8)
STORAGE_ACCOUNT_NAME="sqlhascript${RANDOM_SUFFIX}"

log "Creating storage account ${STORAGE_ACCOUNT_NAME}..."
az storage account create \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2

# Wait for storage account creation to complete
sleep 10

# Get storage account key
STORAGE_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT_NAME \
  --query "[0].value" -o tsv)

# Create container
az storage container create \
  --name scripts \
  --account-name $STORAGE_ACCOUNT_NAME \
  --account-key $STORAGE_KEY \
  --public-access blob

# Upload PowerShell script
az storage blob upload \
  --account-name $STORAGE_ACCOUNT_NAME \
  --account-key $STORAGE_KEY \
  --container-name scripts \
  --file ./scripts/extensions/configure-sql-bag.ps1 \
  --name configure-sql-bag.ps1

# Get script URL
SCRIPT_URL=$(az storage blob url \
  --account-name $STORAGE_ACCOUNT_NAME \
  --account-key $STORAGE_KEY \
  --container-name scripts \
  --name configure-sql-bag.ps1 \
  --output tsv)

log "PowerShell script uploaded to: $SCRIPT_URL"

# 5. Get VM private IPs
VM1_PRIVATE_IP=$(az vm show -d -g $RESOURCE_GROUP -n ${VM_PREFIX}1 --query privateIps -o tsv)
VM2_PRIVATE_IP=$(az vm show -d -g $RESOURCE_GROUP -n ${VM_PREFIX}2 --query privateIps -o tsv)

# 6. Deploy VM extension to primary SQL VM
log "Deploying Custom Script Extension to primary SQL VM..."
az vm extension set \
  --resource-group $RESOURCE_GROUP \
  --vm-name ${VM_PREFIX}1 \
  --name CustomScriptExtension \
  --publisher Microsoft.Compute \
  --version 1.10 \
  --settings "{\"fileUris\": [\"$SCRIPT_URL\"]}" \
  --protected-settings "{\"commandToExecute\": \"powershell -ExecutionPolicy Unrestricted -File configure-sql-bag.ps1 -PrimaryServer ${VM_PREFIX}1 -SecondaryServer ${VM_PREFIX}2 -PrimaryIP $VM1_PRIVATE_IP -SecondaryIP $VM2_PRIVATE_IP -ListenerIP $LISTENER_IP -SqlAdminUser $ADMIN_USERNAME -SqlAdminPassword '$ADMIN_PASSWORD' -AGName '$AG_NAME' -ListenerName '$LISTENER_NAME' -ProbePort $PROBE_PORT\"}"

# 7. Wait before deploying to secondary for setup sequence
log "Waiting for primary VM extension to complete initial setup (3 minutes)..."
sleep 180

# 8. Deploy VM extension to secondary SQL VM
log "Deploying Custom Script Extension to secondary SQL VM..."
az vm extension set \
  --resource-group $RESOURCE_GROUP \
  --vm-name ${VM_PREFIX}2 \
  --name CustomScriptExtension \
  --publisher Microsoft.Compute \
  --version 1.10 \
  --settings "{\"fileUris\": [\"$SCRIPT_URL\"]}" \
  --protected-settings "{\"commandToExecute\": \"powershell -ExecutionPolicy Unrestricted -File configure-sql-bag.ps1 -PrimaryServer ${VM_PREFIX}1 -SecondaryServer ${VM_PREFIX}2 -PrimaryIP $VM1_PRIVATE_IP -SecondaryIP $VM2_PRIVATE_IP -ListenerIP $LISTENER_IP -SqlAdminUser $ADMIN_USERNAME -SqlAdminPassword '$ADMIN_PASSWORD' -AGName '$AG_NAME' -ListenerName '$LISTENER_NAME' -ProbePort $PROBE_PORT\"}"

# 9. Verify deployment
log "Waiting for configuration to complete (5 minutes)..."
sleep 300

log "Verifying SQL Server Availability Group configuration..."
az vm run-command invoke \
  --resource-group $RESOURCE_GROUP \
  --name ${VM_PREFIX}1 \
  --command-id RunPowerShellScript \
  --scripts "Invoke-Sqlcmd -Query \"SELECT name, state_desc FROM sys.availability_groups; SELECT replica_server_name, role_desc, connected_state_desc, synchronization_health_desc FROM sys.dm_hadr_availability_replica_states;\" | Format-Table -AutoSize | Out-String"

log "SQL Server HA deployment with VM extensions completed!"
log "Listener Name: $LISTENER_NAME"
log "Listener IP: $LISTENER_IP"
log "AG Name: $AG_NAME"

#!/bin/bash

# SQL Server Availability Group Setup Script

set -e

# Load deployment variables
source ./deployment-variables.sh

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

log "Starting SQL Server Availability Group setup"

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

# 4. Create a storage account for the SQL AG
# Generate a shorter unique name (max 24 chars)
RANDOM_SUFFIX=$(date +%s | tail -c 8)  # Take only last 8 digits of timestamp
STORAGE_ACCOUNT_NAME="sqlhast${RANDOM_SUFFIX}"  # Short prefix + suffix

log "Creating storage account ${STORAGE_ACCOUNT_NAME}..."
az storage account create \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2

# Get storage account key
STORAGE_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT_NAME \
  --query "[0].value" -o tsv)

# 5. Create the SQL Server Availability Group configuration
log "Creating SQL Server Availability Group configuration..."
az sql vm group create \
  --name $AG_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --image-offer "SQL2019-WS2022" \
  --image-sku "Enterprise" \
  --domain-fqdn "WORKGROUP" \
  --operator-acc $ADMIN_USERNAME \
  --service-acc $ADMIN_USERNAME \
  --sa-key "$STORAGE_KEY" \
  --storage-account "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/" \
  --basic-availability-group

# 6. Add the SQL VMs to the Availability Group
log "Adding SQL VMs to the availability group..."
for i in 1 2; do
  VM_NAME="${VM_PREFIX}${i}"
  
  log "Adding $VM_NAME to group $AG_NAME..."
  az sql vm add-to-group \
    --name $VM_NAME \
    --resource-group $RESOURCE_GROUP \
    --sqlvm-group $AG_NAME \
    --bootstrap-acc-pwd "$ADMIN_PASSWORD" \
    --operator-acc-pwd "$ADMIN_PASSWORD" \
    --service-acc-pwd "$ADMIN_PASSWORD"
done

# 7. Create the availability group listener
log "Creating Availability Group listener..."
az sql vm ag-listener create \
  --resource-group $RESOURCE_GROUP \
  --ag-name $AG_NAME \
  --name $LISTENER_NAME \
  --ip-address $LISTENER_IP \
  --load-balancer $LB_NAME \
  --probe-port $PROBE_PORT \
  --subnet $SUBNET_NAME \
  --vnet-name $VNET_NAME \
  --port 1433

log "Availability Group setup completed successfully!"
log "Listener name: $LISTENER_NAME"
log "Listener IP: $LISTENER_IP"
log "Next step: Run validate-ha-deployment.sh to verify your deployment"

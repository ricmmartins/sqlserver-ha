#!/bin/bash

# Azure SQL VM HA Deployment using AZ CLI

# Set error handling and enable command tracing for troubleshooting
set -e
# Uncomment for verbose debugging
# set -x 

# Variables - Resource names with better naming conventions
TIMESTAMP=$(date +%s)
RESOURCE_GROUP="rg-sqlha-demo-${TIMESTAMP}"
LOCATION="eastus2"
VNET_NAME="vnet-sqlha-${TIMESTAMP}"
SUBNET_NAME="snet-sql-${TIMESTAMP}"
NSG_NAME="nsg-sql-${TIMESTAMP}"
AVSET_NAME="avset-sql-${TIMESTAMP}"
VM_PREFIX="sqlvm"
ADMIN_USERNAME="sqladmin"
LOG_FILE="sql-ha-deploy-${TIMESTAMP}.log"

# Function for logging
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ${message}" | tee -a "${LOG_FILE}"
}

log "Starting SQL HA deployment"

# Generate a strong random password instead of hardcoding it
ADMIN_PASSWORD=$(openssl rand -base64 24)
SQL_IMAGE="MicrosoftSQLServer:SQL2019-WS2022:Standard:latest"

# Login and set subscription
log "Authenticating to Azure..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [ -z "$SUBSCRIPTION_ID" ]; then
    az login
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi
log "Using subscription: $SUBSCRIPTION_ID"

# Create resource group
log "Creating resource group: $RESOURCE_GROUP"
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create VNet and Subnet
log "Creating virtual network and subnet..."
az network vnet create \
  --name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.0.0/24

# Create NSG with required SQL rules
log "Creating network security group with SQL rules..."
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name $NSG_NAME \
  --location $LOCATION

# Add RDP rule
log "Creating NSG rule for RDP access..."
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowRDP \
  --priority 1000 \
  --destination-port-ranges 3389 \
  --protocol Tcp \
  --access Allow \
  --source-address-prefixes "*" \
  --destination-address-prefixes "*" \
  --description "Allow RDP access for administration"

# Add SQL rule
log "Creating NSG rule for SQL access..."
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowSQL \
  --priority 1001 \
  --destination-port-ranges 1433 \
  --protocol Tcp \
  --access Allow \
  --source-address-prefixes "*" \
  --destination-address-prefixes "*" \
  --description "Allow SQL Server access"

# Add rule for AG replication
log "Creating NSG rule for Availability Group replication..."
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowAGReplication \
  --priority 1002 \
  --destination-port-ranges 5022 \
  --protocol Tcp \
  --access Allow \
  --source-address-prefixes "*" \
  --destination-address-prefixes "*" \
  --description "Allow SQL AG endpoint replication"

# Create Availability Set
log "Creating availability set..."
az vm availability-set create \
  --name $AVSET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --platform-fault-domain-count 2 \
  --platform-update-domain-count 5

# Loop to create two SQL VMs
log "Creating SQL VMs..."
for i in 1 2; do
  VM_NAME="${VM_PREFIX}${i}"
  IP_NAME="${VM_NAME}-ip"
  NIC_NAME="${VM_NAME}-nic"
  DISK_NAME="${VM_NAME}-disk"
  
  log "Creating VM: $VM_NAME"

  # Create public IP with static allocation
  az network public-ip create \
    --resource-group $RESOURCE_GROUP \
    --name $IP_NAME \
    --sku Standard \
    --allocation-method Static \
    --version IPv4
  
  # Create NIC
  az network nic create \
    --resource-group $RESOURCE_GROUP \
    --name $NIC_NAME \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_NAME \
    --network-security-group $NSG_NAME \
    --public-ip-address $IP_NAME

  # Create VM with SQL Server image and Premium SSD
  az vm create \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    --location $LOCATION \
    --nics $NIC_NAME \
    --image $SQL_IMAGE \
    --admin-username $ADMIN_USERNAME \
    --admin-password "$ADMIN_PASSWORD" \
    --availability-set $AVSET_NAME \
    --size Standard_D4s_v3 \
    --storage-sku Premium_LRS \
    --os-disk-name $DISK_NAME \
    --os-disk-size-gb 256

  # Add data disks for SQL data and log files
  az vm disk create \
    --resource-group $RESOURCE_GROUP \
    --name "${VM_NAME}-data-disk" \
    --size-gb 512 \
    --sku Premium_LRS
    
  az vm disk attach \
    --resource-group $RESOURCE_GROUP \
    --vm-name $VM_NAME \
    --name "${VM_NAME}-data-disk"
    
  az vm disk create \
    --resource-group $RESOURCE_GROUP \
    --name "${VM_NAME}-log-disk" \
    --size-gb 256 \
    --sku Premium_LRS
    
  az vm disk attach \
    --resource-group $RESOURCE_GROUP \
    --vm-name $VM_NAME \
    --name "${VM_NAME}-log-disk"

  # Register with SQL IaaS Extension
  log "Registering SQL VM: $VM_NAME"
  az sql vm create \
    --name $VM_NAME \
    --resource-group $RESOURCE_GROUP \
    --license-type PAYG \
    --sql-mgmt-type Full \
    --enable-auto-patching \
    --day-of-week Sunday \
    --maintenance-window-duration 60 \
    --maintenance-window-starting-hour 2
done

# Store credential in Key Vault for production use
log "Creating Key Vault for credentials..."
KV_NAME="kv-sqlha-${TIMESTAMP}"

az keyvault create \
  --name $KV_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --enable-rbac-authorization true

# Get current user object ID for Key Vault access policy
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Assign RBAC role to current user
az role assignment create \
  --role "Key Vault Administrator" \
  --assignee $USER_OBJECT_ID \
  --scope $(az keyvault show --name $KV_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Store SQL admin credentials in Key Vault
az keyvault secret set \
  --vault-name $KV_NAME \
  --name "SQLAdminUsername" \
  --value "$ADMIN_USERNAME"

az keyvault secret set \
  --vault-name $KV_NAME \
  --name "SQLAdminPassword" \
  --value "$ADMIN_PASSWORD"

# Output deployment information
log "-------------------------------------"
log "Deployment completed successfully!"
log "Resource Group: $RESOURCE_GROUP"
log "Key Vault: $KV_NAME"
log "SQL Server VMs: ${VM_PREFIX}1, ${VM_PREFIX}2"
log "To retrieve credentials:"
log "Username: az keyvault secret show --vault-name $KV_NAME --name SQLAdminUsername --query value -o tsv"
log "Password: az keyvault secret show --vault-name $KV_NAME --name SQLAdminPassword --query value -o tsv"
log "-------------------------------------"
log "Next steps:"
log "1. Run setup-availability-group.sh to configure SQL Server Always On"
log "2. Run validate-ha-deployment.sh to verify your deployment"
log "-------------------------------------"

# Save important variables for other scripts
cat > deployment-variables.sh << EOF
#!/bin/bash
# SQL HA deployment variables
export RESOURCE_GROUP="${RESOURCE_GROUP}"
export LOCATION="${LOCATION}"
export VNET_NAME="${VNET_NAME}"
export SUBNET_NAME="${SUBNET_NAME}"
export VM_PREFIX="${VM_PREFIX}"
export KV_NAME="${KV_NAME}"
EOF

chmod +x deployment-variables.sh

#!/bin/bash

# Azure SQL VM HA Deployment using AZ CLI
# This script deploys SQL Server VMs in an availability set configuration
# with proper settings for high availability

# Set error handling and verbose logging
set -e
exec > >(tee -i deployment.log)
exec 2>&1

echo "Starting SQL High Availability deployment: $(date)"

# Variables - Resource names
TIMESTAMP=$(date +%s)
RESOURCE_GROUP="rg-sql-ha-demo"
LOCATION="centralus"
VNET_NAME="vnet-sql-ha"
SUBNET_NAME="subnet-sql"
NSG_NAME="nsg-sql-ha"
AVSET_NAME="avset-sql-ha"
VM_PREFIX="sqlvm"
ADMIN_USERNAME="sqladmin"
KV_NAME="kv-sqlha-${TIMESTAMP}"
TAGS="environment=production application=sqlserver owner=dbteam costcenter=123456"

# Generate a strong random password for SQL admin account
ADMIN_PASSWORD=$(openssl rand -base64 24)
SQL_IMAGE="MicrosoftSQLServer:SQL2019-WS2022:Standard:latest"

# Function for logging with timestamps
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

# Function to register SQL VM with retry logic
register_sql_vm() {
    local vm_name=$1
    local retries=3
    local wait_time=30
    local attempt=1

    while [ $attempt -le $retries ]; do
        log "Registering SQL VM $vm_name (Attempt $attempt of $retries)"

        if az sql vm create \
            --name $vm_name \
            --resource-group $RESOURCE_GROUP \
            --license-type PAYG \
            --sql-mgmt-type Full; then
            log "SQL VM $vm_name registered successfully"
            return 0
        else
            log "Registration attempt $attempt failed. Retrying in $wait_time seconds..."
            sleep $wait_time
            ((attempt++))
        fi
    done

    log "Failed to register SQL VM $vm_name after $retries attempts"
    return 1
}

# Login and set subscription
log "Authenticating to Azure..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [ -z "$SUBSCRIPTION_ID" ]; then
    az login
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi
log "Using subscription: $SUBSCRIPTION_ID"

# Create resource group with tags
log "Creating resource group: $RESOURCE_GROUP"
az group create --name $RESOURCE_GROUP --location $LOCATION --tags $TAGS

# Create VNet and Subnet
log "Creating virtual network and subnet..."
az network vnet create \
  --name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.0.0/24 \
  --tags $TAGS

# Create NSG with required SQL rules
log "Creating network security group with SQL rules..."
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name $NSG_NAME \
  --location $LOCATION \
  --tags $TAGS

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
  --destination-address-prefixes "*"

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
  --source-address-prefixes "VirtualNetwork" \
  --destination-address-prefixes "*"

# Add Availability Group endpoint rule
log "Creating NSG rule for AG endpoint..."
az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --name AllowAGEndpoint \
  --priority 1002 \
  --destination-port-ranges 5022 \
  --protocol Tcp \
  --access Allow \
  --source-address-prefixes "VirtualNetwork" \
  --destination-address-prefixes "*"

# Create Availability Set
log "Creating availability set..."
az vm availability-set create \
  --name $AVSET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --platform-fault-domain-count 2 \
  --platform-update-domain-count 5 \
  --tags $TAGS

# Create Azure Key Vault for secure credential storage
log "Creating Azure Key Vault for secure credential storage..."
az keyvault create \
  --name $KV_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --enabled-for-disk-encryption true \
  --enabled-for-deployment true \
  --sku standard \
  --tags $TAGS

# Get current user's object ID - using 'id' instead of 'objectId'
log "Getting current user ID for role assignment..."
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Check if USER_OBJECT_ID was retrieved successfully
if [ -z "$USER_OBJECT_ID" ]; then
    log "Failed to get user object ID. Trying alternative method..."
    # Try to get the user principal name instead
    USER_PRINCIPAL=$(az account show --query user.name -o tsv)

    if [ -n "$USER_PRINCIPAL" ]; then
        log "Using user principal: $USER_PRINCIPAL"
        # Use the principal name instead of object ID
        az role assignment create \
          --role "Key Vault Secrets Officer" \
          --assignee "$USER_PRINCIPAL" \
          --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KV_NAME"
    else
        log "ERROR: Could not identify the current user for role assignment"
        exit 1
    fi
else
    log "User Object ID: $USER_OBJECT_ID"

    # Create the role assignment using object ID
    az role assignment create \
      --role "Key Vault Secrets Officer" \
      --assignee "$USER_OBJECT_ID" \
      --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KV_NAME"
fi

# Waiting for RBAC propagation
log "Waiting 30 seconds for RBAC propagation..."
sleep 30


# Store SQL admin credentials in Key Vault
log "Storing credentials in Key Vault..."
az keyvault secret set \
  --vault-name $KV_NAME \
  --name "SqlAdminUsername" \
  --value "$ADMIN_USERNAME"

az keyvault secret set \
  --vault-name $KV_NAME \
  --name "SqlAdminPassword" \
  --value "$ADMIN_PASSWORD"

# Loop to create two SQL VMs
log "Creating SQL VMs..."
for i in 1 2; do
  VM_NAME="$VM_PREFIX$i"
  IP_NAME="$VM_NAME-ip"
  NIC_NAME="$VM_NAME-nic"
  OS_DISK_NAME="$VM_NAME-os-disk"
  DATA_DISK_NAME="$VM_NAME-data-disk"
  LOG_DISK_NAME="$VM_NAME-log-disk"
  TEMPDB_DISK_NAME="$VM_NAME-tempdb-disk"

  log "Creating VM: $VM_NAME"

  # Create public IP with static allocation
  az network public-ip create \
    --resource-group $RESOURCE_GROUP \
    --name $IP_NAME \
    --sku Standard \
    --allocation-method Static \
    --tags $TAGS

  # Create NIC with accelerated networking for better performance
  az network nic create \
    --resource-group $RESOURCE_GROUP \
    --name $NIC_NAME \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_NAME \
    --network-security-group $NSG_NAME \
    --public-ip-address $IP_NAME \
    --accelerated-networking true \
    --tags $TAGS

  # Create VM with SQL Server image
  log "Creating VM $VM_NAME with SQL Server image..."
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
    --os-disk-name $OS_DISK_NAME \
    --os-disk-size-gb 256 \
    --storage-sku Premium_LRS \
    --tags $TAGS

  # Add data disk for SQL data files with read caching for better performance
  log "Adding data disk for SQL data files..."
  az vm disk attach \
    --resource-group $RESOURCE_GROUP \
    --vm-name $VM_NAME \
    --name $DATA_DISK_NAME \
    --new \
    --size-gb 512 \
    --sku Premium_LRS \
    --caching ReadOnly \
    --lun 0

  # Add log disk for SQL log files with no caching for durability
  log "Adding log disk for SQL log files..."
  az vm disk attach \
    --resource-group $RESOURCE_GROUP \
    --vm-name $VM_NAME \
    --name $LOG_DISK_NAME \
    --new \
    --size-gb 256 \
    --sku Premium_LRS \
    --caching None \
    --lun 1

  # Add tempdb disk for SQL tempdb files with read/write caching
  log "Adding tempdb disk for SQL tempdb files..."
  az vm disk attach \
    --resource-group $RESOURCE_GROUP \
    --vm-name $VM_NAME \
    --name $TEMPDB_DISK_NAME \
    --new \
    --size-gb 128 \
    --sku Premium_LRS \
    --caching ReadWrite \
    --lun 2

  # Register VM with SQL IaaS Extension - FIX: Using register instead of create
  register_sql_vm $VM_NAME
done

# Configure backup for the VMs
log "Configuring Azure Backup for SQL VMs..."
VAULT_NAME="rsv-sql-ha"

# Create Recovery Services Vault
az backup vault create \
  --name $VAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --tags $TAGS

# Create backup policy using template-based approach
log "Creating backup policy..."

# Enable backup for each VM
for i in 1 2; do
  VM_NAME="$VM_PREFIX$i"
  log "Enabling backup for $VM_NAME..."

  az backup protection enable-for-vm \
    --resource-group $RESOURCE_GROUP \
    --vault-name $VAULT_NAME \
    --vm $VM_NAME \
    --policy-name "DefaultPolicy"
done

# Add resource lock to prevent accidental deletion
log "Adding resource lock to protect deployment..."
az lock create \
  --name "sql-ha-lock" \
  --resource-group $RESOURCE_GROUP \
  --lock-type CanNotDelete \
  --notes "Protected SQL HA environment - do not delete"

# Set up Azure Monitor alerts for SQL VMs
log "Configuring monitoring for SQL VMs..."
ACTION_GROUP_NAME="sql-critical-alerts"

# Create action group for alerts
az monitor action-group create \
  --name $ACTION_GROUP_NAME \
  --resource-group $RESOURCE_GROUP \
  --short-name "SQLAlerts"

# Create CPU alert rule for each VM
for i in 1 2; do
  VM_NAME="$VM_PREFIX$i"
  VM_ID=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query id -o tsv)

  az monitor metrics alert create \
    --name "${VM_NAME}-high-cpu" \
    --resource-group $RESOURCE_GROUP \
    --scopes $VM_ID \
    --condition "avg Percentage CPU > 80 where TimeGrain = PT5M" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --action $ACTION_GROUP_NAME \
    --description "Alert when CPU exceeds 80% for 5 minutes"
done

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
export ADMIN_USERNAME="${ADMIN_USERNAME}"
# Use Key Vault to retrieve password:
# export ADMIN_PASSWORD=\$(az keyvault secret show --vault-name $KV_NAME --name SqlAdminPassword --query value -o tsv)
EOF

chmod +x deployment-variables.sh

# Output deployment information
log "-------------------------------------"
log "Deployment completed successfully!"
log "Resource Group: $RESOURCE_GROUP"
log "Key Vault: $KV_NAME (credentials stored securely here)"
log "SQL Server VMs: ${VM_PREFIX}1, ${VM_PREFIX}2"
log ""
log "To retrieve credentials securely:"
log "Admin Username: az keyvault secret show --vault-name $KV_NAME --name SqlAdminUsername --query value -o tsv"
log "Admin Password: az keyvault secret show --vault-name $KV_NAME --name SqlAdminPassword --query value -o tsv"
log "-------------------------------------"
log "Next steps:"
log "1. Configure SQL Server Always On Availability Group"
log "2. Set up AG listener with internal load balancer"
log "3. Configure SQL database backups within the AG"
log "4. Review monitoring and alert configurations"
log "-------------------------------------"
echo "End of deployment: $(date)"

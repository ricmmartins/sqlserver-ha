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

# Create resource group with tags
log "Creating resource group: $RESOURCE_GROUP"
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --tags 'environment=production' 'application=SQL-HA' 'owner=ITOperations' 'costCenter=12345'

# Create VNet and Subnet
log "Creating virtual network and subnet..."
az network vnet create \
  --name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --address-prefix 10.0.0.0/16 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.0.0/24 \
  --tags 'environment=production' 'application=SQL-HA'

# Create NSG with required SQL rules
log "Creating network security group with SQL rules..."
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name $NSG_NAME \
  --location $LOCATION \
  --tags 'environment=production' 'application=SQL-HA'

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
  --platform-update-domain-count 5 \
  --tags 'environment=production' 'application=SQL-HA'

# Create data disk configuration function
create_and_attach_disks() {
    local vm_name=$1
    local resource_group=$2
    
    # Add data disks for SQL data and log files
    log "Creating and attaching data disks for $vm_name"
    
    # Data disk
    az vm disk create \
      --resource-group $resource_group \
      --name "${vm_name}-data-disk" \
      --size-gb 512 \
      --sku Premium_LRS \
      --tags 'diskType=data' 'application=SQL-HA'
      
    az vm disk attach \
      --resource-group $resource_group \
      --vm-name $vm_name \
      --name "${vm_name}-data-disk"
      
    # Log disk
    az vm disk create \
      --resource-group $resource_group \
      --name "${vm_name}-log-disk" \
      --size-gb 256 \
      --sku Premium_LRS \
      --tags 'diskType=log' 'application=SQL-HA'
      
    az vm disk attach \
      --resource-group $resource_group \
      --vm-name $vm_name \
      --name "${vm_name}-log-disk"
      
    # TempDB disk
    az vm disk create \
      --resource-group $resource_group \
      --name "${vm_name}-tempdb-disk" \
      --size-gb 128 \
      --sku Premium_LRS \
      --tags 'diskType=tempdb' 'application=SQL-HA'
      
    az vm disk attach \
      --resource-group $resource_group \
      --vm-name $vm_name \
      --name "${vm_name}-tempdb-disk"
}

# Function to register SQL VM with retry capability
register_sql_vm() {
    local vm_name=$1
    local resource_group=$2
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "Registering SQL VM: $vm_name (Attempt $attempt of $max_attempts)"
        
        if az sql vm register \
          --name $vm_name \
          --resource-group $resource_group \
          --license-type PAYG \
          --sql-mgmt-type Full \
          --auto-patching-settings "Enable=true Day=Sunday MaintenanceWindowStartingHour=2 MaintenanceWindowDuration=60"; then
            
            log "Successfully registered $vm_name with SQL IaaS extension"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                log "Failed to register $vm_name. Retrying in 30 seconds..."
                sleep 30
            else
                log "Failed to register $vm_name after $max_attempts attempts."
                return 1
            fi
        fi
        
        ((attempt++))
    done
}

# Loop to create two SQL VMs
log "Creating SQL VMs..."
for i in 1 2; do
  VM_NAME="${VM_PREFIX}${i}"
  IP_NAME="${VM_NAME}-ip"
  NIC_NAME="${VM_NAME}-nic"
  DISK_NAME="${VM_NAME}-os-disk"
  
  log "Creating VM: $VM_NAME"

  # Create public IP with static allocation
  az network public-ip create \
    --resource-group $RESOURCE_GROUP \
    --name $IP_NAME \
    --sku Standard \
    --allocation-method Static \
    --version IPv4 \
    --tags 'environment=production' 'application=SQL-HA'
  
  # Create NIC
  az network nic create \
    --resource-group $RESOURCE_GROUP \
    --name $NIC_NAME \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_NAME \
    --network-security-group $NSG_NAME \
    --public-ip-address $IP_NAME \
    --accelerated-networking true \
    --tags 'environment=production' 'application=SQL-HA'

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
    --os-disk-size-gb 256 \
    --tags 'environment=production' 'application=SQL-HA' 'role=database'

  # Create and attach data disks
  create_and_attach_disks $VM_NAME $RESOURCE_GROUP

  # Register SQL VM with IaaS extension - using the correct command
  register_sql_vm $VM_NAME $RESOURCE_GROUP
done

# Store credential in Key Vault for production use
log "Creating Key Vault for credentials..."
KV_NAME="kv-sqlha-${TIMESTAMP}"

az keyvault create \
  --name $KV_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --enable-rbac-authorization true \
  --enabled-for-disk-encryption true \
  --sku Premium \
  --tags 'environment=production' 'application=SQL-HA'

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

# Create resource locks for production resources
log "Adding resource locks to protect critical resources..."
az lock create --name "SQLHAResourceGroupLock" \
  --resource-group $RESOURCE_GROUP \
  --lock-type CanNotDelete \
  --notes "Protects SQL HA production environment"

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

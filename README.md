# Azure SQL Server High Availability Solution

This repository contains scripts and documentation for deploying and validating a SQL Server High Availability (HA) solution in Azure using Virtual Machines. The solution leverages Azure Availability Sets and SQL Server Always On Availability Groups.

## Repository Structure

```bash
├── README.md
├── scripts/
│   ├── deploy-sql-ha.sh                # Main deployment script
│   ├── setup-availability-group.sh     # Configure SQL Availability Group
│   └── validate-ha-deployment.sh       # Validation scripts
├── docs/
│   ├── validation-guide.md             # Detailed validation procedures  
│   └── troubleshooting.md              # Common issues and solutions
```

## Prerequisites

- Azure CLI installed and configured
- Bash shell environment (Linux, macOS, WSL, or Azure Cloud Shell)
- An Azure subscription with contributor permissions
- Basic understanding of SQL Server and networking concepts

## Deployment Process

1. Deploy SQL Server VMs
The [deploy-sql-ha.sh](scripts/deploy-sql-ha.sh) script creates:

- Resource group
- Virtual network and subnet
- Network security group with required rules
- Availability Set for high availability
- Two SQL Server VMs registered with SQL IaaS Agent Extension

```bash
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
```

2. Configure SQL Server Availability Group

After deploying the SQL VMs, set up the Availability Group with the setup-availability-group.sh script:

```bash
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
ADMIN_USERNAME=$(az keyvault secret show --vault-name $KV_NAME --name SQLAdminUsername --query value -o tsv)
ADMIN_PASSWORD=$(az keyvault secret show --vault-name $KV_NAME --name SQLAdminPassword --query value -o tsv)

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

# 4. Create the SQL Server Availability Group configuration
log "Creating SQL Server Availability Group configuration..."
az sql vm group create \
  --name $AG_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --bootstrap-account $ADMIN_USERNAME \
  --password "$ADMIN_PASSWORD" \
  --sql-image-offer SQL2019-WS2022 \
  --sql-image-sku Standard \
  --domain-fqdn "WORKGROUP" \
  --operator-account $ADMIN_USERNAME \
  --service-account $ADMIN_USERNAME \
  --sql-service-account-password "$ADMIN_PASSWORD"

# 5. Add the SQL VMs to the Availability Group
log "Adding SQL VMs to the availability group..."
for i in 1 2; do
  VM_NAME="${VM_PREFIX}${i}"
  
  az sql vm group join \
    --name $AG_NAME \
    --resource-group $RESOURCE_GROUP \
    --vm-name $VM_NAME \
    --sql-password "$ADMIN_PASSWORD" \
    --location $LOCATION
done

# 6. Create the availability group listener
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
```

3. Validate Your Deployment

After setting up the environment, validate it using the validate-ha-deployment.sh script:

```bash
#!/bin/bash

# SQL Server HA Validation Script

set -e

# Load deployment variables
source ./deployment-variables.sh

# Variables
LOG_FILE="ha-validation-$(date +%s).log"
AG_NAME="SQLAG"
LB_NAME="lb-sqlha"

# Function for logging
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ${message}" | tee -a "${LOG_FILE}"
}

log "Starting SQL HA validation"

# 1. Validate Availability Set configuration
log "Validating Availability Set..."
az vm availability-set show \
  --name "${RESOURCE_GROUP:3:7}-avset" \
  --resource-group $RESOURCE_GROUP \
  --query "{Name:name, FaultDomains:platformFaultDomainCount, UpdateDomains:platformUpdateDomainCount}" \
  -o table

# Check VMs in Availability Set
log "Validating VMs in Availability Set..."
az vm list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, AvailabilitySet:availabilitySet.id}" \
  -o table

# 2. Validate SQL IaaS Extension registration
log "Validating SQL IaaS Extension registration..."
az sql vm list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, Status:provisioningState, LicenseType:sqlServerLicenseType, ManagementMode:sqlManagementType}" \
  -o table

# Check SQL IaaS Extension details
log "Checking SQL IaaS Extension details..."
for vm in "${VM_PREFIX}1" "${VM_PREFIX}2"; do
  log "SQL IaaS Extension for $vm:"
  az vm extension list \
    --resource-group $RESOURCE_GROUP \
    --vm-name $vm \
    --query "[?name=='SqlIaaSAgent'].{Name:name, Status:provisioningState}" \
    -o table
done

# 3. Validate Load Balancer configuration
log "Validating Load Balancer configuration..."
az network lb show \
  --resource-group $RESOURCE_GROUP \
  --name $LB_NAME \
  --query "{Name:name, FrontendIP:frontendIPConfigurations[0].privateIPAddress}" \
  -o table

# Check health probe configuration
log "Checking health probe configuration..."
az network lb probe list \
  --resource-group $RESOURCE_GROUP \
  --lb-name $LB_NAME \
  -o table

# Check load balancing rules
log "Checking load balancing rules..."
az network lb rule list \
  --resource-group $RESOURCE_GROUP \
  --lb-name $LB_NAME \
  -o table

# 4. Validate Availability Group configuration
log "Validating Availability Group configuration..."
az sql vm group list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, Location:location, provisioningState:provisioningState}" \
  -o table

# Check AG Listener
log "Checking Availability Group listener..."
az sql vm ag-listener list \
  --resource-group $RESOURCE_GROUP \
  --ag-name $AG_NAME \
  --query "[].{Name:name, IP:ipAddress, Port:port}" \
  -o table

# 5. Check VM status
log "Checking VM status..."
az vm list \
  --resource-group $RESOURCE_GROUP \
  --show-details \
  --query "[].{Name:name, PowerState:powerState, ProvisioningState:provisioningState}" \
  -o table

log "Validation summary:"
log "--------------------"
log "The validation script checks the following components:"
log "✓ Availability Set configuration"
log "✓ SQL VMs in Availability Set"
log "✓ SQL IaaS Extension registration"
log "✓ Load Balancer configuration"
log "✓ Health probe and load balancing rules"
log "✓ Availability Group configuration"
log "✓ Availability Group listener"
log "✓ VM status"
log ""
log "For comprehensive validation of SQL AG functionality, you must connect to SQL Server and run specific SQL commands."
log "Refer to docs/validation-guide.md for detailed SQL validation steps."
```

## Detailed Validation Guide

This guide helps you validate your SQL Server High Availability deployment in Azure. See [docs/validation-guide.md](docs/validation-guide.md) for detailed instructions.

## Key Validation Areas

1. **High Availability (Availability Set)**
   - Verify fault domain and update domain configuration
   - Confirm VM placement within the Availability Set

2. **SQL IaaS Agent Extension**
   - Check registration status and configuration
   - Verify auto-patching settings

3. **Availability Group Configuration**
   - Connect to SQL Server and validate AG status
   - Check replica synchronization
   - Test the listener connection

4. **Failover Testing**
   - Perform manual failover between replicas
   - Simulate node failures and observe automatic failover

## Best Practices

For Performance and Availability
- Use Premium SSDs for SQL Server data, log, and TempDB files
- Separate data and log files onto different disks
- Place TempDB on the local SSD (D:) drive for better performance
- Configure proper autogrowth settings for database files
- Use properly sized VMs with adequate memory for SQL Server's buffer pool

For Security
- Store credentials in Azure Key Vault
- Use managed identities for authentication between services
- Implement network security groups with least-privilege access
- Enable Transparent Data Encryption (TDE) for databases
- Use Azure Private Link for secure connectivity

For Monitoring
- Configure Azure Monitor for SQL insights
- Set up alerts for key metrics (CPU, memory, storage, AG health)
- Use SQL Server Extended Events for performance monitoring
- Implement automated backup verification

## Troubleshooting
For common issues and solutions, refer to [docs/troubleshooting.md](docs/troubleshooting.md).

Common Issues

- Connection failures to the AG listener
- Synchronization issues between replicas
- Performance problems under load
- Failover failures or unexpected behavior

## License
MIT

## Contributing
Contributions are welcome! Please submit a pull request or open an issue.
For questions or support, create an issue in this repository.


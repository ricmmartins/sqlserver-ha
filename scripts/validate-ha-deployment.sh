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

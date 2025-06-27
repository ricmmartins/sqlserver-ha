# SQL Server High Availability Validation Guide

This guide provides detailed steps to validate your SQL Server High Availability deployment on Azure VMs.

## Prerequisites

- Azure CLI installed and configured
- SQL Server Management Studio (SSMS) or Azure Data Studio
- Access to the SQL Server VMs

## 1. Validate Infrastructure Components

### 1.1 Validate Availability Set Configuration

```bash
# Verify availability set configuration
az vm availability-set show \
  --name $AVSET_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "{Name:name, FaultDomains:platformFaultDomainCount, UpdateDomains:platformUpdateDomainCount}" \
  -o table

# Check VM distribution across fault domains
az vm list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, AvSet:availabilitySet.id, FaultDomain:instanceView.platformFaultDomain, UpdateDomain:instanceView.platformUpdateDomain}" \
  -o table
```
Expected results:

- Availability Set should show 2-3 fault domains and 5+ update domains
- VMs should be distributed across different fault domains

### 1.2 Validate Network Configuration

```bash
# Verify Network Security Group rules
az network nsg rule list \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  -o table

# Verify internal load balancer configuration
az network lb show \
  --resource-group $RESOURCE_GROUP \
  --name $LB_NAME \
  --query "{Name:name, PrivateIP:frontendIPConfigurations[0].privateIPAddress}" \
  -o table

# Verify health probe configuration
az network lb probe list \
  --resource-group $RESOURCE_GROUP \
  --lb-name $LB_NAME \
  -o table

# Verify load balancing rules
az network lb rule list \
  --resource-group $RESOURCE_GROUP \
  --lb-name $LB_NAME \
  -o table
```

Expected results:

- NSG should have rules for SQL traffic (1433), AG endpoint (5022), and RDP (3389)
- Load balancer should have proper health probe and rules for SQL traffic

## 2. Validate SQL Server Configuration

### 2.1 Validate SQL IaaS Agent Extension

```bash
# Check SQL VM resources
az sql vm list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, Status:provisioningState, LicenseType:sqlServerLicenseType, ManagementMode:sqlManagementType}" \
  -o table

# Check SQL IaaS extension for each VM
for vm in "${VM_PREFIX}1" "${VM_PREFIX}2"; do
  az vm extension list \
    --resource-group $RESOURCE_GROUP \
    --vm-name $vm \
    --query "[?name=='SqlIaaSAgent'].{Name:name, Status:provisioningState}" \
    -o table
done
```

Expected results:

- SQL VM resources should be provisioned successfully
- SQL IaaS extension should be installed and running

### 2.2 Check SQL Server Configuration
Connect to your SQL Server instances using SSMS or Azure Data Studio and run:

```sql
-- Check SQL Server configuration
SELECT 
    SERVERPROPERTY('ServerName') AS [Server Name],
    SERVERPROPERTY('Edition') AS [Edition],
    SERVERPROPERTY('ProductVersion') AS [Version],
    SERVERPROPERTY('IsClustered') AS [Is Clustered],
    SERVERPROPERTY('IsHadrEnabled') AS [Is HADR Enabled]
```

Expected results:

- IsHadrEnabled should be 1 (true)

## 3. Validate Availability Group Configuration

### 3.1 Check Availability Group Status

Connect to your primary SQL Server and run:

```sql
-- Check overall AG health
SELECT 
    ag.name AS [AG Name],
    ag.group_id AS [AG ID],
    ag.primary_replica AS [Primary Replica],
    ag.failure_condition_level AS [Failure Condition Level],
    ag.health_check_timeout AS [Health Check Timeout],
    ag.automated_backup_preference_desc AS [Backup Preference]
FROM 
    sys.availability_groups ag

-- Check replica status
SELECT 
    ar.replica_server_name AS [Replica Server],
    ag.name AS [AG Name],
    ar.availability_mode_desc AS [Mode],
    ar.failover_mode_desc AS [Failover Mode],
    ar.primary_role_allow_connections_desc AS [Primary Connections],
    ar.secondary_role_allow_connections_desc AS [Secondary Connections],
    ar.seeding_mode_desc AS [Seeding Mode],
    ar.synchronization_health_desc AS [Sync Health]
FROM 
    sys.availability_replicas ar
JOIN 
    sys.availability_groups ag ON ar.group_id = ag.group_id
```

Expected results:

- Synchronization health should be "HEALTHY"
- Primary replica should be defined
- Connection modes should be as expected (typically "ALL" for primary and "READ_ONLY" for secondary)

### 3.2 Check Database Status in Availability Group

```sql
-- Check database sync status
SELECT 
    db.name AS [Database],
    ag.name AS [AG Name],
    drs.synchronization_state_desc AS [Sync State],
    drs.synchronization_health_desc AS [Sync Health],
    drs.last_hardened_lsn AS [Last Hardened LSN],
    drs.last_redone_lsn AS [Last Redone LSN],
    drs.last_commit_lsn AS [Last Commit LSN],
    drs.log_send_queue_size AS [Log Send Queue Size],
    drs.log_send_rate AS [Log Send Rate],
    drs.redo_queue_size AS [Redo Queue Size],
    drs.redo_rate AS [Redo Rate],
    drs.suspend_reason_desc AS [Suspend Reason]
FROM 
    sys.dm_hadr_database_replica_states drs
JOIN 
    sys.availability_groups ag ON drs.group_id = ag.group_id
JOIN 
    sys.databases db ON drs.database_id = db.database_id
```

Expected results:

- Synchronization state should be "SYNCHRONIZED" for sync replicas
- Sync health should be "HEALTHY"
- Queue sizes and rates should be reasonable

### 3.3 Validate AG Listener

```sql
-- Check listener configuration
SELECT 
    agl.dns_name AS [Listener Name],
    agl.port AS [Listener Port],
    agl.ip_configuration_string_from_cluster AS [IP Config],
    ag.name AS [AG Name]
FROM 
    sys.availability_group_listeners agl
JOIN 
    sys.availability_groups ag ON agl.group_id = ag.group_id
```

Test connectivity from client:

```powershell
# Using PowerShell
$SqlConnection = New-Object System.Data.SqlClient.SqlConnection
$SqlConnection.ConnectionString = "Server=<listener_name>,1433;Database=master;Integrated Security=True;"
try {
    $SqlConnection.Open()
    Write-Host "Connection successful" -ForegroundColor Green
    $SqlCommand = $SqlConnection.CreateCommand()
    $SqlCommand.CommandText = "SELECT @@SERVERNAME AS [ConnectedServer]"
    $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
    $SqlAdapter.SelectCommand = $SqlCommand
    $DataSet = New-Object System.Data.DataSet
    $SqlAdapter.Fill($DataSet)
    $DataSet.Tables[0]
    $SqlConnection.Close()
} catch {
    Write-Host "Connection failed: $_" -ForegroundColor Red
}
```

Expected results:

- Listener should be defined with correct IP and port
- Connection test should succeed

## 4. Test Failover Scenarios

### 4.1 Perform a Planned Manual Failover

From SSMS:

1. Connect to the AG primary
2. In Object Explorer, expand Always On High Availability > Availability Groups
3. Right-click the AG and select "Failover..."
4. Follow the wizard to fail over to the secondary replica

Using T-SQL on the target secondary:

```sql
-- Failover to this replica (run on the target secondary)
ALTER AVAILABILITY GROUP [SQLAG] FAILOVER;
```

Expected results:

- Failover completes successfully
- Secondary becomes primary, primary becomes secondary
- Applications reconnect automatically via the listener

### 4.2 Test Forced Failover (Disaster Recovery)

Only use this in test environments or actual disasters - forces failover with potential data loss:

```sql
-- Forced failover with potential data loss (run on the target secondary)
ALTER AVAILABILITY GROUP [SQLAG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

Expected results:

- Failover completes despite primary being unavailable
- Target secondary becomes new primary
- Applications reconnect automatically via the listener

### 4.3 Test Automatic Failover

1. For automatic failover testing, simulate a failure on the primary node:

```bash
# Get current primary
# Then stop the VM to simulate failure
az vm stop --resource-group $RESOURCE_GROUP --name $PRIMARY_VM_NAME
```

2. Monitor the secondary to see if it automatically becomes primary

Expected results:

- Automatic failover occurs (if configured)
- Secondary becomes primary
- Applications reconnect automatically via the listener

## 5. Validation Checklist

Use this checklist to ensure all aspects are validated:

<input disabled="" type="checkbox"> Availability Set configuration is correct
<input disabled="" type="checkbox"> SQL IaaS Agent Extension is properly registered
<input disabled="" type="checkbox"> Network Security Group rules are properly configured
<input disabled="" type="checkbox"> Load balancer and health probe are correctly configured
<input disabled="" type="checkbox"> SQL Server AlwaysOn is enabled on both instances
<input disabled="" type="checkbox"> Availability Group is created and healthy
<input disabled="" type="checkbox"> Replicas show proper synchronization health
<input disabled="" type="checkbox"> AG Listener is created and responding
<input disabled="" type="checkbox"> Manual failover works correctly
<input disabled="" type="checkbox"> Automatic failover works as expected
<input disabled="" type="checkbox"> Applications can connect via the listener before and after failover

Troubleshooting
If you encounter issues during validation, refer to the troubleshooting guide at troubleshooting.md.

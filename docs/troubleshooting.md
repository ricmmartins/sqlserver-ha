# SQL Server High Availability Troubleshooting Guide

This guide helps you diagnose and resolve common issues with SQL Server High Availability deployments on Azure VMs.

## Table of Contents

- [Availability Group Creation Issues](#availability-group-creation-issues)
- [Synchronization Problems](#synchronization-problems)
- [Failover Issues](#failover-issues)
- [Listener Connection Problems](#listener-connection-problems)
- [Performance Issues](#performance-issues)

## Availability Group Creation Issues

### Issue: Failed to create AG with "The operation failed because the login does not have Windows administrator privileges"

**Symptoms:**
- AG creation fails with permission errors

**Troubleshooting:**

1. Verify the account used has local admin rights:
   
```powershell
# Check if account is in administrators group
Get-LocalGroupMember -Group "Administrators" | Select-Object Name
```

2. Check if SQL Service accounts have proper permissions:

```powershell
# Check SQL Server service account
Get-WmiObject win32_service | Where-Object {$_.Name -eq "MSSQLSERVER"} | Select-Object StartName
```

**Resolution:**

- Ensure the account used in --bootstrap-account parameter has local admin rights
- Ensure SQL Service account has necessary permissions
- If using domain accounts, ensure they're properly configured

### Issue: "The operation failed because the cluster does not exist"

**Symptoms:**

- AG creation fails with cluster errors

**Troubleshooting:** 

1. Check if cluster service is running:

```powershell
Get-Service -Name ClusSvc
```

2. Verify Windows Firewall rules:

```powershell
Get-NetFirewallRule | Where-Object {$_.DisplayGroup -like "*Clustering*"}
```

**Resolution:**

- Create cluster first using az sql vm group create command
- Ensure firewall allows cluster traffic
- Check for network connectivity between nodes

## Synchronization Problems

### Issue: Databases stuck in "Not Synchronizing" or "Synchronizing" state

**Symptoms:**

- Databases don't move to "Synchronized" state
- Synchronization health shows as "NOT_HEALTHY"

**Troubleshooting:**

1. Check synchronization status:

```sql
SELECT 
    DB_NAME(database_id) AS [Database],
    synchronization_state_desc,
    synchronization_health_desc,
    log_send_queue_size,
    redo_queue_size,
    suspend_reason_desc
FROM 
    sys.dm_hadr_database_replica_states
WHERE 
    replica_id = (SELECT replica_id FROM sys.availability_replicas WHERE replica_server_name = @@SERVERNAME)
```

2. Check for blocking issues:

```sql
SELECT * FROM sys.dm_exec_requests WHERE blocking_session_id > 0
```
**Resolution:**

- Resume data movement if suspended

```sql
ALTER DATABASE [YourDatabase] SET HADR RESUME
```

- Check network connectivity and latency between replicas
- Verify sufficient disk space for transaction logs
- Check for long-running transactions blocking log truncation

### Issue: High latency or slow synchronization

**Symptoms:**

- Large log_send_queue_size or redo_queue_size
- Synchronization takes longer than expected

**Troubleshooting:**

1. Check network performance:

```bash
Test-NetConnection -ComputerName SecondaryVM -Port 5022
```

2. Monitor log generation rate:

```bash
-- On primary
SELECT DB_NAME(database_id) AS [Database], log_reuse_wait_desc FROM sys.databases
```

**Resolution:**

- Improve network bandwidth between VMs
- Consider using Accelerated Networking for VMs
- Optimize workloads to reduce log generation
- Consider asynchronous mode if distance/latency is an issue

## Failover Issues

### Issue: Manual failover fails

**Symptoms:**

- Failover command completes with errors
- Secondary doesn't become primary

**Troubleshooting:**

1. Check synchronization status before failover:

```sql
SELECT 
    ar.replica_server_name, 
    DB_NAME(drs.database_id) AS [Database], 
    drs.synchronization_health_desc
FROM 
    sys.dm_hadr_database_replica_states drs
JOIN 
    sys.availability_replicas ar ON drs.replica_id = ar.replica_id
```

2. Check for connection issues:

```sql
SELECT * FROM sys.dm_hadr_availability_replica_states
```

**Resolution:**

- Ensure synchronization health is HEALTHY before planned failover
- For forced failover, use WITH FORCE option but be aware of data loss potential
- Check for active connections blocking the failover

### Issue: Automatic failover not occurring

**Symptoms:**

- Primary becomes unavailable but secondary doesn't take over
- Applications experience downtime

**Troubleshooting:**

1. Check AG configuration:

```sql
SELECT 
    ag.name, 
    ar.replica_server_name,
    ar.availability_mode_desc,
    ar.failover_mode_desc
FROM 
    sys.availability_groups ag
JOIN 
    sys.availability_replicas ar ON ag.group_id = ar.group_id
```

2. Check cluster quorum configuration:

```sql
Get-ClusterQuorum
```

**Resolution:**

- Ensure failover mode is set to AUTOMATIC
- Ensure availability mode is SYNCHRONOUS_COMMIT
- Configure proper cluster quorum settings
- Ensure health check timeout is appropriate

## Listener Connection Problems

### Issue: Cannot connect to AG listener

**Symptoms:**

- Connection timeouts when connecting to listener
- Error 26 - Error Locating Server/Instance Specified

**Troubleshooting:**

1. Check listener configuration:

```sql
SELECT * FROM sys.availability_group_listeners
```

2. Check load balancer health:

```bash
az network lb probe list --resource-group $RESOURCE_GROUP --lb-name $LB_NAME -o table
```

3. Verify probe response:

```bash
# On each SQL VM, check if the probe port is listening
netstat -ano | findstr :59999
```

**Resolution:**

- Ensure load balancer probe is correctly configured
- Verify SQL Server is listening on the probe port
- Check firewall rules allow traffic on both SQL port (1433) and probe port
- Verify the VMs are in the load balancer backend pool

### Issue: Connections disconnecting after failover

**Symptoms:**

- Applications lose connections during failover
- Reconnection attempts fail or timeout

**Troubleshooting:**

1. Check connection strings used by applications:
  - Verify they include MultiSubnetFailover=True
  -  heck timeout settings
    
2. Test listener connectivity after failover:

```bash
Test-NetConnection -ComputerName <listener_name> -Port 1433
```

**Resolution:**

- Update connection strings to include MultiSubnetFailover=True
- Increase connection timeouts in applications
- Implement retry logic in applications
- Verify the floating IP configuration in load balancer rules

## Performance Issues

### Issue: High CPU usage on SQL VMs

**Symptoms:**

- VM shows high CPU utilization
- Performance degradation across databases

**Troubleshooting:**

1. Check Azure VM metrics:

```bash
az monitor metrics list --resource $VM_ID --metric "Percentage CPU" --interval 5M
```

2. Identify high-resource queries:

```sql
SELECT TOP 10
    qs.total_worker_time/qs.execution_count AS avg_cpu_time,
    SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
             ((CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(qt.text)
                ELSE qs.statement_end_offset
              END - qs.statement_start_offset)/2) + 1) AS query_text,
    qs.execution_count,
    qs.total_elapsed_time/qs.execution_count AS avg_elapsed_time
FROM 
    sys.dm_exec_query_stats qs
CROSS APPLY 
    sys.dm_exec_sql_text(qs.sql_handle) qt
ORDER BY 
    qs.total_worker_time DESC
```

**Resolution:**

- Scale up VM size for more CPU resources
- Optimize high-resource queries
- Implement query performance tuning
- Consider read-only routing to offload read operations to secondary replicas

### Issue: Disk I/O bottlenecks

**Symptoms:**

- High disk latency
- Timeouts during heavy write operations

**Troubleshooting:**

1. Check disk metrics:

```bash
az monitor metrics list --resource $VM_ID --metric "Disk Read Operations/Sec" --interval 5M
az monitor metrics list --resource $VM_ID --metric "Disk Write Operations/Sec" --interval 5M
```

2. Identify I/O intensive queries:

```sql
SELECT TOP 10
    qs.total_logical_reads/qs.execution_count AS avg_logical_reads,
    qs.total_physical_reads/qs.execution_count AS avg_physical_reads,
    qs.total_logical_writes/qs.execution_count AS avg_logical_writes,
    SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
             ((CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(qt.text)
                ELSE qs.statement_end_offset
              END - qs.statement_start_offset)/2) + 1) AS query_text,
    qs.execution_count
FROM 
    sys.dm_exec_query_stats qs
CROSS APPLY 
    sys.dm_exec_sql_text(qs.sql_handle) qt
ORDER BY 
    (qs.total_logical_reads + qs.total_logical_writes) DESC
```

**Resolution:**

- Use Premium SSD or Ultra Disk for data and log files
- Separate data, log, and tempdb files onto different disks
- Enable read-committed snapshot isolation to reduce blocking
- Optimize queries with high I/O demands

## Azure Infrastructure Issues

### Issue: Availability Set Fault Domain Problems

**Symptoms:**

- Both VMs located in same fault domain
- HA not working as expected

**Troubleshooting:**

1. Check VM distribution:

```bash
az vm list --resource-group $RESOURCE_GROUP --query "[].{Name:name, AvSet:availabilitySet.id, FaultDomain:instanceView.platformFaultDomain}" -o table
```

**Resolution:**

- If VMs are in the same fault domain, recreate one VM in a different fault domain
- Ensure availability set has at least 2 fault domains configured

### Issue: Network Security Group Blocking Communication

**Symptoms:**

- AG configuration fails
- Synchronization issues between replicas

**Troubleshooting:**

1. Verify NSG rules:

```bash
az network nsg rule list --resource-group $RESOURCE_GROUP --nsg-name $NSG_NAME -o table
```
**Resolution:**

- Add NSG rules for required ports:
  - SQL Server (1433)
  - AG Endpoint (5022)
  - Windows Cluster (3343)
  - RDP (3389)
 
## General Troubleshooting Steps

Check SQL Server Error Logs

```bash
-- View recent errors
EXEC sp_readerrorlog
```

Check Windows Event Logs

```bash
# Check System logs for cluster events
Get-WinEvent -LogName 'System' -MaxEvents 100 | Where-Object { $_.ProviderName -like '*cluster*' }

Check SQL Server logs
Get-WinEvent -LogName 'Application' -MaxEvents 100 | Where-Object { $_.ProviderName -like '*SQL*' }
```

Check Cluster Logs

```bash
# Get cluster log
Get-ClusterLog -Destination "C:\Logs"
```

Test Network Connectivity

```bash
# Test connectivity between SQL VMs
Test-NetConnection -ComputerName <target_vm> -Port 5022

# Test listener connectivity
Test-NetConnection -ComputerName <listener_name> -Port 1433
```

## Azure Support Resources

If you're still experiencing issues after trying these troubleshooting steps:

1. Create an Azure support request through the Azure portal
2. For critical production issues, call Azure Support directly
3. Consider engaging the SQL Server Tiger Team for complex issues
4. Check Azure Status for any service issues affecting your region

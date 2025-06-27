# Azure SQL Server High Availability Solution

This repository contains scripts and documentation for deploying and validating a SQL Server High Availability (HA) solution in Azure using Virtual Machines. The solution leverages Azure Availability Sets and SQL Server Always On Availability Groups.

> **Disclaimer**  
> This content was created by Microsoft employees for demonstration and lab purposes only. It is not an official Microsoft package, has not been tested on all supported configurations, and is not intended for production use. Use it at your own risk and discretion.


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

1. **Deploy SQL Server VMs**
The [deploy-sql-ha.sh](scripts/deploy-sql-ha.sh) fully automates the deployment of a production-ready, highly available SQL Server environment on Azure. Here’s what the script sets up:
   - Resource Group with detailed tags for ownership and cost management  
   - Virtual Network (VNet) and subnet for secure isolation  
   - Network Security Group (NSG) with rules for RDP, SQL, and AG endpoints  
   - Availability Set for VM fault domain and update domain separation  
   - Azure Key Vault for secure credential storage  
   - Two SQL Server VMs (Windows + SQL 2019 Standard), fully registered with the SQL IaaS Agent Extension  
   - NICs with accelerated networking enabled for performance  
   - Premium SSD Managed Disks for OS, data, logs, and tempdb (optimized for SQL workloads)  
   - Public IPs (static, standard SKU) for each VM  
   - Azure Backup Recovery Services Vault with daily backup policy for each VM  
   - Azure Monitor Action Group and CPU alert rules for both VMs  
   - Resource lock to prevent accidental deletion  
   - Deployment variable file for easy reuse of environment details  

2. **Configure SQL Server Availability Group**
   - After deploying the SQL VMs, set up the Availability Group with the [setup-availability-group.sh](scripts/setup-availability-group.sh) script.

3. **Validate Your Deployment**
   - After setting up the environment, validate it using the [validate-ha-deployment.sh](scripts/validate-ha-deployment.sh) script.

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

## Azure SQL Server VM Best Practices Implemented

### 1. Security
- Store credentials in Azure Key Vault — never in code or output
- Use managed identities for authentication between services
- Implement Network Security Groups (NSGs) with least-privilege access; scope rules only to required ports (SQL, RDP, AG)
- Enable Transparent Data Encryption (TDE) for databases
- Use Azure Private Link for secure connectivity to services
- Resource lock to prevent accidental resource deletion
- Generate secure, random passwords for SQL admin accounts

### 2. Performance
- Use Premium SSDs for SQL Server data, log, and TempDB files
- Separate data, log, and TempDB files onto dedicated disks for best throughput
- Place TempDB on the local SSD (D:) drive for optimal performance
- Configure proper autogrowth settings for database files
- Size VMs appropriately with adequate memory for SQL Server's buffer pool
- Enable accelerated networking for low-latency traffic
- Optimize disk caching per workload:
  - *ReadOnly* for data disks
  - *None* for log disks
  - *ReadWrite* for TempDB

### 3. High Availability
- Deploy VMs in an Availability Set to spread across fault and update domains
- Register VMs with the SQL IaaS Agent Extension (use retry logic for reliability)
- Explicitly allow AG endpoint traffic (port 5022) in NSGs

### 4. Manageability & Monitoring
- Enable Azure Backup with a policy for daily VM backups
- Configure Azure Monitor for SQL insights and key metrics (CPU, memory, storage, AG health)
- Set up alerts for performance and availability events
- Use SQL Server Extended Events for advanced performance monitoring
- Implement automated backup verification
- Consistent resource tagging for tracking and automation
- Detailed logging for every deployment step

### 5. Deployment Reliability
- Idempotent, robust scripting (e.g., `set -e`, retry logic for transient Azure API failures)
- Wait for RBAC propagation before storing secrets in Key Vault
- Export critical deployment values for use in future automation or teardown

## Troubleshooting
For common issues and solutions, refer to [docs/troubleshooting.md](docs/troubleshooting.md).

Common Issues

- Connection failures to the AG listener
- Synchronization issues between replicas
- Performance problems under load
- Failover failures or unexpected behavior

## 🚦 Recommendations for Production Deployments

While this project demonstrates a reference high-availability SQL Server setup, **additional steps are required for production-grade environments**. For a production deployment, please consider:

- **Harden Security:**  
  - Remove public IPs from SQL VMs and rely on private endpoints and jump hosts/bastion for admin access.
  - Restrict NSG rules to only what’s absolutely necessary.  
  - Enable Azure Defender for SQL and use advanced threat protection.

- **Identity and Access:**  
  - Use managed identities for automation and minimize usage of admin credentials.
  - Implement Just-In-Time (JIT) VM access and Privileged Identity Management (PIM) for admin operations.

- **Backup and DR:**  
  - Define and test regular backup and restore strategies.
  - Consider Geo-Redundant backup vaults and geo-replication for business-critical data.
  - Regularly test failover and restore procedures.

- **High Availability and Resiliency:**  
  - Use Availability Zones instead of just Availability Sets where possible.
  - Deploy a domain controller if required for Windows Clustering.
  - Set up a listener with an Internal Load Balancer for Always On Availability Groups.

- **Monitoring and Alerts:**  
  - Integrate with Azure Monitor, Log Analytics, and set up actionable alerts on health, backups, and performance.
  - Enable SQL Server auditing and diagnostic settings.

- **Cost and Performance:**  
  - Size VMs/disks based on workload; consider Reserved Instances for cost savings.
  - Use Premium SSDs or Ultra Disks as needed for storage performance.

- **Automation and Governance:**  
  - Deploy using Infrastructure as Code (IaC), with parameterization for environments.
  - Apply resource locks, tags, and use policy for governance and compliance.

> For more details, refer to the [Azure SQL VM documentation](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/) and consult with your cloud security and database teams.


## Contributing
Contributions are welcome! Please submit a pull request or open an issue.



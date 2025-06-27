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

2. Configure SQL Server Availability Group

After deploying the SQL VMs, set up the Availability Group with the [setup-availability-group.sh](scripts/setup-availability-group.sh) script.

3. Validate Your Deployment

After setting up the environment, validate it using the [validate-ha-deployment.sh](scripts/validate-ha-deployment.sh) script.

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


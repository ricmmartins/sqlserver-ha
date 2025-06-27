param (
    [Parameter(Mandatory=$true)]
    [string]$PrimaryServer,
    
    [Parameter(Mandatory=$true)]
    [string]$SecondaryServer,
    
    [Parameter(Mandatory=$true)]
    [string]$PrimaryIP,
    
    [Parameter(Mandatory=$true)]
    [string]$SecondaryIP,
    
    [Parameter(Mandatory=$true)]
    [string]$ListenerIP,
    
    [Parameter(Mandatory=$true)]
    [string]$SqlAdminUser,
    
    [Parameter(Mandatory=$true)]
    [string]$SqlAdminPassword,
    
    [string]$AGName = "SQLAG",
    
    [string]$ListenerName = "sqlhagrp",
    
    [int]$ProbePort = 59999
)

# Set up logging
$logFile = "C:\SqlHaConfig_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log {
    param([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -FilePath $logFile -Append
    Write-Output $message
}

Write-Log "Starting SQL Server Basic AG configuration"
Write-Log "Primary Server: $PrimaryServer"
Write-Log "Secondary Server: $SecondaryServer"

# Determine if this is primary or secondary
$currentServer = $env:COMPUTERNAME
$isPrimary = $currentServer -eq $PrimaryServer
$role = if ($isPrimary) { "Primary" } else { "Secondary" }
Write-Log "Current server: $currentServer (Role: $role)"

# 1. Update hosts file for name resolution
Write-Log "Updating hosts file..."
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "`n$PrimaryIP $PrimaryServer" -Force
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "`n$SecondaryIP $SecondaryServer" -Force

# 2. Enable SQL Server Always On feature
Write-Log "Enabling SQL Server Always On..."
Import-Module SqlServer -ErrorAction SilentlyContinue
if (-not $?) {
    Write-Log "SqlServer module not found, installing..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser
    Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber
    Import-Module SqlServer
}

Enable-SqlAlwaysOn -ServerInstance $currentServer -Force
Write-Log "SQL Server Always On enabled"

# 3. Create certificates for authentication
$primaryCertName = "$PrimaryServer-Cert"
$secondaryCertName = "$SecondaryServer-Cert"
$certificateDir = "C:\SQLCertificates"
New-Item -Path $certificateDir -ItemType Directory -Force

Write-Log "Creating certificates for authentication..."
$localCertName = if ($isPrimary) { $primaryCertName } else { $secondaryCertName }
$query = @"
USE master;
IF NOT EXISTS(SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'CertP@ssw0rd123!';
END
IF NOT EXISTS(SELECT * FROM sys.certificates WHERE name = '$localCertName')
BEGIN
    CREATE CERTIFICATE [$localCertName] WITH SUBJECT = 'Certificate for BAG authentication';
    BACKUP CERTIFICATE [$localCertName] TO FILE = '$certificateDir\$localCertName.cer'
        WITH PRIVATE KEY (FILE = '$certificateDir\$localCertName.pvk', 
        ENCRYPTION BY PASSWORD = 'CertP@ssw0rd123!');
END
"@
Invoke-Sqlcmd -ServerInstance $currentServer -Query $query
Write-Log "Local certificate created"

# 4. Create availability group endpoint
Write-Log "Creating database mirroring endpoint..."
$remoteCertName = if ($isPrimary) { $secondaryCertName } else { $primaryCertName }

# Create endpoint
$query = @"
USE master;
IF NOT EXISTS(SELECT * FROM sys.endpoints WHERE name = 'Hadr_endpoint')
BEGIN
    CREATE ENDPOINT [Hadr_endpoint]
       STATE = STARTED
       AS TCP (LISTENER_PORT = 5022)
       FOR DATABASE_MIRRORING (
          ROLE = ALL,
          AUTHENTICATION = CERTIFICATE [$localCertName],
          ENCRYPTION = REQUIRED ALGORITHM AES
       );
END
"@
Invoke-Sqlcmd -ServerInstance $currentServer -Query $query
Write-Log "Database mirroring endpoint created"

# 5. If primary, create database and AG
if ($isPrimary) {
    # Create demo database on primary
    Write-Log "Creating demo database on primary..."
    $DatabaseName = "DemoDatabase"
    $query = @"
    IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = '$DatabaseName')
    BEGIN
        CREATE DATABASE [$DatabaseName];
    END
    ALTER DATABASE [$DatabaseName] SET RECOVERY FULL;
"@
    Invoke-Sqlcmd -ServerInstance $currentServer -Query $query
    
    # Create backup directory with proper permissions
    Write-Log "Creating backup directory..."
    $backupDir = "C:\SQLBackups"
    New-Item -Path $backupDir -ItemType Directory -Force
    
    # Create a backup of the database
    Write-Log "Taking full backup of database..."
    $backupFile = "$backupDir\$DatabaseName.bak"
    $query = @"
    BACKUP DATABASE [$DatabaseName] TO DISK = '$backupFile';
"@
    Invoke-Sqlcmd -ServerInstance $currentServer -Query $query
    
    # Wait for secondary to be ready before creating AG
    Write-Log "Waiting for secondary server preparation..."
    Start-Sleep -Seconds 300
    
    # Create Basic Availability Group
    Write-Log "Creating Basic Availability Group..."
    $query = @"
    IF NOT EXISTS (SELECT * FROM sys.availability_groups WHERE name = '$AGName')
    BEGIN
        CREATE AVAILABILITY GROUP [$AGName]
            WITH (BASIC)
            FOR DATABASE [$DatabaseName]
            REPLICA ON 
                N'$PrimaryServer' WITH 
                (
                    ENDPOINT_URL = N'TCP://$PrimaryServer:5022',
                    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                    FAILOVER_MODE = MANUAL,
                    SEEDING_MODE = MANUAL
                ),
                N'$SecondaryServer' WITH 
                (
                    ENDPOINT_URL = N'TCP://$SecondaryServer:5022',
                    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
                    FAILOVER_MODE = MANUAL,
                    SEEDING_MODE = MANUAL
                );
    END
"@
    Invoke-Sqlcmd -ServerInstance $currentServer -Query $query
    
    # Create AG listener
    Write-Log "Creating Availability Group listener..."
    $query = @"
    IF NOT EXISTS (SELECT * FROM sys.availability_group_listeners WHERE name = '$ListenerName')
    BEGIN
        ALTER AVAILABILITY GROUP [$AGName]
            ADD LISTENER N'$ListenerName' (
                WITH IP
                ((N'$ListenerIP', N'255.255.255.0')),
                PORT=1433);
    END
"@
    Invoke-Sqlcmd -ServerInstance $currentServer -Query $query
}
else {
    # Secondary-specific operations
    Write-Log "Performing secondary-specific operations..."
    
    # Wait for primary operations to complete
    Write-Log "Waiting for primary server to complete setup..."
    Start-Sleep -Seconds 180
    
    # Join the availability group
    Write-Log "Joining the Basic Availability Group..."
    $query = @"
    IF EXISTS (SELECT * FROM sys.availability_groups WHERE name = '$AGName')
    BEGIN
        ALTER AVAILABILITY GROUP [$AGName] JOIN;
        ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE;
    END
"@
    Invoke-Sqlcmd -ServerInstance $currentServer -Query $query -ErrorAction SilentlyContinue
}

# 6. Configure the health probe port in the registry
Write-Log "Configuring health probe port for Load Balancer..."
$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib",
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"
)

foreach ($path in $registryPaths) {
    if (Test-Path $path) {
        New-ItemProperty -Path $path -Name "TcpPortProbeInterval" -Value $ProbePort -PropertyType DWord -Force
        Write-Log "Health probe configured at: $path"
        break
    }
}

# 7. Restart SQL services to apply changes
Write-Log "Restarting SQL Server services to apply configuration changes..."
Restart-Service -Name "MSSQLSERVER" -Force

# 8. Report completion
Write-Log "SQL Server HA configuration script completed"
Write-Log "Basic AG Name: $AGName"
Write-Log "Listener Name: $ListenerName"
Write-Log "Listener IP: $ListenerIP"
Write-Log "Log file: $logFile"

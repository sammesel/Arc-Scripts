# Connect to Azure if not already connected
# Connect-AzAccount

#---------------------------------------------------------------------------------------------------------------------------*
#  Purpose        : Script for Information gathering of Azure SQL DB, SQL MI and SQL on VM
#  Schedule       : Ad-Hoc / On-Demand
#  Date           : 05-07-2025
#  Author         : Sunil Seth
#  Reviewer       : Sunil Seth
#  Version        : 1.0
#  INPUT          : As specified in Usage below:
#  VARIABLE       : NONE
#  PARENT         : NONE
#  CHILD          : NONE
#---------------------------------------------------------------------------------------------------------------------------*
#---------------------------------------------------------------------------------------------------------------------------*
#
#  IMPORTANT NOTE : The script is to determine which License Type was used and if need any modication on Azure SQL,MI.
#  You must be connected to Azure AD and logged in to your Azure account. If your account have access to multiple tenants, make sure to log in with a specific tenant ID.
#  Connect-AzureAD -TenantID <tenant_id>
#---------------------------------------------------------------------------------------------------------------------------*
#---------------------------------------------------------------------------------------------------------------------------*
# Usage:
# Powershell.exe -File .\Modify-SQL-license-type.ps1 [-SubId <sub_id>] [-ResourceGroup <resource_group_name>] [-LicenseType {LicenseIncluded, BasePrice}] [-DBReportOnly {$false, $true}]
#
#You can create a .csv file using the following command and then edit to remove the subscriptions you don't want to scan.

#Get-AzSubscription | Export-Csv .\mysubscriptions.csv -NoTypeInformation
<#
    Change Log
    ----------
     #LicenseIncluded - PAYASYOUGO
     #BasePrice- Azure Hybrid Benefits
#>
$subscriptions = Get-AzSubscription


$allSqlResources = @()

foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id


    $vms = Get-AzVM
    foreach ($vm in $vms) {
        $vmStatus = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState*" }).DisplayStatus

        # Try to get SQL IaaS extension to determine LicenseType
        $sqlVm = Get-AzSqlVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction SilentlyContinue
        $licenseType = if ($sqlVm) { $sqlVm.SqlServerLicenseType } else { "N/A" }

        if ($sqlVm -or $vm.Name -match "sql") {
            $allSqlResources += [PSCustomObject]@{
                Subscription   = $sub.Name
                Name           = $vm.Name
                Type           = "SQLVM"
                Status         = $powerState
                LicenseType    = $licenseType
                ResourceGroup  = $vm.ResourceGroupName
                Location       = $vm.Location
            }
        }
    }

   
    $mis = Get-AzSqlInstance
    foreach ($mi in $mis) {
        $licenseType = if ($mi.LicenseType) { $mi.LicenseType } else { "N/A" }
        $allSqlResources += [PSCustomObject]@{
            Subscription   = $sub.Name
            Name           = $mi.ManagedInstanceName
            Type           = "SQLMI"
            Status         = $mi.state
            LicenseType    = $licenseType
            ResourceGroup  = $mi.ResourceGroupName
            Location       = $mi.Location
        }
    }

    $sqlServers = Get-AzSqlServer
    foreach ($server in $sqlServers) {
        $dbs = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName | Where-Object { $_.DatabaseName -ne "master" }
        foreach ($db in $dbs) {
            $licenseType = if ($db.LicenseType) { $db.LicenseType } else { "N/A" }
            $allSqlResources += [PSCustomObject]@{
                Subscription   = $sub.Name
                Name           = "$($server.ServerName)/$($db.DatabaseName)"
                Type           = "DB"
                Status         = $db.Status
                LicenseType    = $licenseType
                ResourceGroup  = $server.ResourceGroupName
                Location       = $server.Location
            }
        }
    }


    $arcSqlQuery = @"
resources
| where type =~ 'microsoft.hybridcompute/machines/extensions'
| where properties.type in ('WindowsAgent.SqlServer','LinuxAgent.SqlServer')
| parse id with * '/providers/Microsoft.HybridCompute/machines/' machineName '/extensions/' *
| extend LicenseType = properties.settings.LicenseType
| where subscriptionId == '$($sub.Id)'
| project machineName, LicenseType, resourceGroup, subscriptionId
"@

    $arcSqlResults = Search-AzGraph -Query $arcSqlQuery

    foreach ($arcSql in $arcSqlResults) {
        $allSqlResources += [PSCustomObject]@{
            Subscription   = $sub.Name
            Name           = $arcSql.machineName
            Type           = "ArcSQL"
            Status         = "Reported via Arc"
            LicenseType    = $arcSql.LicenseType
            ResourceGroup  = $arcSql.resourceGroup
            Location       = "N/A"
        }
    }
}


$allSqlResources | Sort-Object Subscription, Type, Name | Format-Table -AutoSize


$csvFilePath = "AllAzureSQLResources_WithLicenseType.csv"
$allSqlResources | Export-Csv -Path $csvFilePath -NoTypeInformation

Write-Host "Results exported to $csvFilePath" -ForegroundColor Green

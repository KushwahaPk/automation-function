param($Timer)

# Convert current UTC time to IST
$currentTimeIST = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, [System.TimeZoneInfo]::FindSystemTimeZoneById("India Standard Time"))
Write-Output "Current IST time: $currentTimeIST"

$isWeekend = ($currentTimeIST.DayOfWeek -eq 'Saturday' -or $currentTimeIST.DayOfWeek -eq 'Sunday')
Write-Output "Weekend: $isWeekend"

try {
    Connect-AzAccount -Identity | Out-Null
    Write-Output "Logged in with managed identity"
} catch {
    Write-Error "Failed to login with managed identity: $_"
    return
}

# Get all subscriptions provided (NonProd subscriptions)
$subscriptions = Get-AzSubscription # No need to filter by "NonProd" anymore

foreach ($sub in $subscriptions) {
    try {
        Write-Output "Switching to subscription: $($sub.Name)"
        Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
        Write-Error "Failed to set context for subscription $($sub.Name): $_"
        continue
    }

    # Get all VMs in the current subscription, across all resource groups
    $vms = Get-AzVM -Status
    foreach ($vm in $vms) {
        $tags = $vm.Tags

        # Skip VMs without required tags (no filtering based on "Environment")
        $category = $tags["Parking Catagory"]
        $startTime = $tags["Parking start time"]
        $endTime   = $tags["Parking end time"]

        Write-Output "Checking VM: $($vm.Name) - Category: $category - Start: $startTime - End: $endTime"

        # Ensure all required tags exist (if missing, skip VM)
        if (-not $category -or -not $startTime -or -not $endTime) {
            Write-Output "Skipping VM: $($vm.Name) - Missing one or more required tags"
            continue
        }

        # Check whether the VM's parking category matches based on weekend or daily condition
        if (($isWeekend -and $category -ne "ParkWeekends") -or (-not $isWeekend -and $category -ne "ParkDaily")) {
            continue
        }

        # Convert start and end times to DateTime objects
        $startDateTime = [datetime]::ParseExact($startTime, "HH:mm", $null)
        $endDateTime   = [datetime]::ParseExact($endTime, "HH:mm", $null)

        # Adjust times to today’s date
        $startDateTime = $currentTimeIST.Date.AddHours($startDateTime.Hour).AddMinutes($startDateTime.Minute)
        $endDateTime = $currentTimeIST.Date.AddHours($endDateTime.Hour).AddMinutes($endDateTime.Minute)

        # Get current status of the VM
        $vmStatus = (Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status).Statuses[1].Code

        # Check if it's time to stop the VM (within 1 hour after start time)
        if ($currentTimeIST -ge $startDateTime -and $currentTimeIST -le $startDateTime.AddHours(1)) {
            if ($vmStatus -eq "PowerState/running") {
                Write-Output "Stopping VM: $($vm.Name)"
                Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force
            } else {
                Write-Output "VM already stopped or not running: $($vm.Name)"
            }
        }

        # Check if it's time to start the VM (within 1 hour after end time)
        elseif ($currentTimeIST -ge $endDateTime -and $currentTimeIST -le $endDateTime.AddHours(1)) {
            if ($vmStatus -eq "PowerState/deallocated") {
                Write-Output "Starting VM: $($vm.Name)"
                Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
            } else {
                Write-Output "VM already running or not in stopped state: $($vm.Name)"
            }
        } else {
            Write-Output "VM $($vm.Name) is not in any action window."
        }
    }
}

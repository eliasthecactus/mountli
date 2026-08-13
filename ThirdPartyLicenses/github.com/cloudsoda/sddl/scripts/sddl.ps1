# enable this file with:
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# Test-SddlConversion -Path "path-to-file.ext"
function Test-SddlConversion {
    <#
    .SYNOPSIS
    Converts and displays the Security Descriptor of a file in both SDDL string and binary formats.

    .DESCRIPTION
    This function takes a file path as input, retrieves its Security Descriptor,
    and then displays it in two formats:
    1. As an SDDL (Security Descriptor Definition Language) string
    2. As a base64-encoded binary representation

    .PARAMETER Path
    The path to the file or directory whose Security Descriptor is to be displayed.

    .EXAMPLE
    Test-SddlConversion -Path "C:\Windows\System32\notepad.exe"

    .NOTES
    This function is useful for debugging and verifying Security Descriptor conversions.
    It can help ensure that the SDDL string and binary representations are consistent.
    #>

    param (
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    
    Write-Host "SDDL string:"
    $acl = Get-Acl $Path
    Write-Host $acl.Sddl
    
    Write-Host "`nBase64 binary form:"
    $binary = $acl.GetSecurityDescriptorBinaryForm()
    Write-Host ([Convert]::ToBase64String($binary))
}

# Set-ExecutionPolicy -Path "path-to-file.ext"
function Set-CustomOwnership {
    <#
    .SYNOPSIS
    Sets custom ownership for a file or directory using specified RIDs.

    .DESCRIPTION
    This function changes the owner and group of a specified file or directory
    using Relative Identifiers (RIDs) for the local machine's domain.

    .PARAMETER Path
    The path to the file or directory to modify.

    .PARAMETER OwnerRID
    The RID for the new owner. For example, 500 represents the local Administrator.

    .PARAMETER GroupRID
    The RID for the new group. For example, 512 represents the Domain Admins group.

    .EXAMPLE
    Set-CustomOwnership -Path "C:\example.txt" -OwnerRID 500 -GroupRID 512
    #>

    param (
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$OwnerRID,
        [Parameter(Mandatory=$true)]
        [string]$GroupRID
    )
    
    if (-not (Test-Path $Path)) {
        Write-Error "File not found: $Path"
        return
    }
    
    $localAdmin = Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount = True AND SID LIKE 'S-1-5-21-%-500'"
    if (-not $localAdmin) {
        Write-Error "Could not find local Administrator account"
        return
    }
    
    $sidParts = $localAdmin.SID -split "-"
    if ($sidParts.Length -lt 7) {
        Write-Error "Invalid Administrator SID format"
        return
    }
    
    $domainPart = $sidParts[0..($sidParts.Length-2)] -join "-"
    $ownerSID = "$domainPart-$OwnerRID"
    $groupSID = "$domainPart-$GroupRID"
    
    Write-Host "Constructed Owner SID: $ownerSID"
    Write-Host "Constructed Group SID: $groupSID"
    Write-Host "Current path: $((Get-Item $Path).FullName)"
    
    $acl = Get-Acl $Path
    Write-Host "Current owner: $($acl.Owner)"
    Write-Host "Current group: $($acl.Group)"
    
    try {
        $ownerSid = New-Object System.Security.Principal.SecurityIdentifier($ownerSID)
        $groupSid = New-Object System.Security.Principal.SecurityIdentifier($groupSID)
        
        $acl.SetOwner($ownerSid)
        $acl.SetGroup($groupSid)
        Set-Acl -Path $Path -AclObject $acl
        
        $newAcl = Get-Acl $Path
        Write-Host "New owner: $($newAcl.Owner)"
        Write-Host "New group: $($newAcl.Group)"
    }
    catch {
        Write-Error "Failed to change ownership: $_"
        Write-Error "Exception details: $($_.Exception.Message)"
    }
}

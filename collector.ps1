Function Log {
    param (
    [string]$Text, 
    [string]$Path = $PSScriptRoot)
    if (! (Test-Path "$Path/log.txt")) {New-Item -Path "$Path/log.txt" -ItemType File -Force | Out-Null}
    Write-Host "$(Get-Date) - $Text"
    ("$(Get-Date) - $Text") | Out-File "$Path/log.txt" -Append -Force
}

Function Setup-Collector {
    param ([string]$Path = $PSScriptRoot)

    If (-not [System.IO.File]::Exists("$Path\config")) {
        New-Item -Path "$Path\config" -ItemType File | Out-Null
        $Template = @"
WORKSPACE_ID:
WORKSPACE_KEY:
STORAGE_ACCOUNT:
STORAGE_ACCOUNT_KEY:
COLLECTED_TABLES:
"@
        Set-Content -Value $Template -Path "$Path\config"
        Log("input: please update the configuration file at $("$Path\config") and run the script again.")
        exit 1
    }

    If (-not [System.IO.File]::Exists("$Path\database")) {
        New-Item -Path "$Path\database" -ItemType File | Out-Null
        $Template = "STORAGEACCOUNTNAME;TABLENAME;TIMESTAMP"
        Set-Content -Value $Template -Path "$Path\database"
    }

    $Output = @{
        ConfigPath   = "$Path\config"
        DatabasePath = "$Path\database"
    }
    return $Output
}

Function Get-Config ($Path) {
    Get-Content $Path | Foreach-Object { 
        $var = $_.Split(':') 
        New-Variable -Name $var[0] -Value $var[1]
    }
    $Output = @{
        WorkspaceId       = $WORKSPACE_ID
        WorkspaceKey      = $WORKSPACE_KEY
        StorageAccount    = $STORAGE_ACCOUNT
        StorageAccountKey = $STORAGE_ACCOUNT_KEY
        CollectedTables   = $COLLECTED_TABLES
    }
    Write-Output $Output
}
 
Function Get-StorageContext ($Config) {
    $Context = New-AzStorageContext -StorageAccountName $Config.StorageAccount -StorageAccountKey $Config.StorageAccountKey
    Write-Output $Context
}

Function Get-CloudTables($Context, $Config) {
    $Output = @()
    $Tables = Get-AzStorageTable -Context $Context

    foreach ($Table in $Tables) {
        if ($Config.CollectedTables.Split(",") -contains $Table.Name) {
            $Output += $Table.CloudTable
        }
    }
    return $Output
}

Function Get-LatestTimeStamp($Files, $CloudTable) {
    $Current = Get-Content $Files.DatabasePath | Select-String $CloudTable.Name
    if ([string]::IsNullOrEmpty($Current)) {
        $TimeStamp = Get-Date
    }
    else {
        $TimeStamp = [datetime]$Current.ToString().Split(";")[2] 
    }
    return $TimeStamp 
}

Function Set-Database($Files, $Config, $CloudTable, $LatestTimeStamp, $NewTimeStamp) {
    $Current = Get-Content $Files.DatabasePath | Select-String $CloudTable.Name
    If ([string]::IsNullOrEmpty($NewTimeStamp)) {
        $NewTimeStamp = Get-Date
    }
    If ([string]::IsNullOrEmpty($Current)) {
        $String = "$($Config.StorageAccount);$($CloudTable.Name);$NewTimeStamp"
        Add-Content $Files.DatabasePath $String
    }
    else {
        $String = "$($Config.StorageAccount);$($CloudTable.Name);$LatestTimeStamp"
        $NewString = "$($Config.StorageAccount);$($CloudTable.Name);$NewTimeStamp"

        $Content = (Get-Content $Files.DatabasePath).Replace($String,$NewString)
        Set-Content "$($Files.DatabasePath)" $Content
    }
    Log("set: new timestamp:$NewTimeStamp for table:$($CloudTable.Name) on storageaccount:$($Config.StorageAccount).")
}

Function Get-TableRows ($CloudTable, $LatestTimeStamp) {
    $Rows = Get-AzTableRow -Table $CloudTable -CustomFilter "(TIMESTAMP gt datetime'$($LatestTimeStamp.toString('yyyy-MM-ddTHH:mm:ssZ'))')" | Sort-Object -Property TIMESTAMP
    Write-Output $Rows
}

Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
 
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)
 
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
    return $authorization
}
 
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType, $TimeStampField) {
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
 
    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }
 
    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode
}

$TimeStampField = "TIMESTAMP"
$Files = Setup-Collector
$Config = Get-Config $Files.ConfigPath 
$Context = Get-StorageContext $Config 
$CloudTables = Get-CloudTables $Context $Config
foreach ($CloudTable in $CloudTables) {
    $LatestTimeStamp = ""
    $NewTimeStamp = ""
    $Rows = ""
    $Body = ""
    $LatestTimeStamp = Get-LatestTimeStamp $Files $CloudTable
    $Rows = Get-TableRows $CloudTable $LatestTimeStamp
    $NewTimeStamp = $Rows | Select-Object -Last 1 | Select-Object -ExpandProperty TIMESTAMP
    Set-Database $Files $Config $CloudTable $LatestTimeStamp $NewTimeStamp
    $Body = $Rows | ConvertTo-Json
    if ([string]::IsNullOrEmpty($Body)) {
        Log "output: no log data detected in table:$($CloudTable.Name) since $LatestTimeStamp"
    }
    else {
        Log $(Post-LogAnalyticsData -customerId $Config.WorkspaceId -sharedKey $Config.WorkspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -logType $CloudTable.Name -TimeStampField $TimeStampField)
    }
}

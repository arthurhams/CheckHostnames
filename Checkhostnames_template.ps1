# Input bindings are passed in via param block.
param($Timer)

# Write an information log with the current time.
Write-Host "Start!!"

Import-module 'D:\home\site\wwwroot\modules\dnsclient\dnsclient.psd1' 

$hostnamesfile = "https://<StorageName>.blob.core.windows.net/<ContainerName>/Hostnames.txt"

# Replace with your Workspace ID
$CustomerId = "<CustomerId>"  

# Replace with your Primary Key
$SharedKey = "<SharedKey>"

# Specify the name of the record type that you'll be creating (Log Analytics will appen _CL as Custom Log indication)
$LogType = "Hostnames"

# You can use an optional field to specify the timestamp from the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
$TimeStampField = ""

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}


#Retrieve the list of hostnames from a simple textfile on a blob-read-access Storage Account in Azure, so the list can be updated without having to deploy the script again
$hostnames = Invoke-WebRequest($hostnamesfile)

$results = @() 

foreach($hostname in $hostnames.Content.Split([Environment]::NewLine)) #my file has each hostname on a seperate line, you can also split using semicolon for example
{
            
    if ([string]::IsNullOrEmpty($hostname)) {continue} #skip empty lines
    if (Resolve-DnsName -Name $hostname)
    {
        $cnt = 0;
        foreach($ipaddress in (Resolve-DnsName -Name $hostname).IPAddress)
        {
            $cnt++

            $tmp = New-Object -TypeName PSobject
            $tmp | Add-Member -Name "computername" -Type NoteProperty -Value $env:computername
            $tmp | Add-Member -Name "hostname" -Type NoteProperty -Value $hostname
            $tmp | Add-Member -Name "resolves" -Type NoteProperty -Value $true


            $tmp | Add-Member -Name "ipaddress" -Type NoteProperty -Value $ipaddress 


            $response = D:\home\site\wwwroot\modules\TCPing\tcping -n 1 $ipaddress 
            if ([string]::IsNullOrEmpty($response)) 
            {
                $tmp | Add-Member -Name "Failed" -Type NoteProperty -Value $true 

            } 
            else
            {
                $x = -1
                $x =  select-string -inputObject $response "Maximum"; 
                $x =  ($x.tostring() -split ",")[2] | %{($_ -replace "ms","").trim() }
                $x =  ($x.tostring() -split "=")[1] -as [Float]
                $tmp | Add-Member -Name "ResponseTime" -Type NoteProperty -Value $x
 

                $y = 1
                $y =  select-string -inputObject $response "failed";
                $y =  ($y.tostring() -split ",")[1]
                $y =  $y.SubString(1,1).replace(".","")
 
                $tmp | Add-Member -Name "Failed" -Type NoteProperty -Value $y 
            }
            $results += $tmp
        }

    }
    else
    {
        $tmp = New-Object -TypeName PSobject
        $tmp | Add-Member -Name "computername" -Type NoteProperty -Value $env:computername
        $tmp | Add-Member -Name "hostname" -Type NoteProperty -Value $hostname
        $tmp | Add-Member -Name "resolves" -Type NoteProperty -Value $false              
        $results += $tmp
    }
}
$results

#convert to json to send to LA API
$jsonResults=$results | ConvertTo-Json

#Below code is based on this artice: https://docs.microsoft.com/en-us/azure/azure-monitor/platform/data-collector-api
#--------------------------------------------------------------------------------------------------------------------
# Function to create the authorization signature
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}


# Function to create and post the request
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
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
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}

# Submit the data to the API endpoint
Post-LogAnalyticsData -customerId $CustomerId -sharedKey $SharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonResults)) -logType $logType  

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

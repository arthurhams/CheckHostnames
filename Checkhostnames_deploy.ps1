
# get parameters:
$subscriptionname = "<Target Subscription Name>" # to deploy into
$resourcegroupname = "<Target Resource Group Name>" # to deploy into
$location = "<Target Location>" # to deploy into
$storageaccountname = "<Target Storage Account>" #without .blob.core.windows.net -> to replace {storageaccountname} in pagelayout, you will be asked to override if exists. https://{storageaccountname}.blob.core.windows.net/{containername}/
$functionappname = "<Target Functionappname Account>"
$functionname = "<Target Functionname Account>"
$containername = "<Blob Container Name for Hostnames File" # to replace {containername} in pagelayout, error will be generated if already exists, no problem
$currentdirectory = "<current directory where this file and layout files are located>" #eg c:\somefolder\somesubfolder

$InstallFunc = $false #set to true if Azure Functions SDK Is not yet installed

if ( Test-Path -Path "$currentdirectory\$functionappname" -PathType Container ) 
{
    Remove-Item "$currentdirectory\$functionappname" -Recurse
}
Copy-Item "$currentdirectory\Function_Template" "$currentdirectory\$functionappname" -Recurse

# get AZ
Write-Host Get AZ Module
Get-InstalledModule -Name "Az"

#Connect
#Connect-AzAccount -Subscription $subscriptionname

#create res group if not exists
Write-Host Create Resource Group

Get-AzResourceGroup -Name $resourcegroupname -ErrorVariable notPresent -ErrorAction SilentlyContinue

if ($notPresent)
{
    New-AzResourceGroup -Name $resourcegroupname -Location $location
}
else
{
    Get-AzResourceGroup -Name $resourcegroupname
}

# Deploy storage account
Write-Host Create Storage Account

$StorageAccount = Get-AzStorageAccount -Name $storageaccountname -ResourceGroupName $resourcegroupname -ErrorVariable notPresent -ErrorAction SilentlyContinue

if ($notPresent)
{
    $StorageAccount = New-AzStorageAccount -ResourceGroupName $resourcegroupname -Name $storageaccountname -Location $location -SkuName Standard_LRS -Kind StorageV2
}

Write-Host Create Azure Storage Container
$storageContainer = Get-AzStorageContainer -Name $containername -Context $StorageAccount.Context -ErrorAction SilentlyContinue -ErrorVariable notPresent

if ($notPresent)
{
    $storageContainer = New-AzStorageContainer -Name $containername -Permission Blob -Context $StorageAccount.Context 
}

# Create the workspace
$workspace = Get-AzOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $resourcegroupname -ErrorVariable notPresent -ErrorAction SilentlyContinue
if ($notPresent)
{
    $workspace = New-AzOperationalInsightsWorkspace -Location $Location -Name $WorkspaceName -Sku Standard -ResourceGroupName $resourcegroupname
}

$customerId = $workspace.CustomerId

$sharedkey= Get-AzOperationalInsightsWorkspaceSharedKey  -Name $WorkspaceName -ResourceGroupName $resourcegroupname

# change files -> 
Write-Host Changing Files
cd $currentdirectory


$original_file = '.\Checkhostnames_template.ps1'
$destination_file =  '.\Checkhostnames.ps1'
(Get-Content $original_file) | Foreach-Object {
    $_ -replace '<StorageName>', $storageaccountname `
        -replace '<ContainerName>', $containername `
       -replace '<FunctionName>', $functionname `
       -replace '<CustomerId>', $customerId `
       -replace '<SharedKey>', $sharedkey.PrimarySharedKey `
    } | Set-Content $destination_file


# Add files
Write-Host Copy files to Azure
$contentType = @{"ContentType"="text/plain"}
Set-AzStorageBlobContent –File .\Hostnames.txt –Blob Hostnames.txt -Properties $contentType -Context $StorageAccount.Context -Container $storageContainer.CloudBlobContainer.Name -Force


# create timed function
try
{
    New-AzFunctionApp -Name $functionappname `
                          -ResourceGroupName $resourcegroupname `
                          -Location $location `
                          -StorageAccount $storageaccountname `
                          -Runtime PowerShell
}
catch {
#    Get-AzFunctionApp -Name $functionappname 
                          
}



if ($InstallFunc) { 

    Write-Host -------------I N S T A L L    A Z U R E   F U N C T I O N S   C O R E ------------
    npm install -g azure-functions-core-tools@3
}


    Write-Host -------------A Z U R E    F U N C T I O N ------------
    cd "$currentdirectory\$functionappname"

    #create local function //--worker-runtime powershell 
    func init $functionappname --worker-runtime powershell --language powershell  --force
    
    func new --name $functionname --template "Timer trigger" --worker-runtime powershell  --language powershell --force
    
    #put powershell script
      Copy-Item .\..\$destination_file ".\$functionname\run.ps1" -Force

    Write-Host "Go get a coffee, awaiting deployment of Function App..."
    Start-Sleep 30

    #publish to Azure
    func azure functionapp publish $functionappname


Write-Host "Deploy completed. Please give the Function a few minutes to warm up, 5 minutes for the first run and another few minutes for Log Analytics to digest the data"
Write-Host "Then run below query in your Log Analytics Workspace named $WorkspaceName to check if the function is working correct:"
Write-Host "Hostnames_CL | project hostname_s, ResponseTime_d, TimeGenerated |render timechart"



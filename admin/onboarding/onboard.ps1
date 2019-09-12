param([string]$shortName)

# Handle Login to Azure

$context = Get-AzContext
if ($null -eq $context )
{
    $context = Connect-AzAccount
}


#Common Variables
$edcAADGroup = "c5f931df-8725-4611-9594-378ec0a82c13"

$commonRg = "EDC2019Common"
$commonDls = "edc2019dls"

$commonSubscriptionId = "160c90f1-6bbe-4276-91f3-f732cc0a45db"
$commonSubscriptionName = "Omnia Application Workspace - Sandbox"

$logFile = "onboardErrors.ps1" 

$commonKvName = "EDC2019KV"

$location = "northeurope"

$principalName = "$shortName" + "@equinor.com"
$resourceGroupName = "edc2019_$shortName"
$dfName = "edc2019-" + $shortName + "-df"

$appServicePlanName = "edc2019-" + $shortName + "-asp"
$appServiceName = "edc2019-" + $shortName + "-app" 


$adGroup = Get-AzADGroup -ObjectId $edcAADGroup


# Adding the current user to the shared Databricks-instance

$secretName = "DBricksToken"
Write-Host "Getting Databricks access-token from $commonKvName ... " -NoNewline
$tokenValue = (Get-AzKeyVaultSecret -VaultName $commonKvName -Name $secretName -ErrorAction Stop).SecretValueText
if ($null -eq $tokenValue)
{
     Write-Error "DataBricks Access Token is Null or Empty. Aborting..."
     return;
}
Write-Host "Done" -ForegroundColor Green

$databricksApiUri = "https://northeurope.azuredatabricks.net/api/"
$endPoint = "2.0/preview/scim/v2/Users"
$bearerToken = "Bearer " + $tokenValue
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", $bearerToken)
$groups = @()
$entitlements = @()

$body = @{
    "schemas" = @("urn:ietf:params:scim:schemas:core:2.0:User")
    "groups" = $groups
    "entitlements" = $entitlements
    "userName" = "$shortName@equinor.com"
} | ConvertTo-Json



Write-Host "Setting Subscription to $commonSubscriptionName ... " -NoNewline
Set-AzContext -SubscriptionName $commonSubscriptionId | Out-Null
Write-Host "Done" -ForegroundColor Green

Write-Host "Resolving $principalName => " -NoNewline
$user = Get-AzAdUser -UserPrincipalName $principalName

if ($null -eq $user)
{
    Write-Host Failed -ForegroundColor Red
    return;
}
else {
    Write-Host $user.DisplayName -ForegroundColor Green    
}


$rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue 

if ($null -eq $rg)
{
    Write-Host "Creating ResourceGroup $resourceGroupName ... " -NoNewline
    New-AzResourceGroup -Name $resourceGroupName -Location $location -ErrorAction Stop | Out-Null
    Write-Host "Done" -ForegroundColor Green

    Write-Host "Granting Permission to $principalName ... " -NoNewline
    New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName "Owner" -ResourceGroupName $resourceGroupName | Out-Null
    Write-Host "Done" -ForegroundColor Green

}
else {
    Write-Host "Already exists..." -ForegroundColor "Red"
    return;
}

Write-Host "Creating Data Factory ... " -NoNewline
$df = New-AzDataFactoryV2 -Name $dfName -ResourceGroupName $resourceGroupName -Location $location
Write-Host "Done" -ForegroundColor Green

Write-Host "Creating web app and app service plan ... " -NoNewline
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile "webapp-arm-template.json" -shortName $shortName | Out-Null
Write-Host "Done" -ForegroundColor Green



Write-Host "Setting up DataBricks ... " -NoNewline


try {
    #Write-Host "Add user to EDC2019SharedDatabricks"
    $createUserResponse = Invoke-WebRequest -Method Post -Uri ($databricksApiUri + $endPoint) -Headers $headers -Body $body -ContentType 'application/json'
    if ($createUserResponse.StatusCode -eq "Created")
    {
        Write-Host "Done" -ForegroundColor Green
    }       
    } 
    catch {
    $myError = $_.ErrorDetails.Message
    if ($myError.Contains('"status":"409"')){
        Write-Warning "User already exist"
        }
    else{
        Write-Error "Error: " $myError
    }
}



Write-Host "Waiting 5 seconds for AD to propagate ... " -NoNewline
Start-Sleep -Seconds 5
Write-Host "Done" -ForegroundColor Green


Write-Host "Adding User to OMNIA - EDC2019 ..." -NoNewline
Add-AzADGroupMember -TargetGroupObjectId $adGroup.Id -MemberObjectId $user.Id 
Write-Host "Done" -ForegroundColor Green

try {
    Write-Host "Adding DF MSI to OMNIA - EDC2019 ..." -NoNewline
    $df = Get-AzDataFactoryV2 -Name $dfName -ResourceGroupName $resourceGroupName
    Add-AzADGroupMember -TargetGroupObjectId $adGroup.Id -MemberObjectId $df.Identity.PrincipalId
    Write-Host "Done" -ForegroundColor Green
}
catch {
    Start-Sleep -Seconds 5
    $df = Get-AzDataFactoryV2 -Name $dfName -ResourceGroupName $resourceGroupName
    try {
        Add-AzADGroupMember -TargetGroupObjectId $adGroup.Id -MemberObjectId $df.Identity.PrincipalId    
    }
    catch {
        Add-Content -Path $logFile  -Value "Add-AzADGroupMember -TargetGroupObjectId $($adGroup.Id) -MemberObjectId $($df.Identity.PrincipalId)"    
    }
    
    
}

try {
    Write-Host "Adding WebApp MSI to OMNIA - EDC2019 ..." -NoNewline
    $appService = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $appServiceName
    Add-AzADGroupMember -TargetGroupObjectId $adGroup.Id -MemberObjectId $appService.Identity.PrincipalId
    Write-Host "Done" -ForegroundColor Green
        
}
catch {
    Add-Content -Path $logFile -Value "Add-AzADGroupMember -TargetGroupObjectId $($adGroup.Id) -MemberObjectId $($appService.Identity.PrincipalId)"
}

# create user folder in datalake 

$storageAccount = "edc2019dls"
$fileSystem = "dls"

$tenantId = "3aa4a235-b6e2-48d5-9195-7fcf05b459b0"
$clientId = "6e27dafd-0816-4653-ac63-2d7e01b5d764"

try{
    Write-Host "Creating user folder in datalake ..."
    $clientSecret = (Get-AzKeyVaultSecret -VaultName 'EDC2019KV' -Name 'DlsOnboarding' -ErrorAction Stop ).SecretValueText 

    # Acquire OAuth token
    $body = @{ 
    client_id = $clientId
    client_secret = $clientSecret
    scope = "https://storage.azure.com/.default"
    grant_type = "client_credentials" 
    }
    $token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $body
        
    # Required headers
    
    $headers = @{
            "x-ms-version" = "2018-11-09"
            Authorization = "Bearer " + $token.access_token
    }
     
    $path = "user/$shortName"
    Invoke-WebRequest -Method "Put" -Headers $headers -Uri "https://$storageAccount.dfs.core.windows.net/$fileSystem/$path`?resource=directory"

}
catch{
    Write-Host "Creating user folder in datalake failed" -ForegroundColor Red

}
try{
    Write-Host "Set permission on user folder ..."
    $path = [System.Web.HttpUtility]::UrlEncode($path)
    
    $ownerId = $user.Id
    $groupId = $user.Id
    
    
    $aclFolder = "user::rwx,default:user::rwx,group::rwx,default:group::rwx";
    
    $aclHeaders = @{
            "x-ms-version" = "2018-11-09"
            "x-ms-owner" = $ownerId
            "x-ms-group" = $groupId
            "x-ms-acl" = $aclFolder
            Authorization = "Bearer " + $token.access_token
           
    }

    $uri = "https://$storageAccount.dfs.core.windows.net/$fileSystem"
    Invoke-WebRequest -Headers $aclHeaders -Method "PATCH" -Uri "$uri/$path`?action=setAccessControl"  
}
catch{
    Write-Host "Setting permission on user folder in datalake failed" -ForegroundColor Red

}

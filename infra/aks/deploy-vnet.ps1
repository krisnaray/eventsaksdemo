# PowerShell deployment script for VNet-integrated infrastructure

# Check for Az module and install if needed
if (-not (Get-Module -Name Az -ListAvailable)) {
    Write-Host "Installing Az PowerShell module..."
    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
}

# Set variables
$resourceGroupName = "kk-alt-event-aks-rg"
$location = "northeurope"
$templateFile = ".\main-vnet.bicep"
$parametersFile = ".\main-vnet.parameters.json"

# Login to Azure (uncomment if not already logged in)
# Connect-AzAccount

# Select subscription if needed
# $subscriptionId = "your-subscription-id"
# Set-AzContext -SubscriptionId $subscriptionId

# Create resource group if it doesn't exist
$rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating resource group $resourceGroupName in $location..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}

# Deploy the Bicep template
Write-Host "Deploying AKS and Cosmos DB with VNet integration..."
$deployment = New-AzResourceGroupDeployment `
    -Name "EventAppDeployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile $templateFile `
    -TemplateParameterFile $parametersFile `
    -Verbose

# Output the deployment results
Write-Host "Deployment completed."
Write-Host "AKS Cluster Name: $($deployment.Outputs.aksName.Value)"
Write-Host "ACR Name: $($deployment.Outputs.acrName.Value)"
Write-Host "Cosmos DB Account Name: $($deployment.Outputs.cosmosDbAccountName.Value)"
Write-Host "Cosmos DB Endpoint: $($deployment.Outputs.cosmosDbEndpoint.Value)"

# Get OIDC Issuer URL (needed for workload identity setup)
$aksOidcIssuerUrl = $deployment.Outputs.aksOidcIssuerUrl.Value
Write-Host "AKS OIDC Issuer URL: $aksOidcIssuerUrl"

# Get Managed Identity Client ID (needed for workload identity)
$managedIdentityClientId = $deployment.Outputs.managedIdentityClientId.Value
Write-Host "Managed Identity Client ID: $managedIdentityClientId"

# Export variables for Kubernetes manifests
$env:AKS_MANAGED_IDENTITY_CLIENT_ID = $managedIdentityClientId

# Get AKS credentials
Write-Host "Getting AKS credentials..."
Import-AzAksCredential -ResourceGroupName $resourceGroupName -Name $($deployment.Outputs.aksName.Value) -Force

# Create the Kubernetes namespace
Write-Host "Creating Kubernetes eventapp namespace..."
kubectl create namespace eventapp --dry-run=client -o yaml | kubectl apply -f -

# Create Kubernetes secrets
Write-Host "Creating Cosmos DB endpoint secret..."
kubectl create secret generic cosmosdb-endpoint `
    --from-literal=endpoint=$($deployment.Outputs.cosmosDbEndpoint.Value) `
    -n eventapp `
    --dry-run=client -o yaml | kubectl apply -f -

# Create a random Flask secret
$flaskSecret = [System.Guid]::NewGuid().ToString()
Write-Host "Creating Flask secret key..."
kubectl create secret generic flask-secret `
    --from-literal=flask-secret-key=$flaskSecret `
    -n eventapp `
    --dry-run=client -o yaml | kubectl apply -f -

# Apply the Kubernetes service account with workload identity
Write-Host "Updating backend-sa.yaml with managed identity client ID..."
$saYaml = Get-Content -Path ".\backend-sa.yaml" -Raw
$saYaml = $saYaml -replace '\$\{AKS_MANAGED_IDENTITY_CLIENT_ID\}', $managedIdentityClientId
$saYaml | Set-Content -Path ".\backend-sa.yaml"

Write-Host "Applying backend service account..."
kubectl apply -f .\backend-sa.yaml

# Update the backend-deployment.yaml with the correct managed identity client ID
Write-Host "Updating backend deployment with managed identity client ID..."
$backendDeploymentYaml = Get-Content -Path ".\backend-deployment.yaml" -Raw
$backendDeploymentYaml = $backendDeploymentYaml -replace '\$\(AKS_MANAGED_IDENTITY_CLIENT_ID\)', $managedIdentityClientId
$backendDeploymentYaml | Set-Content -Path ".\backend-deployment.yaml"

Write-Host "Successfully deployed infrastructure with VNet integration!"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Build and push your container images to $($deployment.Outputs.acrName.Value)"
Write-Host "2. Apply your updated Kubernetes manifests: kubectl apply -f backend-deployment.yaml"
Write-Host "3. Apply frontend deployment: kubectl apply -f frontend-deployment.yaml"

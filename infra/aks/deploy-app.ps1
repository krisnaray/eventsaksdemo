# Deploy Kubernetes manifests after infrastructure is set up

# Get the AKS_MANAGED_IDENTITY_CLIENT_ID value
if (-not $env:AKS_MANAGED_IDENTITY_CLIENT_ID) {
    Write-Host "AKS_MANAGED_IDENTITY_CLIENT_ID not set. Getting from Azure..."
    $identity = az identity show -g kk-alt-event-aks-rg -n backend-identity --query clientId -o tsv
    $env:AKS_MANAGED_IDENTITY_CLIENT_ID = $identity
    Write-Host "Set AKS_MANAGED_IDENTITY_CLIENT_ID to $identity"
}

# Update the service account YAML with the managed identity client ID
Write-Host "Updating backend-sa.yaml with managed identity client ID..."
$saYaml = Get-Content -Path ".\backend-sa.yaml" -Raw
$saYaml = $saYaml -replace '\$\{AKS_MANAGED_IDENTITY_CLIENT_ID\}', $env:AKS_MANAGED_IDENTITY_CLIENT_ID
$saYaml | Set-Content -Path ".\backend-sa.yaml"

# Update the backend deployment YAML with the managed identity client ID
Write-Host "Updating backend deployment with managed identity client ID..."
$backendDeploymentYaml = Get-Content -Path ".\backend-deployment-vnet.yaml" -Raw
$backendDeploymentYaml = $backendDeploymentYaml -replace '\$\(AKS_MANAGED_IDENTITY_CLIENT_ID\)', $env:AKS_MANAGED_IDENTITY_CLIENT_ID
$backendDeploymentYaml | Set-Content -Path ".\backend-deployment-vnet.yaml"

# Apply namespace
Write-Host "Creating eventapp namespace..."
kubectl create namespace eventapp --dry-run=client -o yaml | kubectl apply -f -

# Create necessary secrets
Write-Host "Creating Cosmos DB endpoint secret..."
$cosmosEndpoint = az cosmosdb show --name kkalteventcosmosdb --resource-group kk-alt-event-aks-rg --query documentEndpoint -o tsv
kubectl create secret generic cosmosdb-endpoint --from-literal=endpoint=$cosmosEndpoint -n eventapp --dry-run=client -o yaml | kubectl apply -f -

Write-Host "Creating Flask secret key..."
$flaskSecret = [System.Guid]::NewGuid().ToString()
kubectl create secret generic flask-secret --from-literal=flask-secret-key=$flaskSecret -n eventapp --dry-run=client -o yaml | kubectl apply -f -

# Apply service account for managed identity
Write-Host "Applying backend service account..."
kubectl apply -f .\backend-sa.yaml

# Apply backend deployment
Write-Host "Applying backend deployment..."
kubectl apply -f .\backend-deployment-vnet.yaml

# Apply frontend deployment
Write-Host "Applying frontend deployment..."
kubectl apply -f .\frontend-deployment-vnet.yaml

# Apply ingress
Write-Host "Applying ingress configuration..."
kubectl apply -f .\ingress.yaml

# Check deployment status
Write-Host "Checking deployment status..."
Start-Sleep -Seconds 5
kubectl get pods -n eventapp
kubectl get services -n eventapp
kubectl get ingress -n eventapp

Write-Host "Deployment complete! It may take a few minutes for services to be fully available."
Write-Host "Monitor pod status with: kubectl get pods -n eventapp -w"

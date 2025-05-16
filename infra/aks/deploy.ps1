#!/usr/bin/env pwsh
# Automated deployment script for Event Management Application

# Set your parameters here
$RESOURCE_GROUP = "kk-alt-event-aks-rg"
$LOCATION = "northeurope"
$AKS_NAME = "kk-alt-event-aks"
$ACR_NAME = "kkalteventacr" # Must be globally unique
$COSMOS_DB_NAME = "kkalteventcosmosdb" # Must be globally unique
$APP_ROOT = "d:\alt\al-kk-demo-apps"

Write-Output "=== Event Management App Deployment Script ==="
Write-Output "This script will deploy the entire application to AKS."

# Step 1: Create resource group
Write-Output "`n[Step 1/10] Creating resource group..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# Step 2: Update parameters file
Write-Output "`n[Step 2/10] Updating parameters file..."
@"
// Parameters for AKS and Cosmos DB deployment
param location string = '$LOCATION'
param resourceGroupName string = '$RESOURCE_GROUP'
param aksClusterName string = '$AKS_NAME'
param acrName string = '$ACR_NAME'
param cosmosDbAccountName string = '$COSMOS_DB_NAME'
param cosmosDbDatabaseName string = 'EventManagement'
param cosmosDbContainerName string = 'Events'
param managedIdentityName string = 'eventapp-identity'
"@ | Out-File -FilePath "$APP_ROOT\infra\aks\main.parameters.bicep" -Encoding utf8

# Step 3: Deploy Azure resources with Bicep
Write-Output "`n[Step 3/10] Deploying Azure resources (AKS, ACR, Cosmos DB)..."
Write-Output "This may take 10-15 minutes..."
az deployment group create --resource-group $RESOURCE_GROUP --template-file "$APP_ROOT\infra\aks\main.bicep" --parameters "@$APP_ROOT\infra\aks\main.parameters.bicep"

# Step 4: Connect to AKS
Write-Output "`n[Step 4/10] Connecting to AKS cluster..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

# Step 5: Build and push Docker images to ACR
Write-Output "`n[Step 5/10] Building and pushing Docker images to ACR..."
Write-Output "Building backend image..."
az acr build --registry $ACR_NAME --image backend:latest "$APP_ROOT\backend"

Write-Output "Building frontend image..."
az acr build --registry $ACR_NAME --image frontend:latest "$APP_ROOT\frontend"

# Step 6: Get Cosmos DB endpoint
Write-Output "`n[Step 6/10] Getting Cosmos DB endpoint..."
$COSMOS_ENDPOINT = az cosmosdb show --name $COSMOS_DB_NAME --resource-group $RESOURCE_GROUP --query "documentEndpoint" -o tsv

# Step 7: Generate Flask secret and prepare secrets file
Write-Output "`n[Step 7/10] Preparing Kubernetes secrets..."
$FLASK_SECRET = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object {[char]$_})

# Base64 encode the secrets
$ENDPOINT_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($COSMOS_ENDPOINT))
$SECRET_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($FLASK_SECRET))

# Update the k8s-namespace-secrets.yaml file
(Get-Content -Path "$APP_ROOT\infra\aks\k8s-namespace-secrets.yaml") -replace '<BASE64_COSMOSDB_ENDPOINT>', $ENDPOINT_B64 | Set-Content -Path "$APP_ROOT\infra\aks\k8s-namespace-secrets.yaml"
(Get-Content -Path "$APP_ROOT\infra\aks\k8s-namespace-secrets.yaml") -replace '<BASE64_FLASK_SECRET>', $SECRET_B64 | Set-Content -Path "$APP_ROOT\infra\aks\k8s-namespace-secrets.yaml"

# Step 8: Update image references in deployment files
Write-Output "`n[Step 8/10] Updating Kubernetes deployment files..."
(Get-Content -Path "$APP_ROOT\infra\aks\backend-deployment.yaml") -replace '<ACR_NAME>', $ACR_NAME | Set-Content -Path "$APP_ROOT\infra\aks\backend-deployment.yaml"
(Get-Content -Path "$APP_ROOT\infra\aks\frontend-deployment.yaml") -replace '<ACR_NAME>', $ACR_NAME | Set-Content -Path "$APP_ROOT\infra\aks\frontend-deployment.yaml"

# Step 9: Deploy to AKS
Write-Output "`n[Step 9/10] Deploying the application to AKS..."
kubectl apply -f "$APP_ROOT\infra\aks\k8s-namespace-secrets.yaml"
kubectl apply -f "$APP_ROOT\infra\aks\backend-deployment.yaml"
kubectl apply -f "$APP_ROOT\infra\aks\frontend-deployment.yaml"

# Step 10: Get service IPs and update frontend
Write-Output "`n[Step 10/10] Configuring services and retrieving access details..."
Write-Output "Waiting for services to get external IPs (this may take a few minutes)..."

# Wait for services to get external IPs
$attempts = 0
$max_attempts = 30
$backend_ip = $null
$frontend_ip = $null

while (($attempts -lt $max_attempts) -and (($null -eq $backend_ip) -or ($null -eq $frontend_ip))) {
    Start-Sleep -Seconds 10
    $attempts++
    
    Write-Output "Checking for external IPs (attempt $attempts/$max_attempts)..."
    
    try {
        $backend_ip = kubectl get svc backend -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        $frontend_ip = kubectl get svc frontend -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    }
    catch {
        Write-Output "  Services not ready yet..."
    }
    
    if ($backend_ip -and $frontend_ip) {
        Write-Output "  Both services have external IPs now!"
    }
    else {
        Write-Output "  Still waiting for external IPs..."
    }
}

if ($backend_ip -and $frontend_ip) {
    # Update frontend to use backend IP and redeploy
    (Get-Content -Path "$APP_ROOT\infra\aks\frontend-deployment.yaml") -replace 'http://<BACKEND_PUBLIC_IP>:5000', "http://$backend_ip`:5000" | Set-Content -Path "$APP_ROOT\infra\aks\frontend-deployment.yaml"
    kubectl apply -f "$APP_ROOT\infra\aks\frontend-deployment.yaml"
    
    Write-Output "`n=== DEPLOYMENT COMPLETE ==="
    Write-Output "Backend API: http://$backend_ip`:5000"
    Write-Output "Frontend UI: http://$frontend_ip"
    Write-Output "`nPlease allow a few moments for the redeployed frontend to connect to the backend."
}
else {
    Write-Output "`nTimeout while waiting for external IPs. Please check your deployment manually:"
    Write-Output "kubectl get svc -n eventapp"
}

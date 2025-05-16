#!/usr/bin/env pwsh
# Automated deployment script for Event Management Application
# This script deploys all infrastructure and application components without manual steps

# Set your parameters here
$RESOURCE_GROUP = "eventapp-rg"
$LOCATION = "eastus"
$AKS_NAME = "eventapp-aks"
$ACR_NAME = "eventappacr" # Must be globally unique
$COSMOS_DB_NAME = "eventappcosmosdb" # Must be globally unique
$MANAGED_IDENTITY_NAME = "eventapp-identity"

# Generate SSH key if none is provided
$SSH_PUBLIC_KEY = ""
# Check if user has an SSH key
$sshKeyPath = "$HOME/.ssh/id_rsa.pub"
if (Test-Path $sshKeyPath) {
    $SSH_PUBLIC_KEY = Get-Content $sshKeyPath -Raw
    Write-Output "Using existing SSH public key from $sshKeyPath"
} else {
    Write-Output "No SSH key found at $sshKeyPath."
    Write-Output "You should generate an SSH key pair using 'ssh-keygen' before continuing."
    Write-Output "Or provide a valid SSH public key in the parameters."
    exit 1
}

Write-Output "=== Event Management App Deployment Script ==="
Write-Output "This script will deploy the entire application to AKS."

# Step 1: Create resource group
Write-Output "`n[Step 1/11] Creating resource group..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# Step 2: Update parameters file for Bicep
Write-Output "`n[Step 2/11] Creating parameters file..."
@"
{
  "`$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "value": "$LOCATION"
    },
    "aksClusterName": {
      "value": "$AKS_NAME"
    },
    "acrName": {
      "value": "$ACR_NAME"
    },
    "cosmosDbAccountName": {
      "value": "$COSMOS_DB_NAME"
    },
    "cosmosDbDatabaseName": {
      "value": "EventManagement"
    },    "cosmosDbContainerName": {
      "value": "Events"
    },
    "managedIdentityName": {
      "value": "$MANAGED_IDENTITY_NAME"
    },
    "sshPublicKey": {
      "value": "$SSH_PUBLIC_KEY"
    }
  }
}
"@ | Out-File -FilePath "main.parameters.json" -Encoding utf8

# Step 3: Deploy Azure resources with Bicep
Write-Output "`n[Step 3/11] Deploying Azure resources (AKS, ACR, Cosmos DB)..."
Write-Output "This may take 10-15 minutes..."
$deployment = az deployment group create --resource-group $RESOURCE_GROUP --template-file main.bicep --parameters @main.parameters.json --query "properties.outputs" -o json | ConvertFrom-Json

# Extract outputs
$COSMOS_ENDPOINT = $deployment.cosmosDbEndpoint.value
$MANAGED_IDENTITY_CLIENT_ID = $deployment.managedIdentityClientId.value
$AKS_OIDC_ISSUER = $deployment.aksOidcIssuerUrl.value

Write-Output "Cosmos DB Endpoint: $COSMOS_ENDPOINT"
Write-Output "Managed Identity Client ID: $MANAGED_IDENTITY_CLIENT_ID"
Write-Output "AKS OIDC Issuer URL: $AKS_OIDC_ISSUER"

# Step 4: Connect to AKS
Write-Output "`n[Step 4/11] Connecting to AKS cluster..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

# Step 5: Build and push Docker images to ACR
Write-Output "`n[Step 5/11] Building and pushing Docker images to ACR..."
Write-Output "Building backend image..."
az acr build --registry $ACR_NAME --image backend:latest ..\backend

Write-Output "Building frontend image..."
az acr build --registry $ACR_NAME --image frontend:latest ..\frontend

# Step 6: Generate Flask secret key
Write-Output "`n[Step 6/11] Generating Flask secret key..."
$FLASK_SECRET = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object {[char]$_})

# Step 7: Create namespace and secrets
Write-Output "`n[Step 7/11] Creating Kubernetes namespace and secrets..."
kubectl create namespace eventapp --dry-run=client -o yaml | kubectl apply -f -

# Create Cosmos DB endpoint secret
kubectl create secret generic cosmosdb-endpoint --from-literal=endpoint=$COSMOS_ENDPOINT -n eventapp --dry-run=client -o yaml | kubectl apply -f -

# Create Flask secret
kubectl create secret generic flask-secret --from-literal=flask-secret-key=$FLASK_SECRET -n eventapp --dry-run=client -o yaml | kubectl apply -f -

# Step 8: Update service account with managed identity
Write-Output "`n[Step 8/11] Setting up service account with workload identity..."
$saYaml = Get-Content -Path "backend-sa.yaml" -Raw
$saYaml = $saYaml -replace 'azure.workload.identity/client-id: ".*"', "azure.workload.identity/client-id: `"$MANAGED_IDENTITY_CLIENT_ID`""
$saYaml | Out-File -FilePath "backend-sa.yaml" -Encoding utf8
kubectl apply -f backend-sa.yaml

# Step 9: Deploy backend
Write-Output "`n[Step 9/11] Deploying backend to AKS..."
$backendYaml = Get-Content -Path "backend-deployment.yaml" -Raw
$backendYaml = $backendYaml -replace 'AZURE_CLIENT_ID.*value: ".*"', "AZURE_CLIENT_ID`n          value: `"$MANAGED_IDENTITY_CLIENT_ID`""
$backendYaml = $backendYaml -replace 'kkalteventacr.azurecr.io', "$ACR_NAME.azurecr.io"
$backendYaml | Out-File -FilePath "backend-deployment.yaml" -Encoding utf8

kubectl apply -f backend-deployment.yaml

# Step 10: Wait for backend service to get external IP
Write-Output "`n[Step 10/11] Waiting for backend service to get external IP..."
$attempts = 0
$max_attempts = 30
$backend_ip = $null

while (($attempts -lt $max_attempts) -and ($null -eq $backend_ip)) {
    Start-Sleep -Seconds 10
    $attempts++
    
    Write-Output "Checking for backend external IP (attempt $attempts/$max_attempts)..."
    
    try {
        $backend_ip = kubectl get svc backend -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        if ($backend_ip -and $backend_ip -ne "") {
            Write-Output "Backend service external IP: $backend_ip"
        }
    } catch {
        Write-Output "Still waiting for backend external IP..."
    }
}

if ($null -eq $backend_ip) {
    Write-Output "Could not get backend external IP after $max_attempts attempts."
    exit 1
}

# Step 11: Deploy frontend with init container to replace localhost:5000 with backend IP
Write-Output "`n[Step 11/11] Deploying frontend with updated backend API URL..."

@"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: eventapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      initContainers:
      - name: init-js-fix
        image: alpine:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            apk add --no-cache sed
            cd /usr/share/nginx/html
            # Find and replace the hardcoded localhost URLs
            for f in \$(find . -type f -name "*.js"); do
              echo "Processing \$f"
              sed -i 's|http://localhost:5000|http://$backend_ip:5000|g' \$f
            done
            echo "URL replacement completed"
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      containers:
      - name: frontend
        image: $ACR_NAME.azurecr.io/frontend:latest
        ports:
        - containerPort: 80
        env:
        - name: REACT_APP_API_URL
          value: "http://$backend_ip:5000"
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
      volumes:
      - name: html
        emptyDir: {}
      nodeSelector:
        kubernetes.io/os: linux
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: eventapp
spec:
  selector:
    app: frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: LoadBalancer
"@ | Out-File -FilePath "frontend-deployment-current.yaml" -Encoding utf8

kubectl apply -f frontend-deployment-current.yaml

# Wait for frontend service to get external IP
$attempts = 0
$frontend_ip = $null

while (($attempts -lt $max_attempts) -and ($null -eq $frontend_ip)) {
    Start-Sleep -Seconds 10
    $attempts++
    
    Write-Output "Checking for frontend external IP (attempt $attempts/$max_attempts)..."
    
    try {
        $frontend_ip = kubectl get svc frontend -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        if ($frontend_ip -and $frontend_ip -ne "") {
            Write-Output "Frontend service external IP: $frontend_ip"
        }
    } catch {
        Write-Output "Still waiting for frontend external IP..."
    }
}

if ($null -eq $frontend_ip) {
    Write-Output "Could not get frontend external IP after $max_attempts attempts."
    exit 1
}

# Step 12: Deploy API test pod if requested
Write-Output "`n[Step 12/12] Deploying API test pod (optional)..."
$deployApiTest = Read-Host "Do you want to deploy an API test pod? (y/n)"

if ($deployApiTest -eq "y") {
    # Generate API test HTML with proper backend URL
    $apiTestHtml = Get-Content -Path "apitest.template.html" -Raw
    $apiTestHtml = $apiTestHtml -replace '{{BACKEND_API_URL}}', "http://$backend_ip`:5000"
    
    # Create configmap for the API test HTML
    kubectl create configmap apitest --from-literal=apitest.html="$apiTestHtml" -n eventapp --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply the API test pod
    kubectl apply -f apitest.yaml
    
    # Wait for the API test pod to get an IP
    $attempts = 0
    $apitest_ip = $null
    
    while (($attempts -lt $max_attempts) -and ($null -eq $apitest_ip)) {
        Start-Sleep -Seconds 10
        $attempts++
        
        Write-Output "Checking for API test external IP (attempt $attempts/$max_attempts)..."
        
        try {
            $apitest_ip = kubectl get svc apitest -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
            if ($apitest_ip -and $apitest_ip -ne "") {
                Write-Output "API test service external IP: $apitest_ip"
            }
        } catch {
            Write-Output "Still waiting for API test external IP..."
        }
    }
    
    if ($null -ne $apitest_ip) {
        Write-Output "API test URL: http://$apitest_ip"
    }
}

# Display access information
Write-Output "`n=== Deployment Complete ==="
Write-Output "Backend API URL: http://$backend_ip:5000"
Write-Output "Frontend URL: http://$frontend_ip"
Write-Output "`nTry accessing the frontend URL in your browser to verify the application is working."

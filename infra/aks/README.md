# Event Management Application - Azure Kubernetes Service (AKS) Deployment

This document provides comprehensive instructions for deploying the Event Management application to Azure Kubernetes Service (AKS).

> **Note**: The deployment YAML files with *-fixed* in their names are for reference only and contain hardcoded values. 
> Actual deployments should use either the automated script (deploy-full.ps1) or follow the manual deployment steps,
> which will generate/update deployment files with the correct dynamic values.

## Architecture

The Event Management application consists of:

- **Frontend**: React.js application for managing events
- **Backend**: Flask API service for CRUD operations
- **Database**: Azure Cosmos DB SQL API for data storage
- **Authentication**: Azure Managed Identity for secure access to Cosmos DB

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [PowerShell Core 7+](https://github.com/PowerShell/PowerShell) installed
- Azure subscription with permissions to create resources

## Deployment Options

### Option 1: Automated Deployment (Recommended)

The automated deployment script handles all steps from infrastructure provisioning to application deployment.

```powershell
# Navigate to the aks directory
cd infra/aks

# Make sure you have an SSH key at ~/.ssh/id_rsa.pub
# If not, generate one using: ssh-keygen -t rsa

# Edit deploy-full.ps1 to customize parameters like resource group name, location, etc.

# Run the deployment script
./deploy-full.ps1
```

The script will:
1. Create Azure resources (AKS, ACR, Cosmos DB) using Bicep templates
2. Build and push Docker images to ACR
3. Set up Kubernetes namespace, secrets, and service accounts
4. Deploy backend with managed identity
5. Deploy frontend with proper backend URL configuration
6. Output the application URLs

### Option 2: Manual Deployment

If you prefer step-by-step deployment or need to customize specific components, follow these steps:

#### 1. Update SSH Key in Bicep Template

Replace the placeholder SSH public key in `main.bicep` with your SSH public key:

```
keyData: 'ssh-rsa YOUR_ACTUAL_PUBLIC_KEY'
```

#### 2. Create Azure Resources

```powershell
# Create resource group
$RESOURCE_GROUP="eventapp-rg"
$LOCATION="eastus"
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy infrastructure with Bicep
az deployment group create --resource-group $RESOURCE_GROUP --template-file main.bicep --parameters @main.parameters.json
```

#### 3. Connect to AKS

```powershell
az aks get-credentials --resource-group $RESOURCE_GROUP --name eventapp-aks --overwrite-existing
```

#### 4. Build and Push Docker Images

```powershell
$ACR_NAME="eventappacr" # Update with your ACR name

# Build and push backend image
az acr build --registry $ACR_NAME --image backend:latest ../backend

# Build and push frontend image
az acr build --registry $ACR_NAME --image frontend:latest ../frontend
```

#### 5. Create Kubernetes Resources

```powershell
# Get outputs from deployment
$COSMOS_ENDPOINT=$(az cosmosdb show --name eventappcosmosdb --resource-group $RESOURCE_GROUP --query documentEndpoint -o tsv)
$MANAGED_IDENTITY_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n eventapp-identity --query clientId -o tsv)

# Create namespace
kubectl create namespace eventapp

# Create secrets
kubectl create secret generic cosmosdb-endpoint --from-literal=endpoint=$COSMOS_ENDPOINT -n eventapp
kubectl create secret generic flask-secret --from-literal=flask-secret-key=$(New-Guid) -n eventapp

# Update service account with managed identity
$saYaml = Get-Content -Path "backend-sa.yaml" -Raw
$saYaml = $saYaml -replace 'azure.workload.identity/client-id: ".*"', "azure.workload.identity/client-id: `"$MANAGED_IDENTITY_CLIENT_ID`""
$saYaml | Out-File -FilePath "backend-sa.yaml" -Encoding utf8
kubectl apply -f backend-sa.yaml

# Deploy backend
kubectl apply -f backend-deployment.yaml

# Wait for backend to get IP
$BACKEND_IP=$(kubectl get svc backend -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

#### 6. Deploy Frontend with Init Container

Create and apply a frontend deployment manifest that uses an init container to replace hardcoded API URLs:

```powershell
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
              sed -i 's|http://localhost:5000|http://$BACKEND_IP:5000|g' \$f
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
          value: "http://$BACKEND_IP:5000"
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

# Get frontend public IP
$FRONTEND_IP=$(kubectl get svc frontend -n eventapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

Write-Output "Backend API available at: http://$BACKEND_IP:5000"
Write-Output "Frontend UI available at: http://$FRONTEND_IP"
```

## Repository Structure

The repository is organized as follows:

```
.
├── backend/               # Backend Flask API code
├── frontend/              # Frontend React application
└── infra/                 # Infrastructure deployment code
    ├── aci/               # Azure Container Instances deployment
    ├── aks/               # Azure Kubernetes Service deployment
    │   ├── main.bicep     # Main Bicep template for AKS deployment
    │   ├── main-vnet.bicep # Bicep template with VNet integration
    │   ├── deploy-full.ps1 # Automated deployment script
    │   ├── *.yaml         # Kubernetes manifests
    │   └── README.md      # Deployment instructions
    ├── appservice/        # Azure App Service deployment
    └── functions/         # Azure Functions deployment
```

## Customizing the Deployment

### Modifying Infrastructure Parameters

Edit the `main.parameters.template.json` file to customize:
- Resource naming
- Azure region
- Kubernetes cluster size
- Cosmos DB configuration

### Securing Cosmos DB

By default, the deployment uses:
- Managed Identity for secure authentication
- Role-Based Access Control for least-privilege access

For enhanced security in production:
- Set `publicNetworkAccess: 'Disabled'` in the Cosmos DB resource
- Enable VNet integration using the `main-vnet.bicep` template

## Testing the Deployment

### Standard Testing

1. After deployment, access the frontend at the URL provided
2. Test creating, reading, updating, and deleting events
3. Verify all operations work correctly between frontend, backend, and database

### API Testing

The deployment script can optionally deploy an API test pod with a simple HTML page to test the backend API:

```powershell
# Choose 'y' when asked about deploying the API test pod
Do you want to deploy an API test pod? (y/n): y
```

This will:
1. Create a ConfigMap with the API test HTML (pointing to your backend)
2. Deploy a test pod that serves this HTML
3. Create a LoadBalancer service to access the test page

You can access the test page at the URL provided after deployment.

## Troubleshooting

### Backend Container Not Starting

Check Pod logs for issues:

```powershell
kubectl logs -n eventapp deployment/backend
```

Common issues:
- Managed identity not configured correctly
- Cosmos DB role assignments not applied

### Frontend Shows Error or Blank Screen

Check if the frontend can access the backend:

```powershell
kubectl exec -it $(kubectl get pods -n eventapp -l app=frontend -o name) -n eventapp -- curl -v http://<backend-ip>:5000/events
```

Common issues:
- Hardcoded localhost:5000 references in frontend code
- Backend service not exposed or accessible

### Checking RBAC Assignments

Verify role assignments for Cosmos DB:

```powershell
az role assignment list --assignee $MANAGED_IDENTITY_CLIENT_ID --all -o table
```

### Checking Managed Identity

Verify the workload identity setup:

```powershell
kubectl describe serviceaccount backend-sa -n eventapp
```

## Cleanup

To delete all deployed resources:

```powershell
# Delete Kubernetes resources
kubectl delete namespace eventapp

# Delete Azure resources
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

# VNet-Integrated Event Management Application Deployment Guide

This guide explains how to deploy the Event Management application with VNet integration for enhanced security between AKS and Cosmos DB.

## Architecture

This deployment uses:

- AKS within a Virtual Network
- Cosmos DB with VNet Service Endpoints
- Managed Identity and Workload Identity for authentication
- Proper network security rules to restrict access

## Deployment Steps

### 1. Deploy VNet-Integrated Infrastructure

Execute the deploy-vnet.ps1 script to create all required Azure resources:

```powershell
cd infra/aks
./deploy-vnet.ps1
```

This script will:
- Create a Virtual Network with subnets for AKS and services
- Deploy AKS with Azure CNI networking inside the VNet
- Deploy Cosmos DB with VNet integration
- Set up Managed Identity and RBAC permissions
- Configure Workload Identity Federation

### 2. Build and Push Container Images 

Once the infrastructure is deployed:

```powershell
# Log in to ACR
$acrName = az acr list --query "[0].name" -o tsv
az acr login --name $acrName

# Build and push backend
cd ../../backend
docker build -t "$acrName.azurecr.io/backend:latest" .
docker push "$acrName.azurecr.io/backend:latest"

# Build and push frontend
cd ../frontend
docker build -t "$acrName.azurecr.io/frontend:latest" .
docker push "$acrName.azurecr.io/frontend:latest"
```

### 3. Deploy Kubernetes Resources

Return to the infra/aks directory and run:

```powershell
cd ../infra/aks
./deploy-app.ps1
```

This will:
- Configure Kubernetes service account with Workload Identity
- Deploy backend and frontend applications
- Set up ingress for external access

### 4. Access Your Application

Get the public IP of your frontend service:

```powershell
kubectl get service -n eventapp frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

The application will be accessible at http://<EXTERNAL-IP>

## Security Benefits of This Approach

1. **Network Isolation**: 
   - Backend components are only accessible within the VNet
   - Cosmos DB accepts connections only from authorized Azure services and VNet subnets

2. **Zero Secrets Management**: 
   - Uses Workload Identity instead of connection strings or service principals
   - No secrets stored in Kubernetes or application configurations

3. **Least Privilege Access**:
   - Service accounts have only the permissions they need
   - RBAC controls at both Kubernetes and Azure levels

## Troubleshooting

If you encounter issues:

1. Check pod status:
   ```powershell
   kubectl get pods -n eventapp
   kubectl describe pod -n eventapp <pod-name>
   ```

2. Check logs:
   ```powershell
   kubectl logs -n eventapp <pod-name>
   ```

3. Verify network connectivity:
   ```powershell
   # From a debug pod in the cluster
   kubectl run -it --rm debug --image=mcr.microsoft.com/dotnet/runtime-deps:6.0 -n eventapp -- bash
   apt-get update && apt-get install -y curl
   curl backend:5000/events
   ```

4. Verify managed identity:
   ```powershell
   kubectl exec -it <pod-name> -n eventapp -- env | grep AZURE
   ```

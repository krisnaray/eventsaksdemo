# Build and push backend image
az acr build --registry <ACR_NAME> --image backend:latest ../backend

# Build and push frontend image
az acr build --registry <ACR_NAME> --image frontend:latest ../frontend

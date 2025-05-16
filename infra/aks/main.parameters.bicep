// Parameters for AKS and Cosmos DB deployment
param location string = 'northeurope'
param resourceGroupName string = 'kk-alt-event-aks-rg'
param aksClusterName string = 'kk-alt-event-aks'
param acrName string = 'kkalteventacr'
param cosmosDbAccountName string = 'kkalteventcosmosdb'
param cosmosDbDatabaseName string = 'EventManagement'
param cosmosDbContainerName string = 'Events'
param managedIdentityName string = 'eventapp-identity'

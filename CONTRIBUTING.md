# Contributing to Event Management App

Thank you for considering contributing to this project! Here are some guidelines to help you get started.

## Development Setup

1. Fork and clone the repository
2. Set up the development environment:
   - Install Azure CLI
   - Install kubectl
   - Install PowerShell Core (7+)
   - Set up an Azure subscription

## Making Changes

1. Create a new branch for your changes: `git checkout -b feature/your-feature-name`
2. Make your changes
3. Ensure all code meets the following standards:
   - No hardcoded credentials or secrets
   - Proper error handling
   - Comprehensive comments
   - Parameterized resources

## Testing Changes

Before submitting a pull request:

1. Test your changes with the deploy-full.ps1 script
2. Ensure the application works end-to-end
3. Clean up any test resources after validation

## Submitting Changes

1. Push your changes to your fork
2. Submit a pull request with a clear description of the changes and their purpose
3. Ensure your PR includes any necessary documentation updates

## Deployment YAML Files

When updating deployment YAML files:
1. Never commit files with hardcoded values like IPs or credentials
2. Update templates instead of committing environment-specific files
3. Make sure all changes work with the automated deployment script

## Bicep Templates

When modifying Bicep templates:
1. Ensure all parameters have descriptions
2. Use parameterization for environment-specific values
3. Test your changes before submitting a PR

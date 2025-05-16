I would like to build a sample event management app with CRUD apis. Use React JS with Flask APIs to build the app. Keep the app simple with just one screen to add / modify and delete event . Use Cosmosdb as backend. Make all the calls as API calls with good API schema.

I would later want to deploy the same app in different backend infra like Azure functions, Contaner Instances or AKS, AppService. Soo keep the deployment separate from the infra.

Have separate folder for infra code and separate template files for deploying them in ACI, AppService, AKS, Azure functions

Use Managed identity to authenticate with CososmDB and endpoint will be read from environment variable
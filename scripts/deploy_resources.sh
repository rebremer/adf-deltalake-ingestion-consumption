#
# 0. Params
RG="<<your resource group>>"
ADF="<<your adf>>"
STOR="<<your storage>>"
SQLSERVER="<<your storage>>"
SUBSCRIPTIONID="<<your subscription>>"
LOC="uksouth"
BACPACFILE="blog_adfdeltalake_db.bacpac"
SQLLOGIN="blogadfdeltalakesqluser"
SQLDATABASE="blogadfdeltalakedb3"
SQLSERVICEOBJECTIVE="S0"
#
# 1. init
az upgrade
az login
az account set --subscription $SUBSCRIPTIONID
cd scripts
#
# 2. Resource group
az group create -n $RG -l $LOC
#
# 3. Storage account
az storage account create -g $RG -n $STOR --enable-hierarchical-namespace true
az storage container create -n "bacpac" --account-name $STOR
az storage container create -n "deltamovie" --account-name $STOR
az storage container create -n "copydata" --account-name $STOR
az storage blob upload -f "$BACPACFILE" -c "bacpac" -n $BACPACFILE --account-name $STOR
#
# 4. SQL
# In production, create SQL server without local users and use Azure AD access only
sqlpassword=$(tr -dc 'A-Za-z0-9!' </dev/urandom | head -c 20  ; echo)
az sql server create -l $LOC -g $RG -n $SQLSERVER -u $SQLLOGIN -p $sqlpassword
# In production, only grant access to private endpoints of ADF managed VNET, VPN/IP of workspace to troubleshoot
az sql server firewall-rule create -g $RG -s $SQLSERVER -n myrule --start-ip-address 0.0.0.0 --end-ip-address 255.255.255.255
az sql db create -g $RG -s $SQLSERVER -n $SQLDATABASE --service-objective $SQLSERVICEOBJECTIVE
# In production, use separate storage account to upload bacpac with access keys. Disable access keys for storage account that serves your delta lake
storageKey=$(az storage account keys list -g $RG -n $STOR --query "[0].value" -o tsv)
az sql db import -g $RG -s $SQLSERVER -n $SQLDATABASE -u $SQLLOGIN -p $sqlpassword --storage-key-type StorageAccessKey --storage-key $storageKey --storage-uri https://$STOR.blob.core.windows.net/bacpac/$BACPACFILE
#
# 5. ADF
az datafactory create -n $ADF -g $RG
az deployment group create --resource-group $RG --template-file ../blog-adfdeltalake-adf/ARMTemplateForFactory.json --parameters factoryName=$ADF BlobStorageDelta_properties_typeProperties_serviceEndpoint="https://$STOR.blob.core.windows.net" default_properties_sqlserver_value="$SQLSERVER.database.windows.net" default_properties_sqldatabase_value=$SQLDATABASE default_properties_stor_value=$STOR
# 
# 6. Grant access ADF managed identity
api_response=$(az datafactory show -n $ADF -g $RG)
adfv2_id=$(jq .identity.principalId -r <<< "$api_response")
# In production, don't make ADF MI admin of your database. Instead, grant ADF MI rights on need to know bases (e.g read to tables, write to tables)
az sql server ad-admin create -u $ADF -i $adfv2_id -g $RG -s $SQLSERVER
scope="/subscriptions/$SUBSCRIPTIONID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$STOR"
az role assignment create --assignee-object-id $adfv2_id --role "Storage Blob Data Contributor" --scope $scope
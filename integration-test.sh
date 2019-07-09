#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

trap 'kill 0' EXIT

BASENAME=$1
RESOURCE_GROUP=$BASENAME
LOCATION=northeurope
export AZURE_STORAGE_ACCOUNT=$BASENAME

uniquestr=$(date +%s)
export IMPORT_CONTAINER=import$uniquestr
export EXPORT_CONTAINER=export$uniquestr

echo '[Integration test] creating resource group'
echo "[Integration test] . name: $RESOURCE_GROUP"
echo "[Integration test] . location: $LOCATION"

az group create -n $RESOURCE_GROUP -l $LOCATION -o none

echo '[Integration test] creating storage account'
echo "[Integration test] . name: $AZURE_STORAGE_ACCOUNT"

az storage account create -n $AZURE_STORAGE_ACCOUNT -g $RESOURCE_GROUP --sku Standard_LRS -o none 
echo '[Integration test] enabling soft delete'
az storage blob service-properties delete-policy update --enable true --days-retained 7 --account-name $AZURE_STORAGE_ACCOUNT -o none
export AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string --name $AZURE_STORAGE_ACCOUNT -g $RESOURCE_GROUP -o tsv)
echo '[Integration test] creating containers'
az storage container create --connection-string $AZURE_STORAGE_CONNECTION_STRING --name "$IMPORT_CONTAINER" -o none
az storage container create --connection-string $AZURE_STORAGE_CONNECTION_STRING --name "$EXPORT_CONTAINER" -o none

export IMPORT_FOLDER=$(mktemp -d)
export EXPORT_FOLDER=$(mktemp -d)

echo "[Integration test] Running"
./run-utility.sh &
utility_pid=$!


##### EXPORT TESTS ####

echo "[Integration test] Uploading export blobs"
az storage blob upload --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --file /dev/null --name "blob_created1$uniquestr" -o none
az storage blob upload --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --file /dev/null --name "blob_created2$uniquestr" -o none

sleep 10
echo "[Integration test] Asserting files were copied"
test -f "$EXPORT_FOLDER/blob_created1$uniquestr"
test -f "$EXPORT_FOLDER/blob_created2$uniquestr"

echo "[Integration test] Deleting local export"
rm "$EXPORT_FOLDER/blob_created1$uniquestr"

sleep 5
echo "[Integration test] Asserting export files"
test ! -f "$EXPORT_FOLDER/blob_created1$uniquestr"
test -f "$EXPORT_FOLDER/blob_created2$uniquestr"
echo "[Integration test] Asserting export blobs"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --name "blob_created1$uniquestr" -o none 2>/dev/null && exit 1
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --name "blob_created2$uniquestr" -o none
echo "[Integration test] Export tests complete"

##### IMPORT TESTS ####

echo "[Integration test] Content" > $IMPORT_FOLDER/file_created1$uniquestr
echo "[Integration test] Content" > $IMPORT_FOLDER/file_created2$uniquestr
tail -f /dev/null > $IMPORT_FOLDER/file_being_written_to$uniquestr &
writing_pid=$!

sleep 10
echo "[Integration test] Asserting files were copied"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_created1$uniquestr" -o none
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_created2$uniquestr" -o none
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_being_written_to$uniquestr" -o none 2>/dev/null && exit 1

echo "[Integration test] Asserting files were retained"
test -f "$IMPORT_FOLDER/file_created1$uniquestr"
test -f "$IMPORT_FOLDER/file_created2$uniquestr"
test -f "$IMPORT_FOLDER/file_being_written_to$uniquestr"

echo "[Integration test] Deleting one file in blob container"
az storage blob delete --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_created1$uniquestr" -o none
sleep 5

echo "[Integration test] Asserting one file was deleted locally"
test ! -f "$IMPORT_FOLDER/file_created1$uniquestr"

echo "[Integration test] Asserting other files were retained locally"
test -f "$IMPORT_FOLDER/file_created2$uniquestr"
test -f "$IMPORT_FOLDER/file_being_written_to$uniquestr"

echo "[Integration test] Asserting files were not copied again"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_created1$uniquestr" -o none 2>/dev/null && exit 1
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_created2$uniquestr" -o none
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_being_written_to$uniquestr" -o none 2>/dev/null && exit 1

echo "[Integration test] Releasing file being written to"
kill $writing_pid
wait $writing_pid || true
sleep 5
echo "[Integration test] Asserting file was copied"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "file_being_written_to$uniquestr" -o none
echo "[Integration test] Terminating utility"
kill $utility_pid
wait $utility_pid || true
echo "[Integration test] Integration tests successful"

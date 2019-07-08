#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

trap 'kill 0' EXIT

BASENAME=$1
RESOURCE_GROUP=$BASENAME
LOCATION=northeurope
export AZURE_STORAGE_ACCOUNT=$BASENAME

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
echo '[Integration test] creating container'
az storage container create --connection-string $AZURE_STORAGE_CONNECTION_STRING --name import -o none

export IMPORT_FOLDER=$(mktemp -d)
export EXPORT_FOLDER=$(mktemp -d)

prefix=$(date +%s)
echo "[Integration test] Content" > $IMPORT_FOLDER/file_created1$prefix
echo "[Integration test] Content" > $IMPORT_FOLDER/file_created2$prefix
tail -f /dev/null > $IMPORT_FOLDER/file_being_written_to$prefix &
writing_pid=$!

echo "[Integration test] Running"
./run-utility.sh &
utility_pid=$!

sleep 10
echo "[Integration test] Asserting files were copied"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_created1$prefix" -o none
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_created2$prefix" -o none
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_being_written_to$prefix" -o none 2>/dev/null && exit 1

echo "[Integration test] Asserting files were retained"
test -f "$IMPORT_FOLDER/file_created1$prefix"
test -f "$IMPORT_FOLDER/file_created2$prefix"
test -f "$IMPORT_FOLDER/file_being_written_to$prefix"

echo "[Integration test] Deleting one file in blob container"
az storage blob delete --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_created1$prefix" -o none
sleep 5

echo "[Integration test] Asserting one file was deleted locally"
test ! -f "$IMPORT_FOLDER/file_created1$prefix"

echo "[Integration test] Asserting other files were retained locally"
test -f "$IMPORT_FOLDER/file_created2$prefix"
test -f "$IMPORT_FOLDER/file_being_written_to$prefix"

echo "[Integration test] Asserting files was not copied again"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_created1$prefix" -o none 2>/dev/null && exit 1
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_created2$prefix" -o none
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_being_written_to$prefix" -o none 2>/dev/null && exit 1

echo "[Integration test] Releasing file being written to"
kill $writing_pid
wait $writing_pid || true
sleep 5
echo "[Integration test] Asserting file was copied"
az storage blob show --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "file_being_written_to$prefix" -o none
echo "[Integration test] Terminating utility"
kill $utility_pid
wait $utility_pid || true
echo "[Integration test] Integration tests successful"

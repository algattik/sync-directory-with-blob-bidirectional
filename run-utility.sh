#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

list_blobs() {
	marker=""
	resultsPerPage=30
	blobList=$(mktemp)
	azStdErr=$(mktemp)
	echo "[Utility] Querying export container" >&2
	while true; do
 		az storage blob list --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --num-results $resultsPerPage --marker "$marker" "$@" >>$blobList 2>$azStdErr
		if grep error $azStdErr; then cat $azStdErr >&2; exit 98; fi
 		marker=$((grep -A1 -x 'WARNING: Next Marker:' "$azStdErr" || true) | sed '2q;d' | cut -f2 -d ' '); test -n "$marker" || break
 		echo "[Utility] Querying next page of results..." >&2
 	done
	rm $azStdErr
	echo $blobList
}
	
export_process() {
	blobList=$(list_blobs --container "$EXPORT_CONTAINER" --include m --query '[].[name,metadata.syncertag]' -o tsv)
	
	local IFS=$'\n'
	for lin in $(cat $blobList); do
		f=$(cut -f1 <<< "$lin")
		tag=$(cut -f2 <<< "$lin")
		if test -e "$EXPORT_FOLDER/$f"; then continue; fi
		if [ "$tag" != "1" ]  ; then
			# new blob
			echo "[Utility] Downloading $f" >&2
			az storage blob download --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --name "$f" --file "$EXPORT_FOLDER/$f" -o none
			az storage blob metadata update --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --name "$f" --metadata "syncertag=1" -o none
		else
			# blob to be deleted
			echo "[Utility] Deleting $f" >&2
			az storage blob delete --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$EXPORT_CONTAINER" --name "$f" -o none
		fi
	done

	rm $blobList
}

echo "[Utility] Testing that sudo works" >&2
if ! sudo -nv; then
	echo "[Utility] FATAL: sudo is required" >&2
	exit 1
fi

is_file_being_written() {
	sudo find /proc/ -mindepth 3 -maxdepth 3 -path '*/fd/*' | (xargs -s 10000 sudo stat --format '%A!%N' 2>/dev/null || true) | grep -q "w.*!.* -> '$1'"
	return $?
}

import_process() {
	for filename in $IMPORT_FOLDER/* ; do
		[ -f "$filename" ] || continue
		basename=$(basename "$filename")
		delete_status=$(az storage blob list --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container "$IMPORT_CONTAINER" --prefix "$basename" --num-results '*' --include d | jq ".[] | select (.name==\"$basename\").deleted")
		echo "[Utility] ($basename) -> ($delete_status)" >&2

		case "delete_status_$delete_status" in
        		delete_status_) #new file
            			if ! is_file_being_written "$filename"; then
					echo "[Utility] Uploading $basename" >&2
					az storage blob upload --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name "$IMPORT_CONTAINER" --name "$basename" --file "$filename" -o none
				else
					echo "[Utility] Ignoring $basename, concurrent process is writing" >&2
				fi
            		;;
        		delete_status_true) #deleted blob
				echo "[Utility] Deleting local file $basename" >&2
				rm "$filename"
            		;;
        		delete_status_false) #already copied file
				echo "[Utility] Ignoring already copied file $basename" >&2
            		;;
        		*) #unexpected jq output
				echo "[Utility] Unexpected jq output: $delete_status" >&2
				exit 99
            		;;
		esac
	done
}

while true; do
	export_process
	import_process
done


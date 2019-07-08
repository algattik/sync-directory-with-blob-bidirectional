#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

if ! sudo -v; then
	echo "sudo is required"
	exit 1
fi

is_file_being_written() {
	(
		set +o pipefail
		sudo find /proc/ -mindepth 3 -maxdepth 3 -path '*/fd/*' | xargs -s 10000 sudo stat --format '%A!%N' 2>/dev/null | grep -q "w.*!.* -> '$1'"
	)
	return $?
}

while true; do
	for filename in $IMPORT_FOLDER/* ; do
		[ -f "$filename" ] || continue
		basename=$(basename "$filename")
		delete_status=$(az storage blob list --account-name algattikts --container import --prefix "$basename" --include d | jq ".[] | select (.name==\"$basename\").deleted")
		echo "[Utility] ($basename) -> ($delete_status)"

		case "delete_status_$delete_status" in
        		delete_status_) #new file
            			if ! is_file_being_written "$filename"; then
					echo "[Utility] Uploading $basename"
					az storage blob upload --connection-string "$AZURE_STORAGE_CONNECTION_STRING" --container-name import --name "$basename" --file "$filename" -o none
				else
					echo "[Utility] Ignoring $basename, concurrent process is writing"
				fi
            		;;
        		delete_status_true) #deleted blob
				echo "[Utility] Deleting local file $basename"
				rm "$filename"
            		;;
        		delete_status_false) #already copied file
				echo "[Utility] Ignoring already copied file $basename"
            		;;
        		*) #unexpected jq output
				echo "[Utility] Unexpected jq output: $delete_status" >&2
				exit 99
            		;;
		esac
	done
done


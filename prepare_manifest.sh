#!/bin/bash
# Description: Generates a CSV manifest from an S3 folder. It supports two methods (jq or awk) to
# create the manifest, displays its content, and optionally uploads it to an S3 destination.
#
# Usage: prepare_manifest -b bucket_name -p prefix -r aws_profile [-d s3_destination_uri] [-j jq_filter]
#   -b: S3 bucket name.
#   -p: S3 folder prefix (e.g., "path/to/folder/").
#   -r: AWS profile.
#   -d: (Optional) Destination URI for uploading the generated manifest.
#   -j: (Optional) Custom jq query for manifest generation.
#   -h: Show this help message.
#
# Example:
#   ./prepare_manifest.sh -b mybucket -p "path/to/folder/" -r myprofile -d s3://destination-bucket/manifest/manifest.csv -j '.Contents[] | "\($bucket),\(.Key)"'
#
# New Functionality:
#   • Automatically selects manifest generation method (jq preferred, awk otherwise).
#   • Displays the generated manifest content.
#   • Removes temporary files after execution.
#   • Optionally uploads the manifest to a specified S3 destination.
#
# Steps:
#   1. List objects in S3 and save them to objects.json.
#   2. Generate manifest.csv using the available tool.
#   3. Upload manifest.csv to S3 if a destination is provided.
#   4. Cleanup temporary files.

# ----- Help Option Check -----
if [[ "$1" == "--help" ]]; then
    echo "Usage: $0 -b bucket -p prefix -r aws_profile [-d s3_destination_uri] [-j jq_filter]"
    echo "Example: $0 -b mybucket -p \"path/to/folder/\" -r myprofile -d s3://destination-bucket/manifest/manifest.csv -j '.Contents[] | \"\($bucket),\(.Key)\"'"
    exit 0
fi

DEST_ARG=""  # Default value for DEST
JQ_FILTER="" # Default value for jq filter

# ----- Argument Parsing -----
while getopts "b:p:r:d:j:h" opt; do
    case $opt in
        b) BUCKET="$OPTARG" ;;
        p) PREFIX="$OPTARG" ;;
        r) PROFILE="$OPTARG" ;;
        d) DEST_ARG="$OPTARG" ;;
        j) JQ_FILTER="$OPTARG" ;;  # New argument for custom jq filter
        h)
           echo "Usage: $0 -b bucket -p prefix -r aws_profile [-d s3_destination_uri] [-j jq_filter]"
           echo "Example: $0 -b mybucket -p \"path/to/folder/\" -r myprofile -d s3://destination-bucket/manifest/manifest.csv -j '.Contents[] | \"\($bucket),\(.Key)\"'"
           exit 0
           ;;
        *) echo "Usage: $0 -b bucket -p prefix -r aws_profile [-d s3_destination_uri] [-j jq_filter]"; exit 1 ;;
    esac
done

if [ -z "$BUCKET" ] || [ -z "$PREFIX" ] || [ -z "$PROFILE" ]; then
    echo "Error: The parameters -b, -p, and -r are required." >&2
    exit 1
fi

# Validate DEST_ARG URI if provided
if [ -n "$DEST_ARG" ]; then
    if [[ ! "$DEST_ARG" =~ ^s3:// ]]; then
         echo "Error: Destination URI must start with s3://"
         exit 1
    fi
fi

# ----- List S3 Objects -----
echo "Listing objects in s3://$BUCKET/$PREFIX"
aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "$PREFIX" \
    --output json \
    --profile "$PROFILE" > objects.json
if [ $? -ne 0 ]; then
    echo "Error listing objects." >&2
    exit 1
fi

# ----- Generate manifest.csv -----
if command -v jq &> /dev/null; then
    echo "Generating manifest.csv using jq..."
    if [ -n "$JQ_FILTER" ]; then
        jq -r --arg bucket "$BUCKET" "$JQ_FILTER" objects.json > manifest.csv
    else
        jq -r --arg bucket "$BUCKET" '.Contents[] | "\($bucket),\(.Key)"' objects.json > manifest.csv
    fi
else
    echo "Error: jq is not installed. Aborting."
    exit 1
fi

echo "Content of manifest.csv:"
cat manifest.csv

# ----- Upload manifest.csv to S3 -----
if [ -n "$DEST_ARG" ]; then
    DEST="$DEST_ARG"
    echo "Uploading manifest.csv to $DEST"
    aws s3 cp manifest.csv "$DEST" --profile "$PROFILE"
    if [ $? -ne 0 ]; then
        echo "Error uploading manifest.csv." >&2
        exit 1
    fi
    echo "Manifest uploaded successfully."
else
    echo "DEST not provided. Skipping manifest upload."
fi

# ----- Cleanup -----
rm objects.json
echo "Script completed."
exit 0

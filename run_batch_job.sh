#!/bin/bash
# Description: Automates the process to prepare and start an S3 Batch Operations job.
# Usage: run_batch_job.sh [-h] -U manifest_uri [-g region] [-r role_name] [-y policy_name] [-l lambda_function] -p profile [-c yes|no] [-P report_prefix]
# Example: ./run_batch_job.sh -U s3://jlhc-hf-eolus/tests/manifest.csv -g eu-west-3 -r batch-lambda-role -y batch-lambda-policy -l process_lambda -p setup -c no -P custom_prefix


# ----- Setup logging ----------------------------------------------------------------------------------
LOG_FILE="run_batch_job.log"
rm -f "$LOG_FILE"
run_aws() {
    echo "Running: aws $*" >> "$LOG_FILE"       # Log the command
    output=$(aws "$@" 2>&1)
    echo "$output" >> "$LOG_FILE"              # Log command output
    echo "$output"
}

# Updated default values
MANIFEST_URI=""      # Full URI of the manifest (e.g., s3://bucket/path/manifest.csv)
REGION="eu-west-3"
ROLE_NAME="batch-lambda-role"
POLICY_NAME="batch-lambda-policy"
LAMBDA_FUNCTION="process_lambda"
PROFILE=""  # No default value; must be provided
CONFIRM_FLAG="yes"  # 'yes' for --confirmation-required, 'no' for --no-confirmation-required
REPORT_PREFIX=""  # Optional prefix for reports

while getopts "hU:g:r:y:l:p:c:P:" opt; do
  case "$opt" in
    h)
      echo "Usage: $0 [-h] -U manifest_uri [-g region] [-r role_name] [-y policy_name] [-l lambda_function] -p profile [-c yes|no] [-P report_prefix]"
      exit 0
      ;;
    U) MANIFEST_URI="$OPTARG" ;;
    g) REGION="$OPTARG" ;;
    r) ROLE_NAME="$OPTARG" ;;
    y) POLICY_NAME="$OPTARG" ;;
    l) LAMBDA_FUNCTION="$OPTARG" ;;
    p) PROFILE="$OPTARG" ;;
    c) CONFIRM_FLAG="$OPTARG" ;;
    P) REPORT_PREFIX="$OPTARG" ;;
    *) exit 1 ;;
  esac
done

# Check that MANIFEST_URI is provided and its format is correct
if [ -z "$MANIFEST_URI" ]; then
  echo "Error: The manifest URI must be provided with -U." >&2
  exit 1
fi
if [[ "$MANIFEST_URI" != s3://* ]]; then
  echo "Error: The manifest URI must start with 's3://'." >&2
  exit 1
fi

# Check that PROFILE is provided
if [ -z "$PROFILE" ]; then
  echo "Error: The profile must be provided with -p." >&2
  exit 1
fi

# Extract BUCKET and MANIFEST_KEY from the URI
BUCKET=$(echo "$MANIFEST_URI" | cut -d'/' -f3)
MANIFEST_KEY=$(echo "$MANIFEST_URI" | cut -d'/' -f4-)
if [ -z "$BUCKET" ] || [ -z "$MANIFEST_KEY" ]; then
  echo "Error: The manifest URI is not in the correct format (s3://bucket/key)." >&2
  exit 1
fi

# Calculate the report prefix if none was provided (-P)
if [ -z "$REPORT_PREFIX" ]; then
    REPORT_PREFIX="${MANIFEST_KEY%/*}"
    if [ "$REPORT_PREFIX" = "$MANIFEST_KEY" ]; then
      REPORT_PREFIX=""
    fi
fi
echo "Using report prefix: $REPORT_PREFIX"

echo "Using manifest: $MANIFEST_URI"
echo "Extracted bucket: $BUCKET, key: $MANIFEST_KEY"

# Fixed variables
# Retrieve the dynamic account id
ACCOUNT_ID=$(run_aws sts get-caller-identity --query "Account" --output text --profile "$PROFILE")
# Manifest object in S3
MANIFEST_ARN="arn:aws:s3:::$BUCKET/$MANIFEST_KEY"

echo "Retrieving ETag of the manifest: s3://$BUCKET/$MANIFEST_KEY ..."
ETAG=$(run_aws s3api head-object --bucket "$BUCKET" --key "$MANIFEST_KEY" --profile "$PROFILE" | jq -r '.ETag')
if [ -z "$ETAG" ] || [ "$ETAG" == "null" ]; then
  echo "Error: Failed to retrieve the ETag." >&2
  exit 1
fi
# Remove quotes if present
ETAG=${ETAG//\"/}
echo "ETag retrieved: $ETAG"

# ----- Create the policy file (batch-policy.json) -----
cat > batch-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VisualEditor0",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObjectAcl",
        "s3:GetObject",
        "lambda:InvokeFunction",
        "s3:RestoreObject",
        "s3:GetObjectTagging",
        "s3:ListBucket",
        "s3:PutObjectTagging",
        "s3:PutObjectAcl",
        "s3:GetObjectVersion"
      ],
      "Resource": [
        "arn:aws:s3:::$BUCKET/*",
        "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_FUNCTION:\$LATEST"
      ]
    }
  ]
}
EOF

# ----- Create the IAM policy (salta la creación si ya existe) -----
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"


  echo "Creating policy $POLICY_NAME ..."
  run_aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file://batch-policy.json \
    --profile "$PROFILE"


# ----- Create the trust document for the role (batch-trust-policy.json) -----
cat > batch-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "batchoperations.s3.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# ----- Create the batch operations role if it does not exist -----

    echo "Creating role $ROLE_NAME ..."
    run_aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file://batch-trust-policy.json \
      --profile "$PROFILE"
    sleep 10  # Allow propagation time


# Wait until the role is fully propagated
echo "Waiting for role propagation..."
for i in {1..10}; do
  if run_aws iam get-role --role-name "$ROLE_NAME" --profile "$PROFILE" >/dev/null 2>&1; then
    echo "Role $ROLE_NAME is available."
    break
  else
    echo "Role $ROLE_NAME not yet available, waiting..."
    sleep 5
  fi
done

# ----- Attach the policy to the role -----
echo "Attaching policy $POLICY_NAME to role $ROLE_NAME ..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"
run_aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" \
  --profile "$PROFILE" || true

# Evaluate the value of CONFIRM_FLAG to define CONFIRMATION_ARG
if [ "$CONFIRM_FLAG" = "no" ]; then
  CONFIRMATION_ARG="--no-confirmation-required"
else
  CONFIRMATION_ARG="--confirmation-required"
fi

# ----- Create the S3 Batch Operations job -----
echo "Creating the S3 Batch Operations job..."
# Determine confirmation requirement for JSON
if [ "$CONFIRM_FLAG" = "no" ]; then
  CONFIRM_REQUIRED_JSON=false
else
  CONFIRM_REQUIRED_JSON=true
fi
# Build job.json for AWS CLI
cat > job.json <<EOF
{
  "AccountId": "$ACCOUNT_ID",
  "Operation": {
    "LambdaInvoke": {
      "FunctionArn": "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_FUNCTION:\$LATEST"
    }
  },
  "Manifest": {
    "Spec": {
      "Format": "S3BatchOperations_CSV_20180820",
      "Fields": ["Bucket","Key"]
    },
    "Location": {
      "ObjectArn": "$MANIFEST_ARN",
      "ETag": "$ETAG"
    }
  },
  "Priority": 10,
  "RoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME",
  "Report": {
    "Bucket": "arn:aws:s3:::$BUCKET",
    "Prefix": "$REPORT_PREFIX",
    "Format": "Report_CSV_20180820",
    "Enabled": true,
    "ReportScope": "AllTasks"
  },
  "Description": "Running S3 Batch Operations job on manifest.csv",
  "ConfirmationRequired": $CONFIRM_REQUIRED_JSON,
  "AbortConfig": {
    "MinNumberOfTasks": 1,
    "FailurePercentage": 100
  }
}
EOF

JOB_OUTPUT=$(run_aws s3control create-job --cli-input-json file://job.json --profile "$PROFILE")

JOB_ID=$(echo "$JOB_OUTPUT" | jq -r '.JobId')
echo "Job created. JobId: $JOB_ID"

# Cleanup generated job.json
rm job.json

# ----- Cleanup temporary files -----
rm batch-policy.json batch-trust-policy.json

echo "Script completed."

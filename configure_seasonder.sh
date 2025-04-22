#!/bin/bash
# ----------------------------------------------------------------------------
# Script: configure_seasonder.sh
# Description: This script automates the deployment and configuration of a Docker-based
#   AWS Lambda function. It performs the following operations:
#     1. Logs all AWS CLI commands executed to a log file for troubleshooting.
#     2. Validates and processes input parameters such as AWS profile, ECR repository name,
#        Lambda function name, IAM role & policy names, S3 URIs, and Docker image settings.
#     3. Creates temporary JSON documents for the IAM trust policy and Lambda execution policy.
#     4. Checks if the specified IAM role exists; if not, it creates the role and updates its trust policy.
#     5. Checks if the IAM policy exists; if not, it creates the policy and attaches it to the role.
#     6. Verifies the existence of the specified ECR repository; if it does not exist, it creates one.
#     7. Logs into the ECR repository, builds, tags, and pushes a Docker image to it.
#     8. Creates or updates the Lambda function to use the newly pushed Docker image.
#     9. Updates the Lambda function configuration with environment variables that reflect the
#        runtime options, ensuring that all mandatory S3 URIs and parameters are set correctly.
#    10. Optionally tests the Lambda function invocation if a test S3 key is provided.
#
# Requirements:
#   - AWS CLI, Docker, and jq must be installed and properly configured.
#   - Valid AWS credentials with permissions to create and update IAM roles, policies, ECR repositories,
#     and Lambda functions.
#
# Usage: configure_seasonder.sh [-h] [-o key=value] [-A aws_profile] [-E ecr_repo] [-L lambda_function] [-R role_name] [-P policy_name] [-T pattern_path] [-S s3_output_path] [-K test_s3_key] [-g region] [-t timeout] [-m memory_size] [-u S3_RESOURCE_ARN]
#   -h: Show this help message.
#   -o: Override OPTIONS with key=value pairs (can be specified multiple times).
#   -A: AWS profile (default: your_aws_profile).
#   -E: ECR repository name (default: my-lambda-docker).
#   -L: Lambda function name (default: process_lambda).
#   -R: IAM role name (default: process-lambda-role).
#   -P: IAM policy name (default: lambda-s3-logs).
#   -T: S3 pattern path (must start with s3://).
#   -S: S3 output path (must start with s3://).
#   -K: S3 key for testing (optional).
#   -g: AWS region (default: eu-west-3).
#   -t: Lambda function timeout in seconds (default: 100).
#   -m: Lambda function memory size in MB (default: 2048).
#   -u: S3 resource ARN (must start with arn:aws:s3:::).
#
# Parameter Details:
#   -u: S3 resource ARN where the Lambda function is granted permission for s3:PutObject and
#       s3:GetObject operations, enabling read and write file operations.
#   -K: S3 URI to a spectral file used to test the Lambda function.
#   -S: S3 URI to a directory where the results will be saved. Within this directory, folders
#       named "Radial_Metrics" (for .ruv files) and "CS_Objects" (for .RData files containing the
#       processed SeaSondeRCS objects) will be created.
#   -T: S3 URI to an antenna pattern file that is used for processing the spectra.
# Detailed Steps:
#   1. Log and process input parameters along with runtime override options.
#   2. Validate the provided S3 URIs and the S3_RESOURCE_ARN for proper format.
#   3. Create temporary JSON files for the necessary IAM role and policy configurations.
#   4. Either create or update AWS resources (IAM role, policy, ECR repository, Lambda function)
#      based on the existence checks.
#   5. Build and push the Docker image to the Amazon ECR repository.
#   6. Update the Lambda configuration with pertinent environment variables.
#   7. Optionally invoke the Lambda function to verify deployment.
# ----------------------------------------------------------------------------

# ----- Setup logging ===================================================================================
LOG_FILE="configure_seasonder.log"
rm -f "$LOG_FILE"  # Remove any existing log file to start fresh

# Added logging function to capture echo outputs in log
log() {
    echo "$@" | tee -a "$LOG_FILE"
}

# ----- Initialize options array for runtime overrides --------------------------------------------------
user_options=()

# ----- Function Definition: run_aws ---------------------------------------------------------------------
# This function wraps the AWS CLI commands to:
#   1. Log the full command line that is executed.
#   2. Capture both standard output and errors.
#   3. Write the command output to the log file for later debugging.
run_aws() {
    echo "Running: aws $*" >> "$LOG_FILE"  # Log executed command
    output=$(aws "$@" 2>&1)
    echo "$output" >> "$LOG_FILE"          # Log output
    echo "$output"                        # Also display output on the console
}

# Replace OPTIONS array with hard-coded default values (plus missing ENVs)
OPTS_NSM=2
OPTS_FDOWN=10
OPTS_FLIM=100
OPTS_NOISEFACT=3.981072
OPTS_CURRMAX=2
OPTS_REJECT_DISTANT_BRAGG=TRUE
OPTS_REJECT_NOISE_IONOSPHERIC=TRUE
OPTS_REJECT_NOISE_IONOSPHERIC_THRESHOLD=0
OPTS_COMPUTE_FOR=TRUE
OPTS_DOPPLER_INTERPOLATION=2
OPTS_PPMIN=5
OPTS_PWMAX=50
OPTS_SMOOTH_NOISE_LEVEL=TRUE
OPTS_MUSIC_PARAMETERS="40,20,2,20"
OPTS_PATTERN_PATH=""
OPTS_S3_OUTPUT_PATH=""
OPTS_RDATA_OUTPUT=FALSE
OPTS_DISCARD_NO_SOLUTION=TRUE
OPTS_DISCARD_LOW_SNR=TRUE

# Additional parameters
AWS_PROFILE="your_aws_profile"
ECR_REPO="my-lambda-docker"
LAMBDA_FUNCTION="process_lambda"
ROLE_NAME="process-lambda-role"
POLICY_NAME="lambda-s3-logs"
TEST_S3_KEY=""
REGION="eu-west-3" # Default region
TIMEOUT=100       # Default timeout in seconds
MEMORY_SIZE=2048  # Default memory size in MB
S3_RESOURCE_ARN=""  

# ----- Argument Parsing ----------------------------------------------------------------------------------
while getopts "ho:A:E:L:R:P:T:S:K:g:t:m:u:" opt; do
    case $opt in
        h)
            echo "Usage: $0 [-h] [-o key=value] [-A aws_profile] [-E ecr_repo] [-L lambda_function] [-R role_name] [-P policy_name] [-T pattern_path] [-S s3_output_path] [-K test_s3_key] [-g region] [-t timeout] [-m memory_size] [-u S3_RESOURCE_ARN]"
            echo "Defaults for OPTIONS:"
            echo "  SEASONDER_NSM=${OPTS_NSM}"
            echo "  SEASONDER_FDOWN=${OPTS_FDOWN}"
            echo "  SEASONDER_FLIM=${OPTS_FLIM}"
            echo "  SEASONDER_NOISEFACT=${OPTS_NOISEFACT}"
            echo "  SEASONDER_CURRMAX=${OPTS_CURRMAX}"
            echo "  SEASONDER_REJECT_DISTANT_BRAGG=${OPTS_REJECT_DISTANT_BRAGG}"
            echo "  SEASONDER_REJECT_NOISE_IONOSPHERIC=${OPTS_REJECT_NOISE_IONOSPHERIC}"
            echo "  SEASONDER_REJECT_NOISE_IONOSPHERIC_THRESHOLD=${OPTS_REJECT_NOISE_IONOSPHERIC_THRESHOLD}"
            echo "  SEASONDER_COMPUTE_FOR=${OPTS_COMPUTE_FOR}"
            echo "  SEASONDER_DOPPLER_INTERPOLATION=${OPTS_DOPPLER_INTERPOLATION}"
            echo "  SEASONDER_PPMIN=${OPTS_PPMIN}"
            echo "  SEASONDER_PWMAX=${OPTS_PWMAX}"
            echo "  SEASONDER_SMOOTH_NOISE_LEVEL=${OPTS_SMOOTH_NOISE_LEVEL}"
            echo "  SEASONDER_MUSIC_PARAMETERS=${OPTS_MUSIC_PARAMETERS}"
            echo "  SEASONDER_PATTERN_PATH=${OPTS_PATTERN_PATH}"
            echo "  SEASONDER_S3_OUTPUT_PATH=${OPTS_S3_OUTPUT_PATH}"
            echo "  TEST_S3_KEY=${TEST_S3_KEY}"
            echo "  REGION=${REGION}"
            echo "  S3_RESOURCE_ARN=${S3_RESOURCE_ARN}"
            echo "  SEASONDER_RDATA_OUTPUT=${OPTS_RDATA_OUTPUT}"
            echo "  SEASONDER_DISCARD_NO_SOLUTION=${OPTS_DISCARD_NO_SOLUTION}"
            echo "  SEASONDER_DISCARD_LOW_SNR=${OPTS_DISCARD_LOW_SNR}"
            exit 0
            ;;
        o) user_options+=("$OPTARG") ;;       # Collect key=value pairs for runtime overrides
        A) AWS_PROFILE="$OPTARG" ;;           # Override AWS profile if provided
        E) ECR_REPO="$OPTARG" ;;              # Override ECR repository name if provided
        L) LAMBDA_FUNCTION="$OPTARG" ;;       # Override Lambda function name if provided
        R) ROLE_NAME="$OPTARG" ;;             # Override IAM role name if provided
        P) POLICY_NAME="$OPTARG" ;;           # Override IAM policy name if provided
        T) OPTS_PATTERN_PATH="$OPTARG" ;;     # Override S3 pattern path
        S) OPTS_S3_OUTPUT_PATH="$OPTARG" ;;   # Override S3 output path
        K) TEST_S3_KEY="$OPTARG" ;;           # Override test S3 key
        g) REGION="$OPTARG" ;;                # Override AWS region
        t) TIMEOUT="$OPTARG" ;;               # Override Lambda timeout value
        m) MEMORY_SIZE="$OPTARG" ;;           # Override Lambda memory size
        u) S3_RESOURCE_ARN="$OPTARG" ;;       # Override S3 resource ARN
        *) ;;                                # Ignore unrecognized options
    esac
done
shift $((OPTIND - 1))

# Validate S3_RESOURCE_ARN
if [ -z "$S3_RESOURCE_ARN" ]; then
    echo "Error: S3_RESOURCE_ARN must be provided." >&2
    exit 1
fi
if [[ ! "$S3_RESOURCE_ARN" =~ ^arn:aws:s3::: ]]; then
    echo "Error: S3_RESOURCE_ARN is not a valid ARN." >&2
    exit 1
fi

# Process -o flag to allow runtime overrides using the same names as the Dockerfile ENV variables
for kv in "${user_options[@]}"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    case "$key" in
      SEASONDER_NSM) OPTS_NSM="$value" ;;
      SEASONDER_FDOWN) OPTS_FDOWN="$value" ;;
      SEASONDER_FLIM) OPTS_FLIM="$value" ;;
      SEASONDER_NOISEFACT) OPTS_NOISEFACT="$value" ;;
      SEASONDER_CURRMAX) OPTS_CURRMAX="$value" ;;
      SEASONDER_REJECT_DISTANT_BRAGG) OPTS_REJECT_DISTANT_BRAGG="$value" ;;
      SEASONDER_REJECT_NOISE_IONOSPHERIC) OPTS_REJECT_NOISE_IONOSPHERIC="$value" ;;
      SEASONDER_REJECT_NOISE_IONOSPHERIC_THRESHOLD) OPTS_REJECT_NOISE_IONOSPHERIC_THRESHOLD="$value" ;;
      SEASONDER_COMPUTE_FOR) OPTS_COMPUTE_FOR="$value" ;;
      SEASONDER_DOPPLER_INTERPOLATION) OPTS_DOPPLER_INTERPOLATION="$value" ;;
      SEASONDER_PPMIN) OPTS_PPMIN="$value" ;;
      SEASONDER_PWMAX) OPTS_PWMAX="$value" ;;
      SEASONDER_SMOOTH_NOISE_LEVEL) OPTS_SMOOTH_NOISE_LEVEL="$value" ;;
      SEASONDER_MUSIC_PARAMETERS) OPTS_MUSIC_PARAMETERS="$value" ;;
      SEASONDER_PATTERN_PATH) OPTS_PATTERN_PATH="$value" ;;
      SEASONDER_S3_OUTPUT_PATH) OPTS_S3_OUTPUT_PATH="$value" ;;
      SEASONDER_RDATA_OUTPUT) OPTS_RDATA_OUTPUT="$value" ;;
      SEASONDER_DISCARD_LOW_SNR) OPTS_DISCARD_LOW_SNR="$value" ;;
      SEASONDER_DISCARD_NO_SOLUTION) OPTS_DISCARD_NO_SOLUTION="$value" ;;
      *) ;;
    esac
done

# ----- Validate Mandatory S3 Arguments ------------------------------------------------------------------
if [ -z "$OPTS_PATTERN_PATH" ] || [ -z "$OPTS_S3_OUTPUT_PATH" ]; then
    echo "Error: Both SEASONDER_PATTERN_PATH (-T) and SEASONDER_S3_OUTPUT_PATH (-S) must be provided."
    exit 1
fi

# Ensure S3 URIs begin with "s3://"
if [[ "$OPTS_PATTERN_PATH" != s3://* ]]; then
    echo "Error: SEASONDER_PATTERN_PATH must be a valid S3 URI (start with s3://)."
    exit 1
fi
if [[ "$OPTS_S3_OUTPUT_PATH" != s3://* ]]; then
    echo "Error: SEASONDER_S3_OUTPUT_PATH must be a valid S3 URI (start with s3://)."
    exit 1
fi

echo "Using AWS_PROFILE: $AWS_PROFILE"
echo "ECR_REPO: $ECR_REPO"
echo "  reject_noise_ionospheric_threshold=${OPTS_REJECT_NOISE_IONOSPHERIC_THRESHOLD}"
echo "  COMPUTE_FOR=${OPTS_COMPUTE_FOR}"
echo "  doppler_interpolation=${OPTS_DOPPLER_INTERPOLATION}"
echo "  PPMIN=${OPTS_PPMIN}"
echo "  PWMAX=${OPTS_PWMAX}"
echo "  smoothNoiseLevel=${OPTS_SMOOTH_NOISE_LEVEL}"
echo "  MUSIC_parameters=${OPTS_MUSIC_PARAMETERS}"

# ----- Create Temporary JSON Files for IAM Configurations ---------------------------------------------
# The following block creates JSON files used to set up IAM policies and roles.
AWS_ACCOUNT_ID=$(run_aws sts get-caller-identity --query "Account" --output text --profile "$AWS_PROFILE")

cat > lambda-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

cat > lambda.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VisualEditor0",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "logs:CreateLogGroup"
      ],
      "Resource": [
        "${S3_RESOURCE_ARN}",
        "arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:*"
      ]
    },
    {
      "Sid": "LogStreamAndEvents",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/${LAMBDA_FUNCTION}:*"
    }
  ]
}
EOF

# ----- Create or Update the IAM Role ---------------------------------------------------------------------
log "Checking IAM role..."
role_check=$(run_aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_PROFILE" 2>&1)
if echo "$role_check" | grep -q 'NoSuchEntity'; then
    log "IAM role not found. Creating IAM role..."
    run_aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file://lambda-policy.json \
      --profile "$AWS_PROFILE"
    sleep 10  # Allow propagation
else
    log "IAM role already exists."
fi

# ----- Create or Update the IAM Policy ------------------------------------------------------------------
log "Checking IAM policy..."
policy_arn_expected="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/$POLICY_NAME"
policy_check=$(run_aws iam get-policy --policy-arn "$policy_arn_expected" --profile "$AWS_PROFILE" 2>&1)
if echo "$policy_check" | grep -q 'NoSuchEntity'; then
    log "IAM policy not found. Creating IAM policy..."
    POLICY_ARN=$(run_aws iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document file://lambda.json \
      --profile "$AWS_PROFILE" | jq -r '.Policy.Arn')
else
    log "IAM policy already exists."
    POLICY_ARN="$policy_arn_expected"
fi
log "Attaching policy to the role..."
run_aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" \
  --profile "$AWS_PROFILE"

# ----- Create the ECR Repository if It Does Not Exist --------------------------------------------------
log "Checking ECR repository..."
repo_check=$(run_aws ecr describe-repositories --repository-names "$ECR_REPO" --profile "$AWS_PROFILE" 2>&1)
if echo "$repo_check" | grep -q 'RepositoryNotFoundException'; then
    log "ECR repository not found. Creating repository..."
    run_aws ecr create-repository \
      --repository-name "$ECR_REPO" \
      --profile "$AWS_PROFILE"
else
    log "ECR repository already exists."
fi

# ----- Log in to Amazon ECR -----------------------------------------------------------------------------
log "Logging in to ECR..."
PASSWORD=$(run_aws ecr get-login-password --profile "$AWS_PROFILE" --region "$REGION")
# Pipe the ECR login password to Docker to authenticate
echo "$PASSWORD" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ----- Build, Tag, and Push the Docker Image -----------------------------------------------------------
log "Building Docker image..."
docker build -t "$ECR_REPO" .  # Build the Docker image using the Dockerfile in the current directory

log "Tagging Docker image..."
docker tag "$ECR_REPO":latest "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$ECR_REPO:latest"

log "Pushing Docker image..."
docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$ECR_REPO:latest"

# ----- Create or Update the Lambda Function ------------------------------------------------------------
IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$ECR_REPO:latest"
lambda_exists=$(run_aws lambda get-function --function-name "$LAMBDA_FUNCTION" --profile "$AWS_PROFILE")
if echo "$lambda_exists" | grep -q 'ResourceNotFoundException'; then
    log "Creating Lambda function with image URI: $IMAGE_URI"
    run_aws lambda create-function \
        --function-name "$LAMBDA_FUNCTION" \
        --package-type Image \
        --code ImageUri="$IMAGE_URI" \
        --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME" \
        --profile "$AWS_PROFILE"
else
    log "Lambda function $LAMBDA_FUNCTION already exists, updating the image..."
    run_aws lambda update-function-code \
      --function-name "$LAMBDA_FUNCTION" \
      --image-uri "$IMAGE_URI" \
      --profile "$AWS_PROFILE"
fi

# ----- Update Lambda Function Configuration ------------------------------------------------------------
log "Updating Lambda function configuration..."
# Wait until any ongoing update operations have completed before modifying configuration
MAX_WAIT=300
WAITED=0
while true; do
    STATUS=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION" --profile "$AWS_PROFILE" --query "Configuration.LastUpdateStatus" --output text)
    log "Current Lambda status: $STATUS"
    if [ "$STATUS" == "Successful" ]; then
      break
    fi
    
    log "Lambda not available yet ($STATUS). Waiting 10 seconds..."
    sleep 10
    WAITED=$((WAITED+10))
    if [ $WAITED -ge $MAX_WAIT ]; then
        log "Timeout reached while waiting for Lambda function update to finish." >&2
        exit 1
    fi
done

# Retry mechanism for updating the Lambda configuration in case of transient errors
MAX_RETRIES=5
RETRY_COUNT=0
until run_aws lambda update-function-configuration \
  --function-name "$LAMBDA_FUNCTION" \
  --timeout "$TIMEOUT" \
  --memory-size "$MEMORY_SIZE" \
  --environment "{\"Variables\":{
    \"SEASONDER_PATTERN_PATH\":\"$OPTS_PATTERN_PATH\",
    \"SEASONDER_NSM\":\"$OPTS_NSM\",
    \"SEASONDER_FDOWN\":\"$OPTS_FDOWN\",
    \"SEASONDER_FLIM\":\"$OPTS_FLIM\",
    \"SEASONDER_NOISEFACT\":\"$OPTS_NOISEFACT\",
    \"SEASONDER_CURRMAX\":\"$OPTS_CURRMAX\",
    \"SEASONDER_REJECT_DISTANT_BRAGG\":\"$OPTS_REJECT_DISTANT_BRAGG\",
    \"SEASONDER_REJECT_NOISE_IONOSPHERIC\":\"$OPTS_REJECT_NOISE_IONOSPHERIC\",
    \"SEASONDER_REJECT_NOISE_IONOSPHERIC_THRESHOLD\":\"$OPTS_REJECT_NOISE_IONOSPHERIC_THRESHOLD\",
    \"SEASONDER_COMPUTE_FOR\":\"$OPTS_COMPUTE_FOR\",
    \"SEASONDER_DOPPLER_INTERPOLATION\":\"$OPTS_DOPPLER_INTERPOLATION\",
    \"SEASONDER_PPMIN\":\"$OPTS_PPMIN\",
    \"SEASONDER_PWMAX\":\"$OPTS_PWMAX\",
    \"SEASONDER_SMOOTH_NOISE_LEVEL\":\"$OPTS_SMOOTH_NOISE_LEVEL\",
    \"SEASONDER_MUSIC_PARAMETERS\":\"$OPTS_MUSIC_PARAMETERS\",
    \"SEASONDER_DISCARD_LOW_SNR\":\"$OPTS_DISCARD_LOW_SNR\",
    \"SEASONDER_DISCARD_NO_SOLUTION\":\"$OPTS_DISCARD_NO_SOLUTION\",
    \"SEASONDER_RDATA_OUTPUT\":\"$OPTS_RDATA_OUTPUT\",
    \"SEASONDER_S3_OUTPUT_PATH\":\"$OPTS_S3_OUTPUT_PATH\"
  }}" \
  --profile "$AWS_PROFILE"; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
      log "Maximum retries reached. Failed to update Lambda function configuration."
      exit 1
    fi
    log "Configuration update in progress. Retry $RETRY_COUNT/$MAX_RETRIES. Waiting 10 seconds..."
    sleep 10
done

# Wait until any ongoing update operations have completed before continuying
MAX_WAIT=300
WAITED=0
while true; do
    STATUS=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION" --profile "$AWS_PROFILE" --query "Configuration.LastUpdateStatus" --output text)
    log "Current Lambda status: $STATUS"
    if [ "$STATUS" == "Successful" ]; then
      break
    fi
    
    log "Lambda not available yet ($STATUS). Waiting 10 seconds..."
    sleep 10
    WAITED=$((WAITED+10))
    if [ $WAITED -ge $MAX_WAIT ]; then
        log "Timeout reached while waiting for Lambda function update to finish." >&2
        exit 1
    fi
done

# ----- Optionally Invoke the Lambda Function for Testing ----------------------------------------------
if [ -n "$TEST_S3_KEY" ]; then
    # Parse the S3 bucket name and key from the provided TEST_S3_KEY
    BUCKET_NAME=$(echo "$TEST_S3_KEY" | awk -F'/' '{print $3}')
    KEY_PATH=$(echo "$TEST_S3_KEY" | cut -d'/' -f4-)
    log "Invoking Lambda function for testing..."
    run_aws lambda invoke \
      --function-name "$LAMBDA_FUNCTION" \
      --payload "{\"invocationSchemaVersion\": \"1.0\", \"invocationId\": \"YXNkbGZqYWRmaiBhc2RmdW9hZHNmZGpmaGFzbGtkaGZza2RmaAo\", \"job\": {\"id\": \"f3cc4f60-61f6-4a2b-8a21-d07600c373ce\"}, \"tasks\": [{\"taskId\": \"dGFza2lkZ29lc2hlcmUF\", \"s3BucketArn\": \"arn:aws:s3:::${BUCKET_NAME}\", \"s3Key\": \"${KEY_PATH}\", \"s3VersionId\": \"1\"}]}" \
      response.json \
      --cli-binary-format raw-in-base64-out \
      --profile "$AWS_PROFILE"

    if [ -f response.json ]; then
        result=$(jq -r '.results[0].resultCode' response.json)
        if [ "$result" = "Succeeded" ]; then
          log "Lambda invocation succeeded: Succeeded"
          metrics_path=$(jq -r '.results[0].resultString | fromjson | .Radial_Metrics_path' response.json)
          filename=$(basename "$metrics_path")
          run_aws s3 cp "$metrics_path" "./$filename" --profile "$AWS_PROFILE"
          if [[ "$filename" == *.gz ]]; then
                gunzip -c "$filename" > "${filename%.gz}"
                log "First 50 lines of decompressed file:"
                head -n 50 "${filename%.gz}" | tee -a "$LOG_FILE"
                log "Last 90 lines of decompressed file:"
                tail -n 90 "${filename%.gz}" | tee -a "$LOG_FILE"
          else
                log "First 50 lines:"
                head -n 50 "$filename" | tee -a "$LOG_FILE"
                log "Last 90 lines:"
                tail -n 90 "$filename" | tee -a "$LOG_FILE"
          fi
        else
          log "Lambda invocation failed: $result"
        fi
    else
        log "response.json file not found."
    fi
fi

log "Script completed. Check response.json for the invocation result."

# ----- Clean Up Temporary Files --------------------------------------------------------------------------
rm lambda-policy.json lambda.json
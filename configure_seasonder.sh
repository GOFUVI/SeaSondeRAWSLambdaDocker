#!/bin/bash
# filepath: /home/vant/Documentos/SeaSondeRAWSLambdaDocker/configure_seasonder.sh
# ----------------------------------------------------------------------------
# Script: configure_seasonder.sh
# Description: Executes the steps outlined in the README:
#   - Creates an IAM role and policy from temporary JSON files.
#   - Creates an ECR repository, logs in, builds, tags, and pushes the Docker image.
#   - Creates a Lambda function using the created image.
#   - Invokes the Lambda function for testing.
#
# Usage: configure_seasonder.sh [-h] [-o key=value] [-A aws_profile] [-E ecr_repo] [-L lambda_function] [-R role_name] [-P policy_name] [-T pattern_path] [-S s3_output_path] [-K test_s3_key] [-g region] [-t timeout] [-m memory_size] [-u S3_RESOURCE_ARN]
#   -h: Show this help message.
#   -o: Override OPTIONS key with key=value (can be used multiple times).
#   -A: AWS profile (default: your_aws_profile).
#   -E: ECR repository name (default: my-lambda-docker).
#   -L: Lambda function name (default: process_lambda).
#   -R: IAM role name (default: process-lambda-role).
#   -P: Policy name (default: lambda-s3-logs).
#   -T: Pattern path (default: empty).
#   -S: S3 output path (default: empty).
#   -K: S3 key for testing (default: empty).
#   -g: AWS region (default: eu-west-3).
#   -t: Timeout for Lambda function (default: 100 seconds).
#   -m: Memory size for Lambda function (default: 2048 MB).
#   -u: S3 resource ARN (default: arn:aws:s3:::my-s3-bucket/*).
#
# Example:
#   ./configure_seasonder.sh -o nsm=3 -A my_aws_profile -E my_repo -L my_lambda -R my_role -P my_policy -T s3://my-pattern-path -S my-s3-output-path -K my-test-s3-key -g us-east-1 -t 120 -m 1024 -u arn:aws:s3:::my-custom-bucket/*
# ----------------------------------------------------------------------------

user_options=()
LOGFILE="/Users/jherrera/Desktop/SeaSondeRAWSLambdaDocker/aws_commands.log"
echo "" > "$LOGFILE"  # Sobreescribe el fichero de logs en cada ejecución

# Añadir función para loggear los comandos aws ejecutados
run_aws() {
    echo "Executing: aws $*" >> "$LOGFILE" 2>&1
    aws "$@"
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
OPTS_DISCARD="no_solution,low_SNR"
OPTS_PATTERN_PATH=""
OPTS_S3_OUTPUT_PATH=""

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
S3_RESOURCE_ARN="arn:aws:s3:::jlhc-hf-eolus/*"  # new parameter S3_RESOURCE_ARN

# Extended argument parsing (include -T, -S, -K, -g, -t, -m and new -u for S3_RESOURCE_ARN)
while getopts "ho:A:E:L:R:P:T:S:K:g:t:m:u:" opt; do
    case $opt in
        h)
            echo "Usage: $0 [-h] [-o key=value] [-A aws_profile] [-E ecr_repo] [-L lambda_function] [-R role_name] [-P policy_name] [-T pattern_path] [-S s3_output_path] [-K test_s3_key] [-g region] [-t timeout] [-m memory_size] [-u S3_RESOURCE_ARN]"
            echo "Defaults for OPTIONS:"
            echo "  nsm=${OPTS_NSM}"
            echo "  fdown=${OPTS_FDOWN}"
            echo "  flim=${OPTS_FLIM}"
            echo "  noisefact=${OPTS_NOISEFACT}"
            echo "  currmax=${OPTS_CURRMAX}"
            echo "  reject_distant_bragg=${OPTS_REJECT_DISTANT_BRAGG}"
            echo "  reject_noise_ionospheric=${OPTS_REJECT_NOISE_IONOSPHERIC}"
            echo "  reject_noise_ionospheric_threshold=${OPTS_REJECT_NOISE_IONOSPHERIC_THRESHOLD}"
            echo "  COMPUTE_FOR=${OPTS_COMPUTE_FOR}"
            echo "  doppler_interpolation=${OPTS_DOPPLER_INTERPOLATION}"
            echo "  PPMIN=${OPTS_PPMIN}"
            echo "  PWMAX=${OPTS_PWMAX}"
            echo "  smoothNoiseLevel=${OPTS_SMOOTH_NOISE_LEVEL}"
            echo "  MUSIC_parameters=${OPTS_MUSIC_PARAMETERS}"
            echo "  discard=${OPTS_DISCARD}"
            echo "  SEASONDER_PATTERN_PATH=${OPTS_PATTERN_PATH}"
            echo "  SEASONDER_S3_OUTPUT_PATH=${OPTS_S3_OUTPUT_PATH}"
            echo "  TEST_S3_KEY=${TEST_S3_KEY}"
            echo "  REGION=${REGION}"
            echo "  S3_RESOURCE_ARN=${S3_RESOURCE_ARN}"
            exit 0
            ;;
        o) user_options+=("$OPTARG") ;;
        A) AWS_PROFILE="$OPTARG" ;;
        E) ECR_REPO="$OPTARG" ;;
        L) LAMBDA_FUNCTION="$OPTARG" ;;
        R) ROLE_NAME="$OPTARG" ;;
        P) POLICY_NAME="$OPTARG" ;;
        T) OPTS_PATTERN_PATH="$OPTARG" ;;  # New flag for pattern path override
        S) OPTS_S3_OUTPUT_PATH="$OPTARG" ;; # New flag for S3 output path override
        K) TEST_S3_KEY="$OPTARG" ;;         # New flag for S3 key override
        g) REGION="$OPTARG" ;;              # New flag for region override
        t) TIMEOUT="$OPTARG" ;;
        m) MEMORY_SIZE="$OPTARG" ;;
        u) S3_RESOURCE_ARN="$OPTARG" ;;     # New flag for S3_RESOURCE_ARN override
        *) ;;
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
      SEASONSER_DISCARD) OPTS_DISCARD="$value" ;;
      SEASONDER_PATTERN_PATH) OPTS_PATTERN_PATH="$value" ;;
      SEASONDER_S3_OUTPUT_PATH) OPTS_S3_OUTPUT_PATH="$value" ;;
      *) ;;
    esac
done

# After processing the options, validate mandatory S3 arguments:
if [ -z "$OPTS_PATTERN_PATH" ] || [ -z "$OPTS_S3_OUTPUT_PATH" ]; then
    echo "Error: Both SEASONDER_PATTERN_PATH (-T) and SEASONDER_S3_OUTPUT_PATH (-S) must be provided."
    exit 1
fi

# Validate that the provided arguments are valid S3 URIs:
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
echo "  discard=${OPTS_DISCARD}"

# ----- Create temporary JSON files for IAM role and policy -----
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

# ----- Create IAM role for Lambda -----
if run_aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1; then
    echo "IAM role $ROLE_NAME already exists, skipping creation." >> "$LOGFILE" 2>&1
else
    echo "Creating IAM role..." >> "$LOGFILE" 2>&1
    run_aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file://lambda-policy.json \
      --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1

    echo "Updating IAM role trust relationship..." >> "$LOGFILE" 2>&1
    run_aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document file://lambda-policy.json \
      --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1
    sleep 30
fi

# ----- Create policy and attach it to the role -----
EXISTING_POLICY_ARN=$(run_aws iam list-policies --profile "$AWS_PROFILE" --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text 2>&1)
if [ -n "$EXISTING_POLICY_ARN" ]; then
    echo "IAM policy $POLICY_NAME already exists, skipping creation." >> "$LOGFILE" 2>&1
else
    echo "Creating IAM policy..." >> "$LOGFILE" 2>&1
    POLICY_ARN=$(run_aws iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document file://lambda.json \
      --profile "$AWS_PROFILE" 2>&1 | jq -r '.Policy.Arn')
    echo "Attaching policy to the role..." >> "$LOGFILE" 2>&1
    run_aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn "$POLICY_ARN" \
      --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1
fi

# ----- Create ECR repository (if not exists) -----
if run_aws ecr describe-repositories --repository-names "$ECR_REPO" --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1; then
    echo "ECR repository $ECR_REPO already exists, skipping creation." >> "$LOGFILE" 2>&1
else
    echo "Creating ECR repository..." >> "$LOGFILE" 2>&1
    run_aws ecr create-repository \
      --repository-name "$ECR_REPO" \
      --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1
fi

# ----- Log in to ECR -----

echo "Logging in to ECR..." >> "$LOGFILE" 2>&1
PASSWORD=$(run_aws ecr get-login-password --profile "$AWS_PROFILE" --region "$REGION")
echo "$PASSWORD" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ----- Build, tag, and push the Docker image -----
echo "Building Docker image..."
docker build -t "$ECR_REPO" .

echo "Tagging Docker image..."
docker tag "$ECR_REPO":latest "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$ECR_REPO:latest"

echo "Pushing Docker image..."
docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$ECR_REPO:latest"

# ----- Create or update the Lambda function -----
IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$ECR_REPO:latest"
if run_aws lambda get-function --function-name "$LAMBDA_FUNCTION" --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1; then
    echo "Lambda function $LAMBDA_FUNCTION already exists, updating the image..." >> "$LOGFILE" 2>&1
    run_aws lambda update-function-code \
      --function-name "$LAMBDA_FUNCTION" \
      --image-uri "$IMAGE_URI" \
      --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1
else
    echo "Creating Lambda function with image URI: $IMAGE_URI" >> "$LOGFILE" 2>&1
    run_aws lambda create-function \
        --function-name "$LAMBDA_FUNCTION" \
        --package-type Image \
        --code ImageUri="$IMAGE_URI" \
        --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME" \
        --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1
fi

# ----- Update Lambda function configuration (optional) -----
echo "Updating Lambda function configuration..." >> "$LOGFILE" 2>&1
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
    \"SEASONSER_DISCARD\":\"$OPTS_DISCARD\",
    \"SEASONDER_S3_OUTPUT_PATH\":\"$OPTS_S3_OUTPUT_PATH\"
  }}" \
  --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
      echo "Max retries reached. Update function configuration failed." >> "$LOGFILE" 2>&1
      exit 1
    fi
    echo "Update in progress. Retry $RETRY_COUNT/$MAX_RETRIES. Waiting 10 seconds..." >> "$LOGFILE" 2>&1
    sleep 10
done

# ----- Invoke the Lambda function for testing (only if TEST_S3_KEY is provided) -----
if [ -n "$TEST_S3_KEY" ]; then
    BUCKET_NAME=$(echo "$TEST_S3_KEY" | awk -F'/' '{print $3}')
    echo "Invoking Lambda function for testing..." >> "$LOGFILE" 2>&1
    run_aws lambda invoke \
      --function-name "$LAMBDA_FUNCTION" \
      --payload "{\"invocationSchemaVersion\": \"1.0\", \"invocationId\": \"YXNkbGZqYWRmaiBhc2RmdW9hZHNmZGpmaGFzbGtkaGZza2RmaAo\", \"job\": {\"id\": \"f3cc4f60-61f6-4a2b-8a21-d07600c373ce\"}, \"tasks\": [{\"taskId\": \"dGFza2lkZ29lc2hlcmUF\", \"s3BucketArn\": \"arn:aws:s3:::${BUCKET_NAME}\", \"s3Key\": \"${TEST_S3_KEY}\", \"s3VersionId\": \"1\"}]}" \
      response.json \
      --cli-binary-format raw-in-base64-out \
      --profile "$AWS_PROFILE" >> "$LOGFILE" 2>&1
fi

echo "Script completed. Check response.json for the invocation result."

# Clean up temporary files
rm lambda-policy.json lambda.json
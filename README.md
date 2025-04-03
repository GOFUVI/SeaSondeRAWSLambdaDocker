# Batch Processing of SeaSonde HF-Radar Spectra Files on AWS with SeaSondeR R Package

## Table of Contents

1. **[Repository Overview](#1-repository-overview)**
2. **[SeaSondeR on AWS: Building & Deploying a Docker-based Lambda Function](#2-seasonder-on-aws-building--deploying-a-docker-based-lambda-function)**
    - [2.1 Step-by-step AWS Setup for Docker Image & Lambda Function](#21-step-by-step-aws-setup-for-docker-image--lambda-function)
    - [Script: configure_seasonder.sh](#21-script-configure_seasondersh)
3. **[Preparing a Manifest for S3 Batch Operations](#3-preparing-a-manifest-for-s3-batch-operations)**
    - [3.1 Step-by-step instructions to create a manifest](#31-step-by-step-instructions-to-create-a-manifest)
    - [Script: prepare_manifest.sh](#31-script-prepare_manifestsh)

## 1. Repository Overview
### 1.1 Overview & Prerequisites

Welcome to our repository for batch processing HF-Radar spectra files using the SeaSondeR R package on AWS. This guide will walk you through building, deploying, and updating a Docker-based Lambda function to process files stored in Amazon S3, as well as preparing a CSV manifest for S3 Batch Operations. Through this comprehensive approach, you will learn to:

- **Build** a Docker image containing SeaSondeR.
- **Push** the image to AWS Elastic Container Registry (ECR), a managed service for Docker images.
- **Deploy** and **update** an AWS Lambda function using the Docker image to process S3 files.
- **Create a CSV manifest** that lists S3 objects, simplifying the execution of batch operations over large numbers of files.

*Key Technologies:*
- **Docker:** Lightweight, independent containers.
- **ECR (Elastic Container Registry):** AWS-managed service for Docker images.
- **Lambda:** Serverless computing for executing code in response to events.
- **S3 (Simple Storage Service):** Scalable storage for data and files.
- **IAM (Identity and Access Management):** Managing permissions for AWS resources.

#### Prerequisites

Before you begin, ensure you have:

- **AWS SSO User:** An AWS Single Sign-On identity with the necessary permissions (administrative permissions are acceptable for testing, though not recommended for production).
- **AWS CLI v2:** The latest version installed and configured (for example, using AWS SSO).
- **Docker:** Installed and running on your system.
- **jq:** A command-line tool for processing JSON.
- **Basic Command Line Skills:** Familiarity with using the terminal to execute scripts and commands.
- Appropriate permissions to list objects on S3 and to manage uploads/downloads, which are essential for generating and handling the CSV manifest for S3 Batch Operations.

This combination of tools and requirements will prepare you to deploy a robust, automated solution that covers both data processing with SeaSondeR and the efficient management of multiple S3 files via Batch Operations.

---

## 2. SeaSondeR on AWS: Building & Deploying a Docker-based Lambda Function

### 2.1. Step-by-step AWS Setup for Docker Image & Lambda Function

This section covers the steps to prepare your AWS environment.

#### Configure AWS CLI with SSO

AWS CLI allows you to interact with AWS services from the command line. To configure it for SSO (Single Sign-On), run:

```bash
aws configure sso
```

This command will prompt you to authenticate and select an AWS SSO profile.

---

#### Create an ECR Repository

ECR is where your Docker image will be stored. Replace `your_aws_profile` with your actual AWS CLI profile name and adjust the repository name if needed.

```bash
aws ecr create-repository --profile your_aws_profile --repository-name my-lambda-docker
```

*Example JSON Response:*
```json
{
    "repository": {
        "repositoryArn": "arn:aws:ecr:eu-west-3:123456789012:repository/my-lambda-docker",
        "registryId": "123456789012",
        "repositoryName": "my-lambda-docker",
        "repositoryUri": "123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker",
        "createdAt": "2025-04-01T11:34:29.685000+02:00",
        "imageTagMutability": "MUTABLE",
        "imageScanningConfiguration": {
            "scanOnPush": false
        },
        "encryptionConfiguration": {
            "encryptionType": "AES256"
        }
    }
}
```

---

#### Push Your Docker Image to ECR

Follow these steps to build your Docker image, tag it, and push it to ECR:

1. **Log in to ECR:**

   This command retrieves a temporary login token and logs Docker into your ECR registry.

   ```bash
   aws ecr get-login-password --profile your_aws_profile --region eu-west-3 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.eu-west-3.amazonaws.com
   ```

2. **Build the Docker Image:**

   Navigate to your repository directory and build the image. The `-t` flag tags the image with the given name.

   ```bash
   docker build -t my-lambda-docker .
   ```

3. **Tag the Docker Image:**

   Tag the image so that it can be recognized by ECR.

   ```bash
   docker tag my-lambda-docker:latest 123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest
   ```

4. **Push the Docker Image:**

   Push the tagged image to your ECR repository.

   ```bash
   docker push 123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest
   ```

---

#### Create the Lambda Function

AWS Lambda lets you run code without provisioning servers. To run your Docker image as a Lambda function, perform the following steps:

1. **Create a Basic Execution Role for Lambda:**

   Lambda functions require an IAM role that defines permissions. First, create a trust policy file (e.g., `lambda-policy.json`):

   ```json
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
   ```

   Create the role with:

   ```bash
   aws iam create-role --role-name process-lambda-role --assume-role-policy-document file://lambda-policy.json --profile your_aws_profile
   ```

   *Example response:*
   ```json
   {
       "Role": {
           "RoleName": "process-lambda-role",
           "Arn": "arn:aws:iam::123456789012:role/process-lambda-role",
           "CreateDate": "2025-04-01T09:53:30+00:00",
           "AssumeRolePolicyDocument": { ... }
       }
   }
   ```

2. **Attach S3 and Logs Permissions:**

   Create a policy file (e.g., `lambda.json`) that grants the necessary permissions for S3 and CloudWatch Logs (used for logging):

   ```json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Sid": "S3AndLogGroupAccess",
               "Effect": "Allow",
               "Action": [
                   "s3:PutObject",
                   "s3:GetObject",
                   "logs:CreateLogGroup"
               ],
               "Resource": [
                   "arn:aws:s3:::my-s3-bucket/*",
                   "arn:aws:logs:eu-west-3:123456789012:*"
               ]
           },
           {
               "Sid": "LogStreamAndEvents",
               "Effect": "Allow",
               "Action": [
                   "logs:CreateLogStream",
                   "logs:PutLogEvents"
               ],
               "Resource": "arn:aws:logs:eu-west-3:123456789012:log-group:/aws/lambda/process_lambda:*"
           }
       ]
   }
   ```

   Create the policy with:

   ```bash
   aws iam create-policy \
   --policy-name lambda-s3-logs \
   --policy-document file://lambda.json \
   --profile your_aws_profile
   ```

   *Sample response:*
   ```json
   {
       "Policy": {
           "PolicyName": "lambda-s3-logs",
           "Arn": "arn:aws:iam::123456789012:policy/lambda-s3-logs",
           "CreateDate": "2025-04-01T10:27:24+00:00"
       }
   }
   ```

   Then, attach the policy to the previously created role:

   ```bash
   aws iam attach-role-policy --role-name process-lambda-role --policy-arn arn:aws:iam::123456789012:policy/lambda-s3-logs --profile your_aws_profile
   ```

3. **Create the Lambda Function:**

   Use the Docker image stored in ECR to create your Lambda function:

   ```bash
   aws lambda create-function \
       --function-name process_lambda \
       --package-type Image \
       --code ImageUri=123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest \
       --role arn:aws:iam::123456789012:role/process-lambda-role \
       --profile your_aws_profile
   ```

   A successful creation returns a JSON object that includes the function name, ARN, and status.

---

#### Updating the Lambda Function

When you update your Docker image or want to change configuration settings, use the following commands:

1. **Update the Image:**

   ```bash
   aws lambda update-function-code \
       --function-name process_lambda \
       --image-uri 123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest \
       --profile your_aws_profile
   ```

2. **Update Configuration (e.g., timeout, memory, environment variables):**

   ```bash
   aws lambda update-function-configuration \
     --function-name process_lambda \
     --timeout 100 \
     --memory-size 2048 \
     --environment '{"Variables":{"MY_PATTERN_PATH":"s3://my-s3-bucket/path/to/your/pattern/file.txt", "MY_DOPPLER_INTERPOLATION":"2", "MY_S3_OUTPUT_PATH":"s3://my-s3-bucket/path/to/your/output/folder"}}' \
     --profile your_aws_profile
   ```

   *Example response:*
   ```json
   {
       "FunctionName": "process_lambda",
       "MemorySize": 2048,
       "Timeout": 40,
       "Environment": {
           "Variables": {
               "MY_PATTERN_PATH": "s3://my-s3-bucket/path/to/your/pattern/file.txt",
               "MY_DOPPLER_INTERPOLATION": "1"
           }
       },
       "State": "Active",
       ...
   }
   ```

---

#### Testing the Lambda Function

After deployment, test your Lambda function by invoking it with a sample payload. This payload includes identifiers and S3 file information that the function will process.

```bash
aws lambda invoke \
  --function-name process_lambda \
  --payload '{"invocationSchemaVersion": "1.0", "invocationId": "example-invocation-id", "job": {"id": "job-id"}, "tasks": [{"taskId": "task-id", "s3BucketArn": "arn:aws:s3:::my-s3-bucket", "s3Key": "your/spectra/file/key.css", "s3VersionId": "1"}]}' \
  response.json \
  --cli-binary-format raw-in-base64-out \
  --profile your_aws_profile
```

A successful test will output a response similar to:

```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
```
---


### 2.1. Script: configure_seasonder.sh

This section provides detailed instructions for the `configure_seasonder.sh` script, which automates the deployment process described above.

#### Overview and Purpose

The `configure_seasonder.sh` script is designed to simplify the deployment of the Docker-based AWS Lambda function. It automates the following tasks:
- Creating IAM roles and policies.
- Setting up an ECR repository.
- Building and pushing the Docker image.
- Creating or updating the Lambda function.

All AWS CLI commands executed by the script are logged to `aws_commands.log` for troubleshooting.

---

#### Pre-requisites for the Script

Before running the script, ensure you have:
- **AWS CLI v2, Docker, and jq** installed on your machine.
- An AWS profile configured with permissions to manage IAM roles, policies, ECR repositories, and Lambda functions (e.g., via `aws configure sso`).

---

#### Usage and Options

Run the script from the command line with the following options:

```bash
./configure_seasonder.sh [-h] [-o key=value] [-A aws_profile] [-E ecr_repo] [-L lambda_function] [-R role_name] [-P policy_name] [-T pattern_path] [-S s3_output_path] [-K test_s3_key] [-g region] [-t timeout] [-m memory_size] [-u S3_RESOURCE_ARN]
```

**Options Explained:**

- **-h:** Display the help message.
- **-o key=value:** Override default settings (multiple overrides allowed).
- **-A:** AWS profile (default: your configured profile).
- **-E:** ECR repository name (default: `my-lambda-docker`).
- **-L:** Lambda function name (default: `process_lambda`).
- **-R:** IAM role name (default: `process-lambda-role`).
- **-P:** IAM policy name (default: `lambda-s3-logs`).
- **-T:** S3 URI for the input antenna pattern file (must start with `s3://`).
- **-S:** S3 URI for the output directory where results will be saved. This will create folders like `Radial_Metrics` and `CS_Objects`.
- **-K:** *(Optional)* S3 URI for a spectral file used to test the Lambda function.
- **-g:** AWS region (default: `eu-west-3`).
- **-t:** Lambda function timeout in seconds (default: 100).
- **-m:** Lambda memory size in MB (default: 2048).
- **-u:** S3 resource ARN granting the Lambda permissions for `s3:PutObject` and `s3:GetObject` (must start with `arn:aws:s3:::`).

---

#### Step-by-Step Execution

1. **Parameter Validation:**  
   The script first checks that all required S3 URIs are provided and that they follow the correct format.

2. **IAM Setup:**  
   It creates temporary JSON files defining the IAM trust and execution policies, then checks if the required IAM role and policy exist; if not, it creates or updates them.

3. **ECR Repository Check:**  
   The script verifies if the specified ECR repository exists, creating it if necessary.

4. **Docker Image Deployment:**  
   It logs into ECR, builds the Docker image, tags it, and pushes it to the repository.

5. **Lambda Function Management:**  
   The script then creates or updates the Lambda function to use the new Docker image and configures it with the environment variables provided.

6. **Optional Testing:**  
   If a test S3 key is provided, the script will invoke the Lambda function to verify that the deployment was successful.

---

#### Example Commands

- **Basic Run with Mandatory S3 URIs:**

   ```bash
   ./configure_seasonder.sh -T s3://example-bucket/my-pattern.txt -S s3://example-bucket/output/
   ```

- **Advanced Run with a Custom AWS Profile and a Test Key:**

   ```bash
   ./configure_seasonder.sh -A myCustomProfile -T s3://example-bucket/my-pattern.txt -S s3://example-bucket/output/ -K s3://example-bucket/test-key.txt
   ```

---

#### Troubleshooting

- **Review Logs:**  
  If you encounter issues, check `aws_commands.log` for detailed output of the AWS CLI commands executed by the script.

- **Permissions:**  
  Ensure that your AWS credentials have the necessary permissions to create and manage IAM roles, ECR repositories, and Lambda functions.

- **Parameter Format:**  
  Verify that the S3 URIs and other parameters are correctly formatted.

---

## 3. Preparing a Manifest for S3 Batch Operations

S3 Batch Operations allow you to process large numbers of S3 objects in a single job. To do this, you need to prepare a manifest file—a CSV file listing the objects to process (with each line typically containing the bucket name and the object key, separated by a comma). Below are step-by-step instructions to create this manifest from an S3 folder (including its subfolders).

### 3.1 Step-by-step instructions to create a manifest

#### Step 1: List All Objects in the Folder

Use the AWS CLI to list all objects in your target S3 folder. Replace `my-s3-bucket` with your bucket name and adjust the prefix path as needed.

```bash
aws s3api list-objects-v2 \
  --bucket my-s3-bucket \
  --prefix "path/to/folder/" \
  --output json \
  --profile your_aws_profile > objects.json
```

This command retrieves a JSON-formatted list of all objects under the specified folder.

#### Step 2: Generate the CSV Manifest

There are two common approaches to extract the object keys and format them into a CSV file:

##### Option 1: Using `jq`

If you have `jq` installed, run the following command to extract each object's key and create a CSV file where each line is formatted as `bucket,key`:

```bash
jq -r '.Contents[] | "my-s3-bucket," + .Key' objects.json > manifest.csv
```

##### Option 2: Using `awk` (Without `jq`)

If you prefer not to use `jq`, you can use `awk` along with the `aws s3 ls` command. This command recursively lists the objects and formats the output into a CSV file. Make sure that the fourth column contains the object key (this may vary depending on your AWS CLI output):

```bash
aws s3 ls s3://my-s3-bucket/path/to/folder/ --recursive --profile your_aws_profile | awk '{print "my-s3-bucket," $4}' > manifest.csv
```

#### Step 3: Verify the Manifest

```bash
cat manifest.csv
```

Ensure that each line of `manifest.csv` correctly lists a bucket and an object key, making it ready for S3 Batch Operations.

### 3.2 Script: prepare_manifest.sh

This section provides detailed instructions for the prepare_manifest.sh script, which implements los steps described above to  generate a CSV manifest from an S3 folder. The script supports two methods for creating the manifest — using jq (preferred) or awk (fallback) — and offers options to display and optionally upload the manifest.

---

#### Overview and Purpose

The prepare_manifest.sh script is designed to simplify the creation of a manifest file for S3 Batch Operations. It:
- Lists S3 objects based on a specified bucket and folder prefix.
- Generates a CSV file (manifest.csv) where each line contains the bucket name and object key.
- Optionally uploads the generated manifest to a specified S3 destination.
- Cleans up temporary files after execution.

---

#### Pre-requisites

Before running prepare_manifest.sh, ensure that you have:
- **AWS CLI v2** installed and configured (e.g., using AWS SSO).
- **jq** installed for JSON processing (optional; the script falls back to awk if not available).
- The correct AWS permissions to list S3 objects and upload files if needed.

---

#### Usage and Options

Run the script from the command line with the following options:

```bash
./prepare_manifest.sh -b bucket_name -p prefix -r aws_profile [-d s3_destination_uri]
```

**Option Details:**

- **-b bucket_name:** Specifies the S3 bucket name.
- **-p prefix:** Defines the S3 folder prefix (e.g., "path/to/folder/").
- **-r aws_profile:** Indicates the AWS CLI profile to use.
- **-d s3_destination_uri (Optional):** If provided, the manifest.csv is uploaded to this S3 URI (must start with s3://).
- **-h:** Show the help message and usage instructions.

---

#### Step-by-Step Execution

1. **Argument Validation:**  
    The script checks if the required parameters (-b, -p, and -r) are provided and validates the format of the destination URI if specified.

2. **List S3 Objects:**  
    Using the AWS CLI (with the provided AWS profile), the script lists the objects within the specified bucket and prefix and saves the output as objects.json.

3. **Generate the CSV Manifest:**  
    - If jq is available, it extracts the object keys and formats each line as "bucket,object_key".
    - Otherwise, awk is used with the output of aws s3 ls to generate the CSV manifest.

4. **Display Manifest Content:**  
    The content of manifest.csv is shown in the terminal for verification.

5. **Optional Upload to S3:**  
    If a destination URI is provided (-d), the script uploads manifest.csv to that S3 location.

6. **Cleanup:**  
    Temporary files, such as objects.json, are removed at the end of the script.

---

#### Example Commands

- **Basic Usage (Display Manifest):**

    ```bash
    ./prepare_manifest.sh -b my-s3-bucket -p "path/to/folder/" -r myprofile
    ```

- **Usage with Upload Option:**

    ```bash
    ./prepare_manifest.sh -b my-s3-bucket -p "path/to/folder/" -r myprofile -d s3://destination-bucket/manifest/manifest.csv
    ```

---

#### Troubleshooting

- **Error Listing Objects:**  
  Check your AWS CLI credentials and ensure that the bucket and prefix are correct.

- **Manifest Generation Issues:**  
  Verify that either jq or awk is installed and functioning. If using aws s3 ls, confirm that the expected output format matches the script’s assumptions.

- **Upload Failures:**  
  Ensure that the destination URI starts with s3:// and that the IAM role associated with the AWS CLI profile has permission to upload files.

---

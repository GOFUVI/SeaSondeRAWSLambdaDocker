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

This script requires jq. Run the following command to extract each object's key and create a CSV file where each line is formatted as `bucket,key`:

```bash
jq -r '.Contents[] | "my-s3-bucket," + .Key' objects.json > manifest.csv
```

#### Step 3: Verify the Manifest

```bash
cat manifest.csv
```

Ensure that each line of `manifest.csv` correctly lists a bucket and an object key, making it ready for S3 Batch Operations.

### 3.2 Script: prepare_manifest.sh

This section provides detailed instructions for the prepare_manifest.sh script, which implements the steps described above to generate a CSV manifest from an S3 folder. The script supports jq for creating the manifest and offers options to display and optionally upload the manifest.

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
- **jq** installed for JSON processing.
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
    jq is used to extract the object keys and format each line as "bucket,object_key".

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
  Verify that jq is installed and functioning.

- **Upload Failures:**  
  Ensure that the destination URI starts with s3:// and that the IAM role associated with the AWS CLI profile has permission to upload files.

---

## 4. Running a Batch Operations Job

This section explains how to launch and confirm an S3 Batch Operations job to process files using the deployed Lambda function.

### 4.1 Step-by-step

#### Step 1: Get the Manifest File’s ETag

Before creating the job, you must retrieve the ETag of the CSV manifest file you uploaded to S3. This value is required to correctly define the manifest’s location.

Run the following command—adjust the bucket, key, and profile as needed:

```bash
aws s3api head-object --bucket my-bucket --key path/to/manifest.csv --profile myprofile
```

The output will look similar to this:

```json
{
    "AcceptRanges": "bytes",
    "LastModified": "2025-04-03T08:50:02+00:00",
    "ContentLength": 790,
    "ETag": "\"cbfd024288e24abb7cb36ef9cde2073f\"",
    "ContentType": "text/csv",
    "ServerSideEncryption": "AES256",
    "Metadata": {}
}
```

Copy the value of `"ETag"` (without the quotes), for example:  
`cbfd024288e24abb7cb36ef9cde2073f`.

---

#### Step 2: Create the Batch Operations Role

To allow the Batch Operations job to invoke the Lambda function and access S3 objects, you need to create a role with the proper permissions.

**a) Create the Batch Operations Policy**

Save the following content in a file named `batch-policy.json`:

```json
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
                "arn:aws:s3:::my-bucket/*",
                "arn:aws:lambda:eu-west-3:123456789012:function:process_lambda:$LATEST"
            ]
        }
    ]
}
```

Then create the policy with:

```bash
aws iam create-policy \
  --policy-name batch-lambda-policy \
  --policy-document file://batch-policy.json \
  --profile myprofile
```

**b) Create the Batch Operations Role**

Create a trust policy file (e.g., `lambda-policy.json`) with the following content:

```json
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
```

Create the role by running:

```bash
aws iam create-role --role-name batch-lambda-role --assume-role-policy-document file://lambda-policy.json --profile myprofile
```

Attach the policy to the role:

```bash
aws iam attach-role-policy --role-name batch-lambda-role --policy-arn arn:aws:iam::123456789012:policy/batch-lambda-policy --profile myprofile
```

---

#### Step 3: Create the S3 Batch Operations Job

Use the `aws s3control create-job` command to define and launch the job. Adjust the values (account ID, ARNs, manifest location, etc.) according to your environment:

```bash
aws s3control create-job \
  --account-id 123456789012 \
  --operation '{"LambdaInvoke": {"FunctionArn": "arn:aws:lambda:eu-west-3:123456789012:function:process_lambda:$LATEST"}}' \
  --manifest '{"Spec": {"Format": "S3BatchOperations_CSV_20180820", "Fields": ["Bucket", "Key"]}, "Location": {"ObjectArn": "arn:aws:s3:::my-bucket/path/to/manifest.csv", "ETag": "cbfd024288e24abb7cb36ef9cde2073f"}}' \
  --priority 10 \
  --role-arn arn:aws:iam::123456789012:role/batch-lambda-role \
  --no-confirmation-required \
  --report '{"Bucket": "arn:aws:s3:::my-bucket", "Prefix": "path/to", "Format": "Report_CSV_20180820", "Enabled": true, "ReportScope": "AllTasks"}' \
  --description "Running S3 Batch Operations job on manifest.csv" \
  --profile myprofile
```

The command will return a JSON output containing a `JobId`, for example:

```json
{
    "JobId": "fake-job-id-1234"
}
```

---

#### Step 4: Confirm and Execute the Job

To allow the job to run, you need to confirm it by updating its status. Use the `JobId` obtained above:

```bash
aws s3control update-job-status \
  --account-id 123456789012 \
  --job-id fake-job-id-1234 \
  --requested-job-status Ready \
  --profile myprofile
```

This command confirms the job, and it will begin executing according to the defined configuration.

---

This step-by-step guide covers obtaining the manifest ETag, setting up the necessary role and policy for Batch Operations, creating the job, and confirming its execution. Adjust the parameters as needed for your specific environment.


### 4.2 Script: run_batch_job.sh

The `run_batch_job.sh` script automates the process of preparing and launching an S3 Batch Operations job, streamlining the steps described in the previous section. Below is an overview of its functionalities and usage details.

#### What the Script Does

1. **Parameter Validation:**
   - Ensures the manifest URI (provided with `-U`) is given and starts with `s3://`.
   - Checks that an AWS CLI profile (provided with `-p`) is specified.

2. **Extracting Manifest Details:**
   - Parses the manifest URI to extract the bucket name and object key.
   - If no report prefix is provided via `-P`, it automatically derives one from the manifest key.

3. **Retrieving the Manifest ETag:**
   - Uses the AWS CLI to obtain the ETag of the manifest file from S3. The ETag is essential for configuring the Batch Operations job.

4. **IAM Policy and Role Setup:**
   - Creates a JSON policy file (`batch-policy.json`) with the necessary permissions (e.g., S3 operations, Lambda invocation).
   - Attempts to create the specified IAM policy (using `-y`) if it does not exist.
   - Creates a trust policy file (`batch-trust-policy.json`) for the Batch Operations role.
   - Creates the IAM role (using `-r`) if it does not already exist and waits for its propagation.
   - Attaches the policy to the role.

5. **Job Creation:**
   - Determines the confirmation flag based on the `-c` option (either `yes` for `--confirmation-required` or `no` for `--no-confirmation-required`).
   - Initiates the S3 Batch Operations job by invoking the specified Lambda function on the objects listed in the manifest.
   - Logs the job creation output and displays the Job ID.

6. **Cleanup:**
   - Removes temporary files created during execution (such as `batch-policy.json` and `batch-trust-policy.json`).

---

#### Usage

```bash
./run_batch_job.sh [-h] -U manifest_uri [-g region] [-r role_name] [-y policy_name] [-l lambda_function] -p profile [-c yes|no] [-P report_prefix]
```

**Options:**

- **-h:** Show help message with usage instructions.
- **-U manifest_uri:** *(Required)* Full S3 URI of the manifest CSV (e.g., `s3://bucket/path/manifest.csv`).
- **-g region:** AWS region to operate in *(default: `eu-west-3`)*.
- **-r role_name:** Name of the IAM role to use or create for the Batch Operations job *(default: `batch-lambda-role`)*.
- **-y policy_name:** Name of the IAM policy to use or create *(default: `batch-lambda-policy`)*.
- **-l lambda_function:** Name of the Lambda function to invoke during the job *(default: `process_lambda`)*.
- **-p profile:** *(Required)* AWS CLI profile to use for authentication.
- **-c yes|no:** Specify if confirmation is required for the job:
  - `yes` uses `--confirmation-required`.
  - `no` uses `--no-confirmation-required`.
  *(Default is `yes`.)*
- **-P report_prefix:** Optional prefix for job reports. If omitted, the script derives a prefix from the manifest key.

---

#### Example

```bash
./run_batch_job.sh -U s3://jlhc-hf-eolus/tests/manifest.csv -g eu-west-3 -r batch-lambda-role -y batch-lambda-policy -l process_lambda -p setup -c no -P custom_prefix
```

---

#### Additional Notes

- **Logging:**  
  Every AWS CLI command and its output are logged to `run_batch_job.log`, making it easier to troubleshoot issues.

- **IAM Propagation:**  
  The script includes a waiting mechanism to ensure that the IAM role is fully propagated before the job is created.

- **Dynamic Configuration:**  
  It dynamically retrieves the AWS account ID to construct ARNs for IAM policies, roles, and the Lambda function.

This user manual provides a comprehensive guide to using the `run_batch_job.sh` script, enabling you to efficiently automate your S3 Batch Operations jobs.

---

## Acknowledgements

This Docker image utilizes the "lambdr" package by David Neuzerling.

Neuzerling D (2025). lambdr: Create a Runtime for Serving Containerised R Functions on 'AWS Lambda'. R package version 1.2.6, https://github.com/mdneuzerling/lambdr, https://lambdr.mdneuzerling.com/.

This work has been funded by the HF-EOLUS project (TED2021-129551B-I00), financed by MICIU/AEI /10.13039/501100011033 and by the European Union NextGenerationEU/PRTR - BDNS 598843 - Component 17 - Investment I3.

## Disclaimer

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

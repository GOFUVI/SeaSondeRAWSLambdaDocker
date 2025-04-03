Below is a revised, detailed README that explains each step and technical term so that even users without an extensive technical background can follow along.

---

# SeaSondeR on AWS: Building & Deploying a Docker-based Lambda Function

This repository demonstrates how to build a Docker image for SeaSondeR, push it to AWS Elastic Container Registry (ECR), and deploy it as an AWS Lambda function. The Lambda function processes files stored in Amazon S3. This guide explains each step in plain English and provides background on the underlying technologies.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [AWS Setup for Docker Image & Lambda Function](#aws-setup)
   - [Configure AWS CLI with SSO](#aws-cli)
   - [Create an ECR Repository](#ecr-repository)
   - [Push Your Docker Image to ECR](#push-docker)
   - [Create the Lambda Function](#create-lambda)
   - [Update the Lambda Function](#update-lambda)
   - [Test the Lambda Function](#test-lambda)
4. [User Manual: configure_seasonder.sh](#user-manual)
   - [Overview and Purpose](#script-overview)
   - [Pre-requisites for the Script](#script-prerequisites)
   - [Usage and Options](#script-usage)
   - [Step-by-Step Execution](#script-steps)
   - [Example Commands](#script-examples)
   - [Troubleshooting](#script-troubleshooting)

---

## 1. Overview

SeaSondeR is a tool designed to process data files from remote sensing stations. In this project, you will learn how to:
- Build a Docker image containing SeaSondeR.
- Upload this image to AWS ECR, a managed Docker container registry.
- Create an AWS Lambda function that uses the Docker image to process files stored in S3 (Amazon’s object storage service).

*Key Terms:*
- **Docker:** A platform that allows you to package applications into containers—lightweight, standalone executable packages.
- **ECR (Elastic Container Registry):** A managed AWS service to store Docker images.
- **Lambda:** A serverless compute service by AWS that runs code in response to events.
- **S3 (Simple Storage Service):** AWS storage for files, images, and other data.
- **IAM (Identity and Access Management):** A service that helps control access to AWS resources.

---

## 2. Prerequisites

Before you begin, make sure you have:

- **AWS SSO User:** An AWS Single Sign-On (SSO) identity with administrative permissions for certain tasks *(Note: Using administrative permissions is acceptable for testing but is not recommended in production)*.
- **AWS CLI v2:** The latest version of the AWS Command Line Interface is installed on your machine.
- **Docker:** Installed and running on your system.
- **jq:** A command-line tool for processing JSON.
- **Basic familiarity with command-line interfaces:** While this guide is detailed, knowing basic shell commands will help.

---

## 3. AWS Setup for Docker Image & Lambda Function

This section covers the steps to prepare your AWS environment.

### Configure AWS CLI with SSO

AWS CLI allows you to interact with AWS services from the command line. To configure it for SSO (Single Sign-On), run:

```bash
aws configure sso
```

This command will prompt you to authenticate and select an AWS SSO profile.

---

### Create an ECR Repository

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

### Push Your Docker Image to ECR

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

### Create the Lambda Function

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

### Updating the Lambda Function

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
     --environment '{"Variables":{"MY_PATTERN_PATH":"s3://my-s3-bucket/tests/readcs-docker/MeasPattern.txt", "MY_DOPPLER_INTERPOLATION":"2", "MY_S3_OUTPUT_PATH":"tests/readcs-docker"}}' \
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
               "MY_PATTERN_PATH": "s3://my-s3-bucket/tests/readcs-docker/IdealPattern.txt",
               "MY_DOPPLER_INTERPOLATION": "1"
           }
       },
       "State": "Active",
       ...
   }
   ```

---

### Testing the Lambda Function

After deployment, test your Lambda function by invoking it with a sample payload. This payload includes identifiers and S3 file information that the function will process.

```bash
aws lambda invoke \
  --function-name process_lambda \
  --payload '{"invocationSchemaVersion": "1.0", "invocationId": "example-invocation-id", "job": {"id": "job-id"}, "tasks": [{"taskId": "task-id", "s3BucketArn": "arn:aws:s3:::my-s3-bucket", "s3Key": "tests/readcs-docker/CSS_TORA_24_04_04_0700.cs", "s3VersionId": "1"}]}' \
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

## 4. User Manual: configure_seasonder.sh

This section provides detailed instructions for the `configure_seasonder.sh` script, which automates the deployment process described above.

### Overview and Purpose

The `configure_seasonder.sh` script is designed to simplify the deployment of the Docker-based AWS Lambda function. It automates the following tasks:
- Creating IAM roles and policies.
- Setting up an ECR repository.
- Building and pushing the Docker image.
- Creating or updating the Lambda function.

All AWS CLI commands executed by the script are logged to `aws_commands.log` for troubleshooting.

---

### Pre-requisites for the Script

Before running the script, ensure you have:
- **AWS CLI v2, Docker, and jq** installed on your machine.
- An AWS profile configured with permissions to manage IAM roles, policies, ECR repositories, and Lambda functions (e.g., via `aws configure sso`).

---

### Usage and Options

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

### Step-by-Step Execution

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

### Example Commands

- **Basic Run with Mandatory S3 URIs:**

   ```bash
   ./configure_seasonder.sh -T s3://example-bucket/my-pattern.txt -S s3://example-bucket/output/
   ```

- **Advanced Run with a Custom AWS Profile and a Test Key:**

   ```bash
   ./configure_seasonder.sh -A myCustomProfile -T s3://example-bucket/my-pattern.txt -S s3://example-bucket/output/ -K s3://example-bucket/test-key.txt
   ```

---

### Troubleshooting

- **Review Logs:**  
  If you encounter issues, check `aws_commands.log` for detailed output of the AWS CLI commands executed by the script.

- **Permissions:**  
  Ensure that your AWS credentials have the necessary permissions to create and manage IAM roles, ECR repositories, and Lambda functions.

- **Parameter Format:**  
  Verify that the S3 URIs and other parameters are correctly formatted.

---

This README should serve as a comprehensive guide for users to build, deploy, and manage SeaSondeR on AWS using Docker and Lambda. Each step is explained in plain language to help users of all technical backgrounds understand the process. Enjoy building your serverless application!
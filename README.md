This is an example of how SeaSondeR can be used in AWS to process multiple files from one station.

# Instructions

## AWS Setup for Docker Image & Lambda Function

### Prerequisites
- **AWS SSO User**: Use an AWS SSO identity with administrative permissions for some tasks. *(Note: This is not recommended for production environments.)*
- **AWS CLI v2**: Ensure that AWS CLI version 2 is installed on your machine.

### Configure AWS CLI with SSO
Configure your AWS CLI SSO settings by running:

```bash
aws configure sso
```

### Create an ECR Repository
Create an ECR repository where your Docker image will be stored. Replace `your_aws_profile` with your actual AWS CLI profile and update the repository name if desired.

```bash
aws ecr create-repository --profile your_aws_profile --repository-name my-lambda-docker
```

A sample JSON response might look like this:

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

### Push Your Docker Image to ECR

1. **Log in to ECR:**

   ```bash
   aws ecr get-login-password --profile your_aws_profile --region eu-west-3 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.eu-west-3.amazonaws.com
   ```

2. **Build the Docker Image:**

   Navigate to your repository directory and build the image:

   ```bash
   docker build -t my-lambda-docker .
   ```

3. **Tag the Docker Image:**

   ```bash
   docker tag my-lambda-docker:latest 123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest
   ```

4. **Push the Docker Image:**

   ```bash
   docker push 123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest
   ```

### Create the Lambda Function

1. **Create a Basic Execution Role for Lambda**

   Prepare an IAM trust policy in a file (e.g., `lambda-policy.json`) with the following content:

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

   Then, create the role:

   ```bash
   aws iam create-role --role-name process-lambda-role --assume-role-policy-document file://lambda-policy.json --profile your_aws_profile
   ```

   A sample response might be:

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

2. **Attach S3 and Logs Permissions**

   Create a policy file (e.g., `lambda.json`) with permissions to access S3 and CloudWatch Logs, similar to the AWSLambdaBasicExecutionRole:

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

   Create the policy:

   ```bash
   aws iam create-policy \
   --policy-name lambda-s3-logs \
   --policy-document file://lambda.json \
   --profile your_aws_profile
   ```

   You should receive a response similar to:

   ```json
   {
       "Policy": {
           "PolicyName": "lambda-s3-logs",
           "Arn": "arn:aws:iam::123456789012:policy/lambda-s3-logs",
           "CreateDate": "2025-04-01T10:27:24+00:00"
       }
   }
   ```

   Finally, attach the policy to your role:

   ```bash
   aws iam attach-role-policy --role-name process-lambda-role --policy-arn arn:aws:iam::123456789012:policy/lambda-s3-logs --profile your_aws_profile
   ```

3. **Create the Lambda Function**

   Now create the Lambda function using the image URI and the role created above:

   ```bash
   aws lambda create-function \
       --function-name process_lambda \
       --package-type Image \
       --code ImageUri=123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest \
       --role arn:aws:iam::123456789012:role/process-lambda-role \
       --profile your_aws_profile
   ```

   A successful creation returns a JSON similar to:

   ```json
   {
       "FunctionName": "process_lambda",
       "FunctionArn": "arn:aws:lambda:eu-west-3:123456789012:function:process_lambda",
       "Role": "arn:aws:iam::123456789012:role/process-lambda-role",
       "State": "Pending",
       ...
   }
   ```

### Updating the Lambda Function

If you need to update the image, run:

```bash
aws lambda update-function-code \
    --function-name process_lambda \
    --image-uri 123456789012.dkr.ecr.eu-west-3.amazonaws.com/my-lambda-docker:latest \
    --profile your_aws_profile
```

To update the function's configuration (e.g., timeout, memory, environment variables), execute:

```bash
aws lambda update-function-configuration \
  --function-name process_lambda \
  --timeout 100 \
  --memory-size 2048 \
  --environment '{"Variables":{"MY_PATTERN_PATH":"s3://my-s3-bucket/tests/readcs-docker/MeasPattern.txt", "MY_DOPPLER_INTERPOLATION":"2", "MY_S3_OUTPUT_PATH":"tests/readcs-docker"}}' \
  --profile your_aws_profile
```

A sample response could be:

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

### Testing the Lambda Function

Finally, invoke the function with a test payload to ensure everything is working as expected:

```bash
aws lambda invoke \
  --function-name process_lambda \
  --payload '{"invocationSchemaVersion": "1.0", "invocationId": "example-invocation-id", "job": {"id": "job-id"}, "tasks": [{"taskId": "task-id", "s3BucketArn": "arn:aws:s3:::my-s3-bucket", "s3Key": "tests/readcs-docker/CSS_TORA_24_04_04_0700.cs", "s3VersionId": "1"}]}' \
  response.json \
  --cli-binary-format raw-in-base64-out \
  --profile your_aws_profile
```

You should see a response similar to:

```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
```


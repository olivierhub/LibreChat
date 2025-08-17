# Code Execution Terraform Stack

This module provisions an AWS-based sandbox compatible with LibreChat's code execution feature. It creates:

- **API Lambda** – Node.js function exposing REST endpoints and managing sessions
- **Python Executor Lambda** – isolated function invoked by the API Lambda to run user Python code
- **EFS File System** – mounted at `/mnt/data` on the API Lambda, providing per-session persistence
- **API Gateway** – REST API forwarding `/exec` calls to the API Lambda
- **IAM Roles/Policies** – permissions for invoking the executor, writing to EFS, VPC access, and API Gateway integration

## Usage

1. Provide values for required variables in a `terraform.tfvars` or via CLI:
   - `region`
   - `vpc_id`
   - `subnet_ids`
   - optional paths for `api_lambda_zip` and `python_lambda_zip`
2. Initialize and validate:
   ```bash
   terraform init -backend=false
   terraform validate
   ```
3. Deploy:
   ```bash
   terraform apply
   ```

The output `api_gateway_url` exposes the endpoint that LibreChat should target as the `LIBRECHAT_CODE_BASEURL`.

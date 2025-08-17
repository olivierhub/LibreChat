provider "aws" {
  region = var.region
}

# Security group for Lambda function
resource "aws_security_group" "lambda" {
  name   = "code-execution-lambda"
  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for EFS allowing NFS from Lambda
resource "aws_security_group" "lambda_efs" {
  name   = "code-execution-efs"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EFS file system used for session persistence
resource "aws_efs_file_system" "code" {
  creation_token = "librechat-code-execution"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
}

resource "aws_efs_mount_target" "code" {
  count          = length(var.subnet_ids)
  file_system_id = aws_efs_file_system.code.id
  subnet_id      = var.subnet_ids[count.index]
  security_groups = [aws_security_group.lambda_efs.id]
}

resource "aws_efs_access_point" "code" {
  file_system_id = aws_efs_file_system.code.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "750"
    }
  }
}

# IAM Roles

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api_lambda" {
  name               = "code-execution-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role" "python_lambda" {
  name               = "code-execution-python"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_policy" "efs_and_invoke" {
  name   = "code-execution-efs-invoke"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"],
        Resource = [aws_efs_file_system.code.arn, aws_efs_access_point.code.arn]
      },
      {
        Effect   = "Allow",
        Action   = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.python.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_basic" {
  role       = aws_iam_role.api_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "api_vpc" {
  role       = aws_iam_role.api_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "api_custom" {
  role       = aws_iam_role.api_lambda.name
  policy_arn = aws_iam_policy.efs_and_invoke.arn
}

resource "aws_iam_role_policy_attachment" "python_basic" {
  role       = aws_iam_role.python_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Python execution Lambda
resource "aws_lambda_function" "python" {
  function_name = "code-execution-python"
  role          = aws_iam_role.python_lambda.arn
  handler       = "handler.run"
  runtime       = "python3.11"
  filename      = var.python_lambda_zip
  source_code_hash = filebase64sha256(var.python_lambda_zip)
}

# API Lambda exposing REST interface
resource "aws_lambda_function" "api" {
  function_name = "code-execution-api"
  role          = aws_iam_role.api_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  filename      = var.api_lambda_zip
  source_code_hash = filebase64sha256(var.api_lambda_zip)

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  file_system_config {
    arn              = aws_efs_access_point.code.arn
    local_mount_path = "/mnt/data"
  }

  environment {
    variables = {
      PYTHON_LAMBDA_ARN = aws_lambda_function.python.arn
    }
  }
}

# API Gateway setup
resource "aws_api_gateway_rest_api" "code_execution" {
  name = "code-execution-api"
}

resource "aws_api_gateway_resource" "exec" {
  rest_api_id = aws_api_gateway_rest_api.code_execution.id
  parent_id   = aws_api_gateway_rest_api.code_execution.root_resource_id
  path_part   = "exec"
}

resource "aws_api_gateway_method" "exec_post" {
  rest_api_id   = aws_api_gateway_rest_api.code_execution.id
  resource_id   = aws_api_gateway_resource.exec.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "exec_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.code_execution.id
  resource_id             = aws_api_gateway_resource.exec.id
  http_method             = aws_api_gateway_method.exec_post.http_method
  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.api.invoke_arn
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.code_execution.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "code_execution" {
  depends_on = [aws_api_gateway_integration.exec_lambda]
  rest_api_id = aws_api_gateway_rest_api.code_execution.id
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.code_execution.id
  deployment_id = aws_api_gateway_deployment.code_execution.id
  stage_name    = "prod"
}

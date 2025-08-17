variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC where Lambda and EFS reside"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for Lambda and EFS mount targets"
  type        = list(string)
}

variable "api_lambda_zip" {
  description = "Path to deployment package for the API Lambda"
  type        = string
  default     = "api.zip"
}

variable "python_lambda_zip" {
  description = "Path to deployment package for the Python executor Lambda"
  type        = string
  default     = "python.zip"
}

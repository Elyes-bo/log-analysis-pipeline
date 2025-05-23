# Provider configuration
provider "aws" {
  region = "eu-central-1"
}

# Variables for database credentials
variable "db_username" {
  description = "Database administrator username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Database administrator password"
  type        = string
  sensitive   = true
}

# S3 bucket for log data storage
resource "aws_s3_bucket" "log_data" {
  bucket = "log-analysis-data-bucket"
}

resource "aws_s3_bucket_ownership_controls" "log_data" {
  bucket = aws_s3_bucket.log_data.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "log_data" {
  depends_on = [aws_s3_bucket_ownership_controls.log_data]
  bucket     = aws_s3_bucket.log_data.id
  acl        = "private"
}

# Get default VPC
data "aws_vpc" "default" {
  default = true
}

# Get public subnets from default VPC
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Get private subnets from default VPC
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  
  tags = {
    Tier = "Private"
  }
}

# S3 VPC Endpoint for Glue to access S3
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = data.aws_vpc.default.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  
  route_table_ids = [data.aws_vpc.default.main_route_table_id]
  
  tags = {
    Name = "S3 VPC Endpoint"
  }
}

# Get current region
data "aws_region" "current" {}

# Secrets Manager for RDS credentials
resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "rds/logs-db-credentials"
  description = "RDS database credentials for logs DB"
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    engine   = "mysql"
    host     = aws_db_instance.logs_db.address
    port     = aws_db_instance.logs_db.port
    dbname   = aws_db_instance.logs_db.db_name
  })
  
  depends_on = [aws_db_instance.logs_db]
}

# Get the current secret version from Secrets Manager
data "aws_secretsmanager_secret_version" "current" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  depends_on = [aws_secretsmanager_secret_version.rds_credentials]
}

# IAM role for Glue
resource "aws_iam_role" "glue_role" {
  name = "glue_etl_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}

# Attach AWS managed policies for Glue
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Custom policy for Glue to access S3 bucket and Secrets Manager
resource "aws_iam_policy" "glue_access_policy" {
  name        = "glue_access_policy"
  description = "Allow Glue to access S3 and Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.log_data.arn,
          "${aws_s3_bucket.log_data.arn}/*"
        ]
      },
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.rds_credentials.arn
      },
      {
        Action = [
          "ec2:DescribeVpcEndpoints",
          "ec2:DescribeRouteTables",
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcAttribute"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:log-group:/aws-glue/*"
      },
      {
        Action = [
          "rds:DescribeDBInstances"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_access" {
  role       = aws_iam_role.glue_role.id
  policy_arn = aws_iam_policy.glue_access_policy.arn
}

# RDS security group
resource "aws_security_group" "rds_sg" {
  name        = "rds_security_group"
  description = "Allow traffic to RDS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for Glue connection
resource "aws_security_group" "glue_sg" {
  name        = "glue_security_group"
  description = "Allow Glue to connect to resources"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# DB subnet group using public subnets
resource "aws_db_subnet_group" "logs_db_subnet" {
  name       = "logs-db-subnet-group"
  subnet_ids = slice(data.aws_subnets.public.ids, 0, 2)

  tags = {
    Name = "Logs DB subnet group"
  }
}

# RDS MySQL instance
resource "aws_db_instance" "logs_db" {
  identifier             = "logs-db"
  allocated_storage      = 20
  storage_type           = "gp2"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "logs_database"
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = "default.mysql8.0"
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.logs_db_subnet.name
  publicly_accessible    = true
  backup_retention_period = 0
  multi_az               = false
  storage_encrypted      = false
}

# Glue Database and Table
resource "aws_glue_catalog_database" "logs_catalog" {
  name = "logs_catalog"
}

resource "aws_glue_catalog_table" "logs_table" {
  name          = "logs_table"
  database_name = aws_glue_catalog_database.logs_catalog.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    "classification"      = "csv"
    "csvDelimiter"        = ","
    "skip.header.line.count" = "1"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.log_data.bucket}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    columns {
      name = "datetime"
      type = "timestamp"
    }

    columns {
      name = "geography"
      type = "string"
    }

    columns {
      name = "method"
      type = "string"
    }

    columns {
      name = "client_ip"
      type = "string"
    }

    columns {
      name = "url_request"
      type = "string"
    }
  }
}

# Get subnet details
data "aws_subnet" "public_subnet" {
  id = data.aws_subnets.public.ids[0]
}

# Glue Connection to RDS
resource "aws_glue_connection" "rds_connection" {
  name = "rds-mysql-connection"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:mysql://${aws_db_instance.logs_db.endpoint}/${aws_db_instance.logs_db.db_name}"
    USERNAME            = jsondecode(aws_secretsmanager_secret_version.rds_credentials.secret_string)["username"]
    PASSWORD            = jsondecode(aws_secretsmanager_secret_version.rds_credentials.secret_string)["password"]
  }

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.public_subnet.availability_zone
    security_group_id_list = [aws_security_group.glue_sg.id]
    subnet_id              = data.aws_subnets.public.ids[0]
  }
}

# Glue ETL Job
resource "aws_glue_job" "logs_etl" {
  name     = "logs_etl_job"
  role_arn = aws_iam_role.glue_role.arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.log_data.bucket}/scripts/gluetl.py"
  }

  connections = [aws_glue_connection.rds_connection.name]

  default_arguments = {
    "--job-language"             = "python"
    "--class"                    = "GlueApp"
    "--TempDir"                  = "s3://${aws_s3_bucket.log_data.bucket}/temp/"
    "--enable-metrics"           = "true"
    "--CONNECTION_NAME"          = aws_glue_connection.rds_connection.name
    "--S3_INPUT_PATH"            = "s3://${aws_s3_bucket.log_data.bucket}/raw/dns_log_file.txt"
  }

  max_retries      = 0
  timeout          = 10
  glue_version     = "5.0"
  worker_type      = "G.1X"
  number_of_workers = 5
  
  security_configuration = aws_glue_security_configuration.glue_security_config.name
}

# Glue Security Configuration
resource "aws_glue_security_configuration" "glue_security_config" {
  name = "glue_security_configuration"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "DISABLED"
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "DISABLED"
    }
    
    s3_encryption {
      s3_encryption_mode = "DISABLED"
    }
  }
}

# Lambda role
resource "aws_iam_role" "lambda_role" {
  name = "logs_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda basic execution role
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda VPC execution role
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Lambda access Secrets Manager
resource "aws_iam_policy" "lambda_access_policy" {
  name        = "lambda_access_policy"
  description = "Allow Lambda to access RDS and Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.rds_credentials.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_access" {
  role       = aws_iam_role.lambda_role.id
  policy_arn = aws_iam_policy.lambda_access_policy.arn
}

# Lambda security group
resource "aws_security_group" "lambda_sg" {
  name        = "lambda_security_group"
  description = "Security group for Lambda"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Lambda function
resource "aws_lambda_function" "logs_api" {
  function_name = "logs_api_function"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = 10
  memory_size   = 128

  filename      = "lambda_deployment.zip" 
  source_code_hash = filebase64sha256("lambda_deployment.zip")

  environment {
    variables = {
      DB_HOST     = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["host"]
      DB_NAME     = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["dbname"]
      DB_PASSWORD = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["password"]
      DB_USER     = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["username"]
    }
  }

  vpc_config {
    subnet_ids         = [data.aws_subnets.public.ids[0]]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
}

# Geo Data Enhancement Lambda function
resource "aws_lambda_function" "geo_data_enhancement" {
  function_name = "geo_data_enhancement_function"
  role          = aws_iam_role.lambda_role.arn
  handler       = "geo_data_enhancement.lambda_handler"
  runtime       = "python3.9"
  timeout       = 60
  memory_size   = 256

  filename      = "lambda_function2.zip" 
  source_code_hash = filebase64sha256("lambda_function2.zip")

  environment {
    variables = {
      DB_HOST     = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["host"]
      DB_NAME     = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["dbname"]
      DB_PASSWORD = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["password"]
      DB_USER     = jsondecode(data.aws_secretsmanager_secret_version.current.secret_string)["username"]
    }
  }

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
}

# EventBridge rule to trigger Lambda after Glue job completion
resource "aws_cloudwatch_event_rule" "glue_job_completion" {
  name        = "glue-job-completion-rule"
  description = "Trigger geo enhancement Lambda after Glue job completion"

  event_pattern = jsonencode({
    source      = ["aws.glue"],
    detail-type = ["Glue Job State Change"],
    detail = {
      jobName = [aws_glue_job.logs_etl.name],
      state   = ["SUCCEEDED"]
    }
  })
}

# EventBridge target to invoke Lambda
resource "aws_cloudwatch_event_target" "geo_enhancement" {
  rule      = aws_cloudwatch_event_rule.glue_job_completion.name
  target_id = "GeoDataEnhancementLambda"
  arn       = aws_lambda_function.geo_data_enhancement.arn
}

# Lambda permission to allow EventBridge to invoke the function
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.geo_data_enhancement.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.glue_job_completion.arn
}

# Add Glue job monitoring permissions to Lambda role
resource "aws_iam_role_policy_attachment" "lambda_glue_monitoring" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# API Gateway
resource "aws_api_gateway_rest_api" "logs_api" {
  name        = "logs_analysis_api"
  description = "API for logs analysis"
}

# API Gateway resource
resource "aws_api_gateway_resource" "logs" {
  rest_api_id = aws_api_gateway_rest_api.logs_api.id
  parent_id   = aws_api_gateway_rest_api.logs_api.root_resource_id
  path_part   = "logs"
}

# API Gateway method
resource "aws_api_gateway_method" "logs_get" {
  rest_api_id      = aws_api_gateway_rest_api.logs_api.id
  resource_id      = aws_api_gateway_resource.logs.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.querystring.interval" = false
  }
}

# API Gateway execution role
resource "aws_iam_role" "api_gateway_role" {
  name = "api_gateway_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

# Policy to allow API Gateway to invoke Lambda
resource "aws_iam_role_policy" "api_gateway_lambda_policy" {
  name = "api_gateway_lambda_policy"
  role = aws_iam_role.api_gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "lambda:InvokeFunction"
        ]
        Effect   = "Allow"
        Resource = aws_lambda_function.logs_api.arn
      }
    ]
  })
}

# API Gateway integration with Lambda
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.logs_api.id
  resource_id             = aws_api_gateway_resource.logs.id
  http_method             = aws_api_gateway_method.logs_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.logs_api.invoke_arn
  credentials             = aws_iam_role.api_gateway_role.arn
}

# API Gateway method response
resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.logs_api.id
  resource_id = aws_api_gateway_resource.logs.id
  http_method = aws_api_gateway_method.logs_get.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

# API Gateway deployment
resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda_integration,
  ]

  rest_api_id = aws_api_gateway_rest_api.logs_api.id
  stage_name  = "prod"
}

# API Key for Basic Auth
resource "aws_api_gateway_api_key" "logs_api_key" {
  name = "logs_api_key"
}

# Usage plan for API key
resource "aws_api_gateway_usage_plan" "basic" {
  name         = "basic_usage_plan"
  description  = "Basic usage plan for logs API"

  api_stages {
    api_id = aws_api_gateway_rest_api.logs_api.id
    stage  = aws_api_gateway_deployment.deployment.stage_name
  }

  throttle_settings {
    burst_limit = 10
    rate_limit  = 5
  }
}

# Connect API key to usage plan
resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.logs_api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.basic.id
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.logs_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn = "${aws_api_gateway_rest_api.logs_api.execution_arn}/*/*"
}

# Output the API endpoint and key
output "api_endpoint" {
  value = "${aws_api_gateway_deployment.deployment.invoke_url}/logs"
}

output "api_key" {
  value       = aws_api_gateway_api_key.logs_api_key.value
  sensitive   = true
  description = "API Key for Basic Authentication"
}

# Outputs
output "s3_bucket_name" {
  value = aws_s3_bucket.log_data.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.logs_db.endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.logs_api.function_name
}

output "glue_job_name" {
  value = aws_glue_job.logs_etl.name
}

output "secrets_manager_arn" {
  value = aws_secretsmanager_secret.rds_credentials.arn
}

output "glue_connection_name" {
  value = aws_glue_connection.rds_connection.name
}

# S3 bucket lifecycle rule
resource "aws_s3_bucket_lifecycle_configuration" "log_data" {
  bucket = aws_s3_bucket.log_data.id

  rule {
    id     = "cleanup_old_data"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# Upload the Glue ETL script to S3
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.log_data.id
  key    = "scripts/gluetl.py"
  source = "${path.module}/gluetl.py"
  etag   = filemd5("${path.module}/gluetl.py")
}

# Create a sample DNS log file and upload it to S3
resource "aws_s3_object" "dns_log_file" {
  bucket = aws_s3_bucket.log_data.id
  key    = "raw/dns_log_file.txt"
  source = "${path.module}/dns_log_file.txt"
  etag   = filemd5("${path.module}/dns_log_file.txt")
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Create private subnets
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = data.aws_vpc.default.id
  cidr_block        = "172.31.${160 + (count.index * 16)}.0/20"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "Private Subnet ${count.index + 1}"
    Tier = "Private"
  }
}

# Create Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
}

# Create NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = slice(data.aws_subnets.public.ids, 0, 1)[0]

  tags = {
    Name = "Log Analysis NAT Gateway"
  }

  depends_on = [aws_eip.nat]
}

# Create route table for private subnets
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "Private Route Table"
  }
}

# Associate private subnets with the private route table
resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

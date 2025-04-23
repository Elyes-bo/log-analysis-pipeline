# Log Analysis Pipeline

Hi team! I've just finished implementing our DNS log analysis project. This README will guide you through setting up and testing the solution I've built.

## What This Does

Collects DNS log files, processes them, stores the data in MySQL, enriches it with geolocation data, and provides an API to query the results. Here's what I've built:

- Storage for DNS logs in S3
- ETL processing with AWS Glue
- Data storage in RDS MySQL (credentials managed in AWS Secrets Manager)
- Geolocation enrichment with Lambda
- API access through API Gateway
- Everything deployed with Terraform
- CI/CD pipeline with GitHub Actions
- Automated deployment package creation for Lambda functions

## Getting Started

### Prerequisites

- AWS CLI configured with proper access
- Terraform installed (I used v1.5.0)
- Python 3.9
- Git
- PowerBi

### Setup Instructions

1. **Clone the repo**
   ```
   git clone url
   cd log-analysis-pipeline
   ```

2. **Set up AWS credentials**
   
   You'll need to set these environment variables, & actions secrets:
   ```
   export AWS_ACCESS_KEY_ID=your_access_key
   export AWS_SECRET_ACCESS_KEY=your_secret_key
   export AWS_REGION=eu-central-1
   ```

3. **Deploy the infrastructure**
   ```
   cd iac
   terraform init
   terraform apply
   ```

4. **Get RDS credentials from Secrets Manager**
   
   The RDS credentials are stored in AWS Secrets Manager. You can retrieve them using:
   ```
   aws secretsmanager get-secret-value --secret-id rds/logs-db-credentials
   ```

5. **Connect to the database**
   ```
   mysql -h logs-db.czcooiosc04i.eu-central-1.rds.amazonaws.com -u admin -p logs_database
   ```

6. **Create the required table**
   ```sql
   CREATE TABLE logs (
       id INT NOT NULL AUTO_INCREMENT,
       datetime DATETIME DEFAULT NULL,
       geography VARCHAR(255) DEFAULT NULL,
       method VARCHAR(10) DEFAULT NULL,
       client_ip VARCHAR(45) DEFAULT NULL,
       url_request TEXT DEFAULT NULL,
       latitude DOUBLE DEFAULT NULL,
       longitude DOUBLE DEFAULT NULL,
       PRIMARY KEY (id),
       KEY idx_datetime (datetime),
       KEY idx_geography (geography),
       KEY idx_method (method),
       KEY idx_client_ip (client_ip)
   );
   ```

7. **Launch the Glue job**
   The Glue job will automatically trigger the geo-enhancement Lambda upon completion.

8. **Get the API key**
   
   After deployment completes, Terraform will output the API endpoint and API key. Save these for later.
   ```
   terraform output api_key
   terraform output api_endpoint
   ```

9. **Test the API**
   
   Try calling the API with the key:
   ```
   curl -H "x-api-key: YOUR_API_KEY" https://your-api-endpoint/prod/logs?interval=daily
   ```

## How to Test

Run the automated tests:
```
cd tests
pip install -r requirements.txt
pytest
```

## How It Works

### Data Flow

1. DNS logs are uploaded to S3 bucket
2. Glue job parses the logs and loads them into MySQL
3. After Glue job completes, EventBridge triggers the geo-enrichment Lambda
4. Lambda adds geolocation data to the logs
5. API Gateway + Lambda provide query access to the processed data

### File Structure

- `iac/main.tf` - Terraform infrastructure definition
- `iac/gluetl.py` - ETL script for processing logs
- `iac/lambda_function.py` - API endpoint Lambda
- `iac/geo_data_enhancement.py` - Geo enrichment Lambda
- `.github/workflows/main.yml` - CI/CD pipeline
- `tests/` - Test suite for the application


### logs
- Lambda function logs: CloudWatch Logs under /aws/lambda/logs-api-function
- Glue job logs: CloudWatch Logs under /aws-glue/jobs
- API Gateway logs: CloudWatch Logs under API-Gateway-Execution-Logs
- RDS performance insights: Available in RDS console
- Secrets Manager audit logs: CloudTrail

### CI CD

The project uses GitHub Actions for continuous integration and deployment. The workflow is defined in `.github/workflows/main.yml` and is automatically triggered when code is pushed to the main branch.

#### What the Workflow Does

1. **Test Phase**
   - Runs on Ubuntu latest
   - Sets up Python 3.9 environment
   - Installs project dependencies from requirements.txt
   - Runs pytest suite with mock database credentials
   - Must pass before deployment can proceed

2. **Deploy Phase**
   - Runs only after successful tests
   - Sets up Python 3.9 environment
   - Installs dependencies including AWS CLI
   - Configures AWS credentials from GitHub Secrets
   - Updates Lambda function code with new deployment package

#### How to Launch the Workflow

1. **Prerequisites**
   - GitHub repository with the project code
   - AWS credentials configured as GitHub Secrets:
     * `AWS_ACCESS_KEY_ID`
     * `AWS_SECRET_ACCESS_KEY`
     * `AWS_REGION`

2. **Automatic Trigger**
   - The workflow runs automatically when code is pushed to the main branch
   - No manual intervention required

3. **Monitoring**
   - View workflow progress in the "Actions" tab
   - Check test results and deployment status
   - View detailed logs for each step

#### Workflow Security

- AWS credentials are stored as GitHub Secrets
- Tests run with mock credentials
- Deployment only occurs after successful tests
- Access to AWS resources is controlled by IAM roles

###AWS Resources Created by Terraform Configuration
=============================================

S3 Resources:
------------
- Bucket: log-analysis-data-bucket
- Bucket Ownership Controls: log-analysis-data-bucket
- Bucket ACL: log-analysis-data-bucket (private)
- Lifecycle Configuration: log-analysis-data-bucket (30-day expiration)

RDS Resources:
-------------
- DB Instance: logs-db
  * Instance Class: db.t3.micro (compatible with MySQL 8.0)
  * Engine: MySQL 8.0
  * Database Name: logs_database
  * Publicly Accessible: Yes
  * Storage: 20 GB gp2
  * Backup Retention: 0 days (minimized)
  * Multi-AZ: No (single AZ)
  * Encryption: Disabled
- DB Subnet Group: logs-db-subnet-group
- Security Group: rds_security_group

Secrets Manager:
--------------
- Secret: rds/logs-db-credentials
- Secret Version: Contains DB credentials

Glue Resources:
-------------
- Database: logs_catalog

- Connection: rds-mysql-connection
- Job: logs_etl_job
  * Worker Type: G.1X
  * Number of Workers: 5
  * Timeout: 10 minutes
  * Retries: 0
  * Glue Version: 5.0
- Security Group: glue_security_group
- IAM Role: glue_etl_role
- IAM Policy: glue_access_policy

Lambda Resources:
---------------
- Function: logs_api_function
  * Runtime: Python 3.9
  * Handler: lambda_function.lambda_handler
  * Memory: 128 MB (minimum)
  * Timeout: 10 seconds
  * Functionality: Query log counts by hour/day/week
- Function: geo_data_enhancement_function
  * Runtime: Python 3.9
  * Handler: geo_data_enhancement.lambda_handler
  * Memory: 256 MB
  * Timeout: 60 seconds
  * Functionality: Enrich logs with geolocation data
- Security Group: lambda_security_group
- IAM Role: logs_lambda_role
- IAM Policy: lambda_access_policy

API Gateway Resources:
-------------------
- REST API: logs_analysis_api
- Resource: /logs
- Method: GET
- Integration: Lambda integration
- Deployment: prod stage
- API Key: logs_api_key
- Usage Plan: basic_usage_plan
  * Burst Limit: 10
  * Rate Limit: 5

VPC Resources:
------------
- Using Default VPC
- Public Subnets (from Default VPC)
- Private Subnets (2)
- NAT Gateway
- Route Tables
- VPC Endpoints:
  * S3 Gateway Endpoint

EventBridge Resources:
-------------------
- Rule: glue-job-completion-rule
- Target: geo_data_enhancement_function

Note: All resources are created in eu-central-1 region 
# Log Analysis Pipeline

This project implements a data pipeline for analyzing log data using AWS services. The pipeline includes data ingestion, storage, processing, and serving layers.

## Architecture

The architecture consists of the following components:

1. **Data Storage**:
   - S3 bucket for storing raw log data
   - RDS MySQL database for structured data storage

2. **Data Processing**:
   - AWS Glue for ETL operations
   - Extracts data from S3 and loads it into RDS

3. **Data Serving**:
   - Lambda function for querying log data
   - API Gateway for exposing the Lambda function
   - API Key authentication for secure access

## Prerequisites

- AWS Account with appropriate permissions
- Terraform installed
- Python 3.9+ for Lambda function
- PowerShell for building Lambda package

## Setup Instructions

1. **Configure AWS Credentials**:
   ```
   aws configure
   ```

2. **Initialize Terraform**:
   ```
   terraform init
   ```

3. **Create terraform.tfvars**:
   Create a file named `terraform.tfvars` with the following content:
   ```
   db_username = "admin"
   db_password = "xAGl_rsd-24"
   ```

4. **Build Lambda Package**:
   ```
   .\build_lambda.ps1
   ```

5. **Apply Terraform Configuration**:
   ```
   terraform apply
   ```

6. **Upload Log Data**:
   Upload your log data to the S3 bucket created by Terraform.

7. **Run Glue ETL Job**:
   Run the Glue ETL job to process the log data.

## API Usage

The API provides endpoints to query log data by time period (hourly, daily, or weekly).

### Endpoint

```
GET /logs
```

### Request Body

```json
{
  "time_unit": "daily"  // Options: "hourly", "daily", "weekly"
}
```

### Response

```json
{
  "time_unit": "daily",
  "results": [
    {
      "time_period": "2023-01-01",
      "count": 150
    },
    {
      "time_period": "2023-01-02",
      "count": 200
    }
  ]
}
```

### Authentication

The API requires an API key for authentication. Include the API key in the `x-api-key` header.

## Resources

See `resources.txt` for a complete list of AWS resources created by this project.

## Cost Optimization

This project is designed to minimize costs:
- RDS uses t3.micro instance (free tier eligible)
- Lambda uses minimum memory (128MB)
- Glue uses minimum capacity (1)
- S3 has lifecycle rules to delete old data
- RDS has backup retention set to 0

## License

MIT


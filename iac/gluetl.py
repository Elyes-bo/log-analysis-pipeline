import sys

from awsglue.transforms import *

from awsglue.utils import getResolvedOptions

from pyspark.context import SparkContext

from awsglue.context import GlueContext

from pyspark.sql import SparkSession

from pyspark.sql.functions import regexp_extract, to_timestamp, col, when, lit

from awsglue.job import Job



# Initialize Glue context and job

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'CONNECTION_NAME', 'S3_INPUT_PATH'])

sc = SparkContext()

glueContext = GlueContext(sc)

spark = glueContext.spark_session

job = Job(glueContext)

job.init(args['JOB_NAME'], args)



# Get parameters

connection_name = "jdbc:mysql://logs-db.czcooiosc04i.eu-central-1.rds.amazonaws.com:3306/logs_database"

s3_input_path = args['S3_INPUT_PATH']

table_name = "logs" # Or pass this as a job parameter if you prefer




# Get the JDBC URL from the connection
# Format: jdbc:mysql://hostname:port/database
jdbc_url = "jdbc:mysql://logs-db.czcooiosc04i.eu-central-1.rds.amazonaws.com:3306/logs_database"

db_user = "admin"  
db_password = "xAGl_rsd-24"  

# Add debug logging for connection
print(f"Attempting to connect to database with URL: {jdbc_url}")
print(f"Using username: {db_user}")



# Extract: Read logs from S3

# Read all lines initially

logs_data = spark.read.text(s3_input_path)



# Transform: Parse DNS log entries

# We won't filter strictly here, but the regex will only match lines with the expected format.

# Lines that don't match will produce nulls for extracted fields.

parsed_logs = logs_data.select(

    # Extract Timestamp (Format: dd-MMM-yyyy HH:mm:ss.SSS)

    to_timestamp(

        regexp_extract('value', r'^(\d{2}-\w{3}-\d{4}\s\d{2}:\d{2}:\d{2}\.\d{3})', 1),

        'dd-MMM-yyyy HH:mm:ss.SSS'

    ).alias('datetime'),



    # Extract Client IP

    regexp_extract('value', r'client\s+(\S+)#', 1).alias('client_ip'),



    # Extract Query Name (Map to url_request)

    regexp_extract('value', r'query:\s+(\S+)\s+IN', 1).alias('url_request'),



    # Extract Query Type (Map to method)

    regexp_extract('value', r'query:\s+\S+\s+(?:IN|view\s+\S+\s+IN)?\s+(\w+)', 1).alias('method'),



    # Geography is not available in this log format - explicitly add a null column

    lit(None).cast("string").alias("geography")

)



# Clean up potentially empty strings from regex non-matches to ensure they become NULL

# Also filter out any records where essential fields like datetime or client_ip failed parsing

cleaned_and_filtered_logs = parsed_logs.withColumn("client_ip", when(col("client_ip") == "", None).otherwise(col("client_ip"))) \
    .withColumn("url_request", when(col("url_request") == "", None).otherwise(col("url_request"))) \
    .withColumn("method", when(col("method") == "", None).otherwise(col("method"))) \
    .filter(col("datetime").isNotNull())  # Keep only records with valid datetime, regardless of other fields


# Select columns matching the target table
# Make sure the column names match your DB table EXACTLY (case sensitivity might matter depending on OS/DB config)
output_df = cleaned_and_filtered_logs.select(
    col("datetime"),
    col("geography"),
    col("method"),
    col("client_ip"),
    col("url_request")
)

# Print a sample of the transformed data for debugging
print("Sample of transformed data:")
output_df.show(5, truncate=False)
print(f"Schema of data being written:")
output_df.printSchema()
count = output_df.count()
print(f"Total valid log entries to be written: {count}")

# Load: Write to RDS MySQL

# Construct connection properties using retrieved credentials
connection_properties = {
    "user": db_user,
    "password": db_password,
    "driver": "com.mysql.cj.jdbc.Driver"  # Ensure you have the MySQL JDBC driver in your Glue job's libraries
}

if count > 0:
    try:
        print(f"Attempting to write {count} records to database: {jdbc_url}")
        print(f"Table: {table_name}")

        output_df.write \
            .jdbc(url=jdbc_url,
                  table=table_name,
                  mode="append",  # Use "overwrite" if you want to replace existing data
                  properties=connection_properties)

        print("Successfully wrote data to RDS")
    except Exception as e:
        print(f"Error writing to database: {str(e)}")
        import traceback
        traceback.print_exc()
        raise
else:
    print("No valid log entries found to write to the database.")

job.commit()
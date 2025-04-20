import json
import pymysql
import os
import datetime

# Database configuration
DB_HOST = os.environ['DB_HOST']
DB_USER = os.environ['DB_USER']
DB_PASSWORD = os.environ['DB_PASSWORD']
DB_NAME = os.environ['DB_NAME']

# Initialize database connection
def connect_to_db():
    try:
        conn = pymysql.connect(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME
        )
        return conn
    except Exception as e:
        print(f"Error connecting to database: {e}")
        return None

def lambda_handler(event, context):
    # Get the interval parameter (hourly, daily, weekly)
    interval = event.get('queryStringParameters', {}).get('interval', 'daily')
    
    # Connect to the database
    conn = connect_to_db()
    if not conn:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Failed to connect to database'})
        }
    
    try:
        with conn.cursor() as cursor:
            # SQL query based on interval
            if interval == 'hourly':
                sql = """
                SELECT DATE_FORMAT(datetime, '%Y-%m-%d %H:00:00') as hour_interval, 
                       COUNT(*) as count 
                FROM logs 
                GROUP BY hour_interval 
                ORDER BY hour_interval
                """
            elif interval == 'weekly':
                sql = """
                SELECT DATE_FORMAT(datetime, '%Y-%u') as week_interval, 
                       MIN(DATE_FORMAT(datetime, '%Y-%m-%d')) as week_start,
                       COUNT(*) as count 
                FROM logs 
                GROUP BY week_interval 
                ORDER BY week_interval
                """
            else:  # default to daily
                sql = """
                SELECT DATE_FORMAT(datetime, '%Y-%m-%d') as day_interval, 
                       COUNT(*) as count 
                FROM logs 
                GROUP BY day_interval 
                ORDER BY day_interval
                """
            
            # Execute query
            cursor.execute(sql)
            results = cursor.fetchall()
            
            # Format results
            formatted_results = []
            for row in results:
                if interval == 'hourly':
                    formatted_results.append({
                        'interval': row[0],
                        'count': row[1]
                    })
                elif interval == 'weekly':
                    formatted_results.append({
                        'week': row[0],
                        'week_start': row[1],
                        'count': row[2]
                    })
                else:  # daily
                    formatted_results.append({
                        'date': row[0],
                        'count': row[1]
                    })
            
            # Return results
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json'
                },
                'body': json.dumps({
                    'interval_type': interval,
                    'results': formatted_results
                })
            }
    
    except Exception as e:
        print(f"Error executing query: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': f'Error executing query: {str(e)}'})
        }
    
    finally:
        conn.close()
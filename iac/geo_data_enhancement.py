import json
import pymysql
import os
import datetime
import requests

# Database configuration
DB_HOST = "logs-db.czcooiosc04i.eu-central-1.rds.amazonaws.com"
DB_USER = "admin"
DB_PASSWORD = "xAGl_rsd-24"
DB_NAME = "logs_database"

def get_geo_from_ip(ip):
    try:
        print(f"Fetching geo data for IP: {ip}")
        response = requests.get(f"https://ip-api.com/json/{ip}", timeout=5)
        print(f"API Response status: {response.status_code}")
        print(f"API Response content: {response.text}")
        
        if response.status_code == 200:
            data = response.json()
            if data['status'] == 'success':
                lat = float(data['lat'])
                lon = float(data['lon'])
                print(f"Successfully got coordinates: lat={lat}, lon={lon}")
                return (lat, lon)
            else:
                print(f"API returned unsuccessful status: {data.get('message', 'No message')}")
        else:
            print(f"API request failed with status code: {response.status_code}")
        return (None, None)
    except Exception as e:
        print(f"Error fetching geo data for IP {ip}: {str(e)}")
        return (None, None)

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
    conn = connect_to_db()
    if not conn:
        return
    
    try:
        cursor = conn.cursor()
        
        # Get distinct client IPs
        cursor.execute("SELECT DISTINCT client_ip FROM logs")
        client_ips = cursor.fetchall()
        
        # Process each IP
        for (ip,) in client_ips:
            if not ip:  # Skip if IP is None or empty
                continue
                
            lat, lon = get_geo_from_ip(ip)
            print(f" laaaattt : {lat} {lon} ")
            if lat is not None and lon is not None:
                # Update the logs table with geo data
                update_query = """
                    UPDATE logs 
                    SET latitude = %s, longitude = %s 
                    WHERE client_ip = %s
                """
                cursor.execute(update_query, (lat, lon, ip))
        
        conn.commit()
        print(f"Successfully processed {len(client_ips)} unique client IPs")
        
    except Exception as e:
        print(f"Error processing client IPs: {e}")
        conn.rollback()
    finally:
        cursor.close()
        conn.close()

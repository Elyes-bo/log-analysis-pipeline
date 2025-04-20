import pytest
from unittest.mock import patch, MagicMock
import sys
import os
import json

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
import lambda_function

@pytest.fixture
def mock_db_connection():
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor
    return mock_conn, mock_cursor

def test_lambda_handler_daily(mock_db_connection):
    # Setup
    mock_conn, mock_cursor = mock_db_connection
    mock_cursor.fetchall.return_value = [('2023-01-01', 100), ('2023-01-02', 150)]
    
    with patch('lambda_function.connect_to_db', return_value=mock_conn):
        # Execute
        event = {'queryStringParameters': {'interval': 'daily'}}
        result = lambda_function.lambda_handler(event, {})
        
        # Assert
        assert result['statusCode'] == 200
        body = json.loads(result['body'])
        assert body['interval_type'] == 'daily'
        assert len(body['results']) == 2
        assert body['results'][0]['date'] == '2023-01-01'
        assert body['results'][0]['count'] == 100

def test_lambda_handler_hourly(mock_db_connection):
    # Setup
    mock_conn, mock_cursor = mock_db_connection
    mock_cursor.fetchall.return_value = [('2023-01-01 01:00:00', 50), ('2023-01-01 02:00:00', 75)]
    
    with patch('lambda_function.connect_to_db', return_value=mock_conn):
        # Execute
        event = {'queryStringParameters': {'interval': 'hourly'}}
        result = lambda_function.lambda_handler(event, {})
        
        # Assert
        assert result['statusCode'] == 200
        body = json.loads(result['body'])
        assert body['interval_type'] == 'hourly'
        assert len(body['results']) == 2
        assert body['results'][0]['interval'] == '2023-01-01 01:00:00'
        assert body['results'][0]['count'] == 50

def test_lambda_handler_db_error():
    # Setup
    with patch('lambda_function.connect_to_db', return_value=None):
        # Execute
        event = {'queryStringParameters': {'interval': 'daily'}}
        result = lambda_function.lambda_handler(event, {})
        
        # Assert
        assert result['statusCode'] == 500
        body = json.loads(result['body'])
        assert 'error' in body
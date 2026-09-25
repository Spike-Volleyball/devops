-- Create development databases for all microservices
-- This script runs automatically when the PostgreSQL container is first created

-- Create databases
CREATE DATABASE auth;
CREATE DATABASE events;
CREATE DATABASE profiles;
CREATE DATABASE messages;
CREATE DATABASE clubs;
CREATE DATABASE notifications;
CREATE DATABASE social;
CREATE DATABASE payments;
CREATE DATABASE coaching;
CREATE DATABASE rewards;

-- Grant all privileges to volleyer_user on all databases
GRANT ALL PRIVILEGES ON DATABASE auth TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE events TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE profiles TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE messages TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE clubs TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE notifications TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE social TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE payments TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE coaching TO volleyer_user;
GRANT ALL PRIVILEGES ON DATABASE rewards TO volleyer_user;

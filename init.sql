CREATE DATABASE IF NOT EXISTS badgekit;
CREATE DATABASE IF NOT EXISTS badgekit_test;
CREATE DATABASE IF NOT EXISTS badgekit_web;
CREATE USER IF NOT EXISTS 'badges'@'%' IDENTIFIED WITH mysql_native_password BY 'badges';
GRANT ALL PRIVILEGES ON badgekit.* TO 'badges'@'%';
GRANT ALL PRIVILEGES ON badgekit_test.* TO 'badges'@'%';
CREATE USER IF NOT EXISTS 'badgekit'@'%' IDENTIFIED WITH mysql_native_password BY 'badgekit';
GRANT ALL PRIVILEGES ON badgekit_web.* TO 'badgekit'@'%';
-- les tests du front DROP/CREATE leur base :
GRANT CREATE, DROP ON *.* TO 'badgekit'@'%';
FLUSH PRIVILEGES;

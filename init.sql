CREATE DATABASE IF NOT EXISTS badgekit;
CREATE DATABASE IF NOT EXISTS badgekit_test;
CREATE DATABASE IF NOT EXISTS badgekit_web;
CREATE DATABASE IF NOT EXISTS badgekit_web_test;
CREATE USER IF NOT EXISTS 'badges'@'%' IDENTIFIED WITH mysql_native_password BY 'badges';
GRANT ALL PRIVILEGES ON badgekit.* TO 'badges'@'%';
GRANT ALL PRIVILEGES ON badgekit_test.* TO 'badges'@'%';
CREATE USER IF NOT EXISTS 'badgekit'@'%' IDENTIFIED WITH mysql_native_password BY 'badgekit';
GRANT ALL PRIVILEGES ON badgekit_web.* TO 'badgekit'@'%';
-- les tests du front DROP/CREATE leur base : le grant est au niveau base
-- (mysql.db), donc il survit au DROP/CREATE DATABASE fait par la suite —
-- MySQL ne révoque pas les privilèges au niveau base quand la base est
-- supprimée, et un GRANT ... ON db.* est valide même si `db` n'existe pas
-- encore au moment du GRANT.
GRANT ALL PRIVILEGES ON badgekit_web_test.* TO 'badgekit'@'%';
GRANT CREATE, DROP ON *.* TO 'badgekit'@'%';
FLUSH PRIVILEGES;

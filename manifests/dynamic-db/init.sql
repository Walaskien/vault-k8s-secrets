-- Runs once, on the first start of the demo Postgres, as the admin user.
-- Vault creates its short-lived users as members of app_readonly.
CREATE ROLE app_readonly NOLOGIN;

CREATE TABLE items (
  id   serial PRIMARY KEY,
  name text NOT NULL
);
INSERT INTO items (name) VALUES ('first'), ('second');

GRANT USAGE ON SCHEMA public TO app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;

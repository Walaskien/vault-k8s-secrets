# Extension: the identity that asks for short-lived Postgres credentials.
# Reading the creds path creates a new database user, so this is not a harmless read.
path "database/creds/app-ro" {
  capabilities = ["read"]
}

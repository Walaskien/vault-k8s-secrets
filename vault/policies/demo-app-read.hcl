# What External Secrets in namespace "demo" may do in Vault: read one secret.
# kv v2 keeps the payload under secret/data/..., so that is the path to name.
# No list, no write, no secret/metadata, nothing else in the mount.
path "secret/data/demo/app" {
  capabilities = ["read"]
}

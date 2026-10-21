#!/usr/bin/env bash
# Prints the master password from Secrets Manager.
# Usage: export DB_PASSWORD="$(scripts/get_password.sh)"
set -euo pipefail
cd "$(dirname "$0")/../terraform"
ARN="$(terraform output -raw master_secret_arn)"
aws secretsmanager get-secret-value --secret-id "$ARN" \
  --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])'
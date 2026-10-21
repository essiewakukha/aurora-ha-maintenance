#!/usr/bin/env bash
# Simulates the disruptive part of a maintenance window while the probe runs.
#
#   scripts/maintenance_event.sh pending    # list real pending maintenance actions
#   scripts/maintenance_event.sh apply      # apply them now instead of waiting for the window
#   scripts/maintenance_event.sh reboot     # reboot the writer (stand-in for patching it)
#   scripts/maintenance_event.sh failover   # planned failover to a replica (needs reader_count >= 1)
#
# With one instance, "reboot" = the outage the scenario worries about.
# With a replica, "failover" first, then patch the old writer, = the fix.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
CLUSTER="$(terraform output -raw cluster_id)"
WRITER="$(terraform output -raw writer_instance_id)"
REGION="$(terraform console <<< 'var.region' | tr -d '"')"
export AWS_REGION="$REGION"

stamp() { date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }

case "${1:-}" in
  pending)
    aws rds describe-pending-maintenance-actions \
      --filters "Name=db-cluster-id,Values=$CLUSTER" --output table
    ;;
  apply)
    ARNS=$(aws rds describe-pending-maintenance-actions \
      --filters "Name=db-cluster-id,Values=$CLUSTER" \
      --query 'PendingMaintenanceActions[].ResourceIdentifier' --output text)
    for arn in $ARNS; do
      for action in $(aws rds describe-pending-maintenance-actions --resource-identifier "$arn" \
          --query 'PendingMaintenanceActions[0].PendingMaintenanceActionDetails[].Action' --output text); do
        echo "$(stamp) applying $action to $arn"
        aws rds apply-pending-maintenance-action --resource-identifier "$arn" \
          --apply-action "$action" --opt-in-type immediate >/dev/null
      done
    done
    ;;
  reboot)
    echo "$(stamp) rebooting writer $WRITER"
    aws rds reboot-db-instance --db-instance-identifier "$WRITER" >/dev/null
    ;;
  failover)
    TARGET=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
      --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`false`].DBInstanceIdentifier | [0]' --output text)
    if [[ "$TARGET" == "None" || -z "$TARGET" ]]; then
      echo "No reader to fail over to. Set reader_count = 1 and terraform apply." >&2; exit 1
    fi
    echo "$(stamp) failing over $CLUSTER to $TARGET"
    aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER" \
      --target-db-instance-identifier "$TARGET" >/dev/null
    ;;
  *)
    sed -n '2,11p' "$0"; exit 1
    ;;
esac
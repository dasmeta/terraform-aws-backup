import hashlib
import logging
import os
import re
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import boto3


logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
FAILURE_LOOKBACK = timedelta(minutes=20)
ARCHIVE_RETRY_WINDOW = timedelta(days=7)


def event_point(event, account, vault, snapshot_pattern):
    if not isinstance(event, dict) or (
        event.get("source") != "aws.backup"
        or event.get("detail-type") != "Copy Job State Change"
        or event.get("account") != account
        or event.get("region") != os.environ["SOURCE_REGION"]
    ):
        return

    detail = event.get("detail")
    if not isinstance(detail, dict) or (
        detail.get("state") != "COMPLETED"
        or detail.get("resourceType") != "RDS"
        or detail.get("destinationBackupVaultArn") != vault
    ):
        return

    point = detail.get("destinationRecoveryPointArn")
    if not isinstance(point, str) or not snapshot_pattern.fullmatch(point):
        logger.warning("Ignoring completed copy with invalid destination recovery point")
        return
    return point


def forward(backup, vault_name, point, failed_job_id=None):
    token_input = f"{point}/{failed_job_id}" if failed_job_id else point
    metadata = backup.describe_recovery_point(BackupVaultName=vault_name, RecoveryPointArn=point)
    retention = metadata.get("Lifecycle", {}).get("DeleteAfterDays")
    if not isinstance(retention, int) or retention <= 0:
        raise ValueError("Intermediate recovery point lacks a finite retention")
    result = backup.start_copy_job(
        SourceBackupVaultName=vault_name,
        RecoveryPointArn=point,
        DestinationBackupVaultArn=os.environ["DESTINATION_VAULT_ARN"],
        IamRoleArn=os.environ["COPY_ROLE_ARN"],
        Lifecycle={"DeleteAfterDays": retention},
        IdempotencyToken=hashlib.sha256(token_input.encode()).hexdigest(),
    )
    logger.info("Requested DR copy %s for %s", result["CopyJobId"], point)
    return result["CopyJobId"]


def records(list_api, key, **filters):
    while True:
        page = list_api(MaxResults=1000, **filters)
        yield from page[key]
        if not page.get("NextToken"):
            return
        filters["NextToken"] = page["NextToken"]


def forward_jobs(backup, vault, snapshot_pattern, **filters):
    destination = os.environ["DESTINATION_VAULT_ARN"]
    for job in records(backup.list_copy_jobs, "CopyJobs", ByResourceType="RDS",
                       ByDestinationVaultArn=destination, **filters):
        arn = job.get("SourceRecoveryPointArn")
        if (job.get("ResourceType") == "RDS" and job.get("SourceBackupVaultArn") == vault
                and job.get("DestinationBackupVaultArn") == destination
                and isinstance(arn, str) and snapshot_pattern.fullmatch(arn)):
            yield job


def emit_metric(region, name, value, unit):
    boto3.client("cloudwatch", region_name=region).put_metric_data(
        Namespace="Dasmeta/BackupDr",
        MetricData=[{
            "MetricName": name, "Value": value, "Unit": unit,
            "Dimensions": [{"Name": "BackupPath", "Value": "RdsIntermediate"}],
        }],
    )


def reconcile(backup, vault, vault_name, snapshot_pattern, region):
    created = {}
    latest = {}
    archive_points = {}
    now = datetime.now(timezone.utc)
    for point in records(backup.list_recovery_points_by_backup_vault, "RecoveryPoints",
                         BackupVaultName=vault_name, ByResourceType="RDS"):
        arn = point["RecoveryPointArn"]
        if (point["ResourceType"] != "RDS" or point["Status"] != "COMPLETED"
                or point["BackupVaultArn"] != vault or not snapshot_pattern.fullmatch(arn)):
            continue
        resource = point["ResourceArn"]
        created[arn] = point["CreationDate"]
        if (point.get("Lifecycle", {}).get("DeleteAfterDays", 0) > int(os.environ["RETENTION_DAYS"])
                and point["CreationDate"] >= now - ARCHIVE_RETRY_WINDOW):
            archive_points[arn] = resource
        candidate = (created[arn], arn)
        if resource not in latest or candidate > latest[resource]:
            latest[resource] = candidate
    jobs = defaultdict(list)
    if created:
        for job in forward_jobs(backup, vault, snapshot_pattern,
                                ByCreatedAfter=max(min(created.values()) - timedelta(seconds=1), now - ARCHIVE_RETRY_WINDOW)):
            arn = job["SourceRecoveryPointArn"]
            if arn in created:
                jobs[arn].append(job)

    copied = {arn for arn, attempts in jobs.items() if any(job["State"] == "COMPLETED" for job in attempts)}
    last_error = None
    candidates = {arn for _, arn in latest.values()} | set(archive_points)
    for arn in sorted(candidates):
        attempts = jobs[arn]
        if arn in copied or any(job["State"] in ("CREATED", "RUNNING") for job in attempts):
            continue
        # A terminal job consumed its original token. Concurrent reconcilers must agree on the retry token.
        failed = [job for job in attempts if job["State"] in ("FAILED", "PARTIAL")]
        failed_id = None
        if failed:
            failed_id = max(failed, key=lambda job: (job["CreationDate"], job["CopyJobId"]))["CopyJobId"]
        try:
            forward(backup, vault_name, arn, failed_id)
        except Exception as error:
            logger.exception("Could not request DR copy for %s", arn)
            last_error = error
    if copied:
        newest = max(created[arn] for arn in copied)
        age = (now - newest).total_seconds() / 60
        emit_metric(region, "RpoAgeMinutes", max(0, age), "None")
    recent_failures = {
        job["CopyJobId"] for job in forward_jobs(backup, vault, snapshot_pattern,
                                                 ByCompleteAfter=now - FAILURE_LOOKBACK, ByCompleteBefore=now)
        if job["State"] in ("FAILED", "PARTIAL")
    }
    if recent_failures:
        emit_metric(region, "ForwardCopyFailed", len(recent_failures), "Count")
    if last_error:
        raise last_error


def handler(event, context):
    vault = os.environ["INTERMEDIATE_VAULT_ARN"]
    _, partition, _, region, account, _, vault_name = vault.split(":")
    prefix = f"arn:{partition}:rds:{region}:{account}:snapshot:awsbackup:"
    snapshot_pattern = re.compile(re.escape(prefix) + r"[a-zA-Z0-9-]+")
    try:
        if event == {"mode": "reconcile"}:
            return reconcile(boto3.client("backup", region_name=region), vault, vault_name, snapshot_pattern, region)
        point = event_point(event, account, vault, snapshot_pattern)
        if point:
            return forward(boto3.client("backup", region_name=region), vault_name, point)
    except Exception:
        try:
            emit_metric(region, "ForwardCopyFailed", 1, "Count")
        except Exception:
            logger.exception("Could not publish the forward-copy failure metric")
        raise

import hashlib
import importlib.util
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch


VAULT = "arn:aws:backup:eu-west-1:111122223333:backup-vault:intermediate"
DR_VAULT = "arn:aws:backup:eu-west-1:444455556666:backup-vault:dr"
COPY_ROLE = "arn:aws:iam::111122223333:role/forward-copy"
POINT = "arn:aws:rds:eu-west-1:111122223333:snapshot:awsbackup:copy-abcd1234"
RESOURCE = "arn:aws:rds:eu-central-1:111122223333:db:example"
NOW = datetime(2026, 11, 18, 12, tzinfo=timezone.utc)


def point(arn=POINT, age=15, **overrides):
    return dict({
        "BackupVaultArn": VAULT, "RecoveryPointArn": arn, "ResourceArn": RESOURCE,
        "ResourceType": "RDS", "Status": "COMPLETED",
        "CreationDate": NOW - timedelta(minutes=age),
    }, **overrides)


def job(arn=POINT, state="COMPLETED", **overrides):
    return dict({
        "SourceRecoveryPointArn": arn, "SourceBackupVaultArn": VAULT,
        "DestinationBackupVaultArn": DR_VAULT, "State": state,
        "ResourceType": "RDS", "CopyJobId": "job-id", "CreationDate": NOW - timedelta(minutes=10),
        "CompletionDate": NOW - timedelta(minutes=1),
    }, **overrides)


def completed_event():
    return {
        "id": "first-delivery",
        "source": "aws.backup",
        "detail-type": "Copy Job State Change",
        "account": "111122223333",
        "region": "eu-central-1",
        "detail": {
            "state": "COMPLETED",
            "resourceType": "RDS",
            "destinationBackupVaultArn": VAULT,
            "destinationRecoveryPointArn": POINT,
        },
    }


class ForwardCopyTest(unittest.TestCase):
    def setUp(self):
        self.sdk = Mock()
        self.backup = Mock()
        self.cloudwatch = Mock()
        self.sdk.client.side_effect = lambda service, region_name: {
            "backup": self.backup, "cloudwatch": self.cloudwatch,
        }[service]
        self.backup.start_copy_job.return_value = {"CopyJobId": "copy-job"}
        self.backup.describe_recovery_point.return_value = {"Lifecycle": {"DeleteAfterDays": 1}}
        self.enterContext(patch.dict(os.environ, {
            "SOURCE_REGION": "eu-central-1",
            "INTERMEDIATE_VAULT_ARN": VAULT,
            "DESTINATION_VAULT_ARN": DR_VAULT,
            "COPY_ROLE_ARN": COPY_ROLE,
            "RETENTION_DAYS": "1",
        }))
        path = Path(__file__).resolve().parents[1] / "lambda" / "forward_copy.py"
        spec = importlib.util.spec_from_file_location("forward_copy", path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"boto3": self.sdk}):
            spec.loader.exec_module(module)
        self.handler = module.handler
        self.enterContext(patch.object(module, "datetime")).now.return_value = NOW

    def run_reconcile(self, points, jobs):
        self.backup.list_recovery_points_by_backup_vault.return_value = {"RecoveryPoints": points}

        def list_jobs(**filters):
            if "ByCompleteAfter" in filters:
                return {"CopyJobs": [job for job in jobs
                                     if filters["ByCompleteAfter"] < job["CompletionDate"] <= filters["ByCompleteBefore"]]}
            return {"CopyJobs": jobs}

        self.backup.list_copy_jobs.side_effect = list_jobs
        self.handler({"mode": "reconcile"}, None)

    def metric_values(self, name):
        values = []
        for call in self.cloudwatch.put_metric_data.call_args_list:
            self.assertEqual(call.kwargs["Namespace"], "Dasmeta/BackupDr")
            for metric in call.kwargs["MetricData"]:
                self.assertEqual(metric["Dimensions"], [{"Name": "BackupPath", "Value": "RdsIntermediate"}])
                if metric["MetricName"] == name:
                    values.append(metric["Value"])
        return values

    def test_completed_and_in_progress_jobs_are_skipped_and_rpo_uses_snapshot_time(self):
        self.run_reconcile(
            [point(age=67.5), point(POINT + "new", age=10), point(POINT + "older", age=99)],
            [job(), job(POINT + "new", "RUNNING"), job(POINT + "older")],
        )
        self.backup.start_copy_job.assert_not_called()
        self.assertEqual(self.metric_values("RpoAgeMinutes"), [67.5])

    def test_only_latest_missing_copy_is_submitted_and_matches_the_event_request(self):
        newest = POINT + "new"
        self.run_reconcile(
            [point(newest), point(POINT + "older", age=45), point(ResourceArn=RESOURCE + "2")],
            [job(), job(newest, DestinationBackupVaultArn=VAULT)],
        )
        self.backup.start_copy_job.assert_called_once()
        scheduled = self.backup.start_copy_job.call_args.kwargs
        self.assertEqual(scheduled["RecoveryPointArn"], newest)
        event = completed_event()
        event["detail"]["destinationRecoveryPointArn"] = newest
        self.handler(event, None)
        self.assertEqual(self.backup.start_copy_job.call_args.kwargs, scheduled)

    def test_pages_from_both_apis_and_deterministic_ties(self):
        self.backup.list_recovery_points_by_backup_vault.side_effect = [
            {"RecoveryPoints": [point(POINT + "a"), point(POINT + "x", ResourceArn=RESOURCE + "2")], "NextToken": "more-points"},
            {"RecoveryPoints": [point(POINT + "b"), point(age=50, ResourceArn=RESOURCE + "3")]},
        ]
        self.backup.list_copy_jobs.side_effect = [
            {"CopyJobs": [], "NextToken": "more-jobs"}, {"CopyJobs": [job()]},
            {"CopyJobs": [], "NextToken": "more-recent"}, {"CopyJobs": [job(state="FAILED")]},
        ]
        self.handler({"mode": "reconcile"}, None)
        job_calls = self.backup.list_copy_jobs.call_args_list
        for calls, token in [(self.backup.list_recovery_points_by_backup_vault.call_args_list, "more-points"),
                             (job_calls[:2], "more-jobs"), (job_calls[2:], "more-recent")]:
            first, second = [call.kwargs for call in calls]
            self.assertEqual(second, {**first, "NextToken": token})
            self.assertEqual(first["ByResourceType"], "RDS")
        self.assertEqual(job_calls[2].kwargs["ByCompleteAfter"], NOW - timedelta(minutes=20))
        self.assertEqual(job_calls[2].kwargs["ByCompleteBefore"], NOW)
        self.assertEqual(self.backup.list_copy_jobs.call_args.kwargs["ByDestinationVaultArn"], DR_VAULT)
        self.assertEqual(self.backup.list_recovery_points_by_backup_vault.call_args.kwargs["BackupVaultName"], "intermediate")
        self.assertEqual([c.kwargs["RecoveryPointArn"] for c in self.backup.start_copy_job.call_args_list],
                         [POINT + "b", POINT + "x"])
        self.assertEqual(self.metric_values("RpoAgeMinutes"), [50])
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

    def test_failed_and_unrelated_recovery_points_cannot_start_a_copy_or_contribute_rpo(self):
        self.run_reconcile([
            point(Status="PARTIAL"), point(Status="FAILED"), point(ResourceType="S3"),
            point(POINT.replace(":rds:", ":s3:")), point(POINT.replace("111122223333", "999999999999")),
            point(BackupVaultArn=DR_VAULT),
        ], [job()])
        self.backup.start_copy_job.assert_not_called()
        self.assertEqual(self.metric_values("RpoAgeMinutes"), [])

    def test_failed_dr_job_is_counted_and_retried_idempotently_after_its_last_attempt(self):
        self.run_reconcile([point()], [job(state="FAILED")])
        first = self.backup.start_copy_job.call_args.kwargs["IdempotencyToken"]
        self.assertNotEqual(first, hashlib.sha256(POINT.encode()).hexdigest())
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])
        self.run_reconcile([point()], [job(state="FAILED")])
        self.assertEqual(self.backup.start_copy_job.call_args.kwargs["IdempotencyToken"], first)

    def test_reports_recent_failure_even_when_the_successor_has_a_completed_dr_copy(self):
        newer = POINT + "new"
        self.run_reconcile(
            [point(age=75), point(newer, age=15)],
            [job(state="FAILED", CreationDate=NOW - timedelta(minutes=72),
                 CompletionDate=NOW - timedelta(minutes=17)), job(newer)],
        )
        self.backup.start_copy_job.assert_not_called()
        self.assertEqual(self.metric_values("RpoAgeMinutes"), [15])
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

    def test_stale_failure_can_be_retried_without_reopening_the_failure_alarm(self):
        self.run_reconcile([point(age=7 * 24 * 60)], [
            job(state="FAILED", CreationDate=NOW - timedelta(days=6), CompletionDate=NOW - timedelta(minutes=21)),
        ])
        self.backup.start_copy_job.assert_called_once()
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [])

    def test_recent_failures_are_scoped_to_the_path_even_after_the_source_point_expires(self):
        self.run_reconcile([], [
            job(state="PARTIAL", CopyJobId="failure"),
            job(state="FAILED", SourceBackupVaultArn=DR_VAULT, CopyJobId="other-source"),
            job(state="FAILED", DestinationBackupVaultArn=VAULT, CopyJobId="other-target"),
            job(state="FAILED", ResourceType="S3", CopyJobId="other-type"),
            job(POINT.replace(":rds:", ":s3:"), state="FAILED", CopyJobId="other-arn"),
        ])
        self.backup.start_copy_job.assert_not_called()
        self.assertEqual(self.metric_values("RpoAgeMinutes"), [])
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

    def test_list_failure_emits_failure_metric_and_propagates(self):
        self.backup.list_recovery_points_by_backup_vault.side_effect = RuntimeError("list failed")
        with self.assertRaisesRegex(RuntimeError, "list failed"):
            self.handler({"mode": "reconcile"}, None)
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

    def test_one_unavailable_point_does_not_prevent_other_missing_copies(self):
        self.backup.start_copy_job.side_effect = [RuntimeError("copy unavailable"), {"CopyJobId": "ok"}]
        with self.assertLogs("forward_copy", level="ERROR"), self.assertRaises(RuntimeError):
            self.run_reconcile([point(), point(POINT + "2", ResourceArn=RESOURCE + "2")], [])
        self.assertEqual(self.backup.start_copy_job.call_count, 2)
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

    def test_monitoring_outage_does_not_block_missing_copies(self):
        self.cloudwatch.put_metric_data.side_effect = RuntimeError("metrics unavailable")
        with self.assertLogs("forward_copy", level="ERROR"), self.assertRaisesRegex(RuntimeError, "metrics unavailable"):
            self.run_reconcile([point(), point(POINT + "2", ResourceArn=RESOURCE + "2")], [job()])
        self.backup.start_copy_job.assert_called_once()

    def test_submits_the_intermediate_snapshot_and_reuses_its_token_on_redelivery(self):
        event = completed_event()
        self.assertEqual(self.handler(event, None), "copy-job")
        self.sdk.client.assert_called_once_with("backup", region_name="eu-west-1")
        event["id"] = "redelivery"
        self.handler(event, None)
        expected = dict(
            SourceBackupVaultName="intermediate",
            RecoveryPointArn=POINT,
            DestinationBackupVaultArn=DR_VAULT,
            IamRoleArn=COPY_ROLE,
            Lifecycle={"DeleteAfterDays": 1},
            IdempotencyToken=hashlib.sha256(POINT.encode()).hexdigest(),
        )
        self.assertEqual([call.kwargs for call in self.backup.start_copy_job.call_args_list], [expected, expected])
        event["detail"]["destinationRecoveryPointArn"] += "2"
        self.handler(event, None)
        self.assertNotEqual(self.backup.start_copy_job.call_args.kwargs["IdempotencyToken"], expected["IdempotencyToken"])

    def test_ignores_unrelated_or_malformed_events(self):
        for field, value in [
            ("source", "other"), ("detail-type", "Backup Job State Change"),
            ("account", "444455556666"), ("region", "eu-west-1"), ("detail", None),
            ("detail", []), ("detail", {}),
        ]:
            with self.subTest(field=field, value=value):
                self.handler({**completed_event(), field: value}, None)
        for field, value in [
            ("state", "FAILED"), ("resourceType", "S3"), ("destinationBackupVaultArn", DR_VAULT),
            ("destinationRecoveryPointArn", {}), ("destinationRecoveryPointArn", None),
            ("destinationRecoveryPointArn", POINT.replace("eu-west-1", "eu-central-1")),
            ("destinationRecoveryPointArn", POINT.replace("111122223333", "444455556666")),
            ("destinationRecoveryPointArn", POINT.replace(":rds:", ":s3:")),
            ("destinationRecoveryPointArn", POINT.replace("snapshot:", "cluster-snapshot:")),
            ("destinationRecoveryPointArn", POINT.rsplit(":", 1)[0] + ":"),
            ("destinationRecoveryPointArn", POINT + " invalid"),
        ]:
            with self.subTest(field=field, value=value):
                event = completed_event()
                event["detail"][field] = value
                self.handler(event, None)
        for event in [None, [], {}, {"detail": "error"}]:
            self.handler(event, None)
        self.backup.start_copy_job.assert_not_called()

    def test_event_preserves_archive_retention(self):
        self.backup.describe_recovery_point.return_value = {"Lifecycle": {"DeleteAfterDays": 84}}
        self.handler(completed_event(), None)
        self.assertEqual(self.backup.start_copy_job.call_args.kwargs["Lifecycle"], {"DeleteAfterDays": 84})

    def test_reconcile_retries_missing_archive_even_if_newer_hourly_point_exists(self):
        archive = POINT + "archive"
        self.run_reconcile([point(), point(archive, age=2000, Lifecycle={"DeleteAfterDays": 84})], [job()])
        self.assertEqual(self.backup.start_copy_job.call_args.kwargs["RecoveryPointArn"], archive)

    def test_archived_point_already_copied_is_not_duplicated(self):
        archive = POINT + "archive"
        self.run_reconcile([point(), point(archive, age=2000, Lifecycle={"DeleteAfterDays": 84})], [job(), job(archive)])
        self.backup.start_copy_job.assert_not_called()

    def test_reconcile_does_not_recreate_old_archive_without_copy_job_history(self):
        archive = POINT + "archive"
        self.run_reconcile([point(), point(archive, age=8 * 24 * 60, Lifecycle={"DeleteAfterDays": 84})], [job()])
        self.backup.start_copy_job.assert_not_called()

    def test_missing_lifecycle_fails_without_creating_short_lived_copy(self):
        self.backup.describe_recovery_point.return_value = {}
        with self.assertRaisesRegex(ValueError, "finite retention"):
            self.handler(completed_event(), None)
        self.backup.start_copy_job.assert_not_called()
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

    def test_propagates_backup_failures_for_lambda_retry(self):
        self.backup.start_copy_job.side_effect = RuntimeError("temporarily unavailable")
        with self.assertRaisesRegex(RuntimeError, "temporarily unavailable"):
            self.handler(completed_event(), None)
        self.assertEqual(self.metric_values("ForwardCopyFailed"), [1])

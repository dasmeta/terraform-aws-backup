# Copy monitoring internal module

This module routes scoped AWS Backup copy failure events through CloudWatch Logs and a CloudWatch alarm to an existing SNS topic. When configured for a two-stage RDS path it also forwards intermediate copy failures and the existing RDS alarm transitions to the source Region. It is intended for use by this repository's backup modules, which derive its inputs from their existing settings.

AWS Backup events are best effort. The alarm may group multiple events while it is already in ALARM state. Confirm event delivery, topic policy, and SNS KMS permissions in the target account. A separate per-resource recovery-point age check and periodic restore tests are needed.

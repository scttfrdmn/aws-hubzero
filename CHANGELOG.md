# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-03-18

### Added
- Terraform implementation: EC2, optional RDS MariaDB 10.11, EBS DLM snapshots,
  IAM roles, Secrets Manager integration, SSM Session Manager access
- AWS CDK (TypeScript) implementation with feature parity to Terraform
- Three environments (test / staging / prod) with environment-specific instance
  types, storage, RDS sizing, backup retention, and deletion protection
- EC2 bootstrap script (`scripts/userdata.sh`) for Rocky Linux 8: Apache 2.4 +
  PHP-FPM 8.2, HubZero CMS v2.4 via Composer, optional MariaDB 10.11, optional
  Docker + Apache Solr 9.7
- On-premises migration script (`scripts/migrate.sh`) with SSH-based data
  transfer, database export/import, and Solr index rebuild
- On-premises migration guide (`docs/migration-guide.md`)
- Terraform state backend bootstrap script (`scripts/bootstrap-terraform-backend.sh`)
- GitHub Actions CI: Terraform fmt/validate, CDK TypeScript build and lint
- Apache 2.0 LICENSE
- Security hardening: IMDSv2 enforcement, fail2ban, HSTS + security headers,
  PHP hardening, Docker user namespace remapping, Composer integrity checks,
  encrypted EBS and RDS at rest, Secrets Manager for RDS credentials

[Unreleased]: https://github.com/scttfrdmn/aws-hubzero/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/scttfrdmn/aws-hubzero/releases/tag/v0.1.0

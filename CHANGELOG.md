# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Application-controller helpers for each authentication scope, including `authenticate_user!`, `current_user`, `current_user_account`, and `user_signed_in?`.
- Optional route scope names inferred from the model or identity, preserving model namespaces.
- Automatic route wrapper creation and duplicate scope detection in generators.

### Changed

- Generated account models now normalize email addresses and validate presence and case-insensitive uniqueness.

## [0.1.0] - 2026-09-21

### Added

- Initial release.

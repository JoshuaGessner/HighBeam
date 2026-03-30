# Changelog

All notable changes to the HighBeam project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Project initialization with full documentation structure
- Architecture docs: OVERVIEW.md, CLIENT.md, SERVER.md, PROTOCOL.md
- Version planning: VERSION_PLAN.md with roadmap through v1.0.0
- Reference docs: BEAMMP_RESEARCH.md, BEAMNG_MODDING.md
- Documentation index (INDEX.md) with usage instructions for developers and AI assistants
- Copilot instructions (.copilot-instructions.md)
- PR template, .gitignore, README.md, LICENSE
- BUILD_GUIDE.md — comprehensive 6-phase implementation blueprint with code examples
- Acceptance criteria for every milestone in VERSION_PLAN.md

### Changed
- Default port changed from 30814 to **18860** (1886 = Karl Benz's automobile patent)
- Default update rate changed from 30 Hz to **20 Hz** (research-backed; configurable)
- Networking model refined: state synchronization with priority accumulator, jitter buffer, snapshot interpolation, visual smoothing, and delta compression (documented in BUILD_GUIDE.md)

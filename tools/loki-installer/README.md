# Loki Installer V2

Rust implementation of the Loki Installer V2 contract in `docs/installer-v2/installer-contract.md`.

## What it includes

- Contract types for install requests, plans, manifests, sessions, and adapter events
- Manifest loading from repository `packs/`, `profiles/`, and `methods/`
- Planning logic with default inference and option validation
- CloudFormation and Terraform adapter stubs shared by CLI and TUI flows
- JSON session persistence for `resume` and `status`

## Commands

- `cargo run -- install --pack openclaw --profile builder --method cfn --yes --non-interactive`
- `cargo run -- plan --pack openclaw --profile builder --method terraform --yes --non-interactive`
- `cargo run -- doctor`
- `cargo run -- status --session <id>`
- `cargo run -- resume --session <id>`

## Testing

- `cargo check`
- `cargo test`

The integration tests exercise contract round-trips, manifest validation against repository YAML, session persistence, planner output, and CLI parsing.

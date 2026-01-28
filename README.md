# Gossip

A Dart monorepo for gossip-based data synchronization.

## Packages

- **gossip** - Core gossip protocol implementation
- **gossip_nearby** - Nearby Connections transport for peer discovery and messaging

## Development

This project uses [Melos](https://melos.invertase.dev/) to manage the monorepo.

### Setup

```bash
# Install dependencies and bootstrap the workspace
dart pub get
melos bootstrap
```

### Common Commands

```bash
# Run static analysis on all packages
melos run analyze

# Run tests in all packages
melos run test

# Format all packages
melos run format

# Check formatting without modifying files
melos run format:check
```

### Running Commands in Specific Packages

```bash
# Run a command in a specific package
melos exec --scope="gossip_nearby" -- flutter test

# Run a command in all packages
melos exec -- dart analyze .
```

# Custom NixOS Modules

This directory contains custom NixOS modules for system-level services and configurations.

## Structure

- `services/` - System service modules

## Usage

Import modules in your host configuration:

```nix
imports = [
  ../../modules/services/your-module.nix
];
```

Then configure the service:

```nix
services.your-service = {
  enable = true;
  # configuration options
};
```

## Adding New Modules

When creating new system-level modules:

1. Place service modules in `services/`
2. Place other system modules directly in `modules/`
3. Include documentation in the same directory
4. Follow NixOS module conventions with options and config sections
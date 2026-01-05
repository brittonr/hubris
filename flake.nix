{
  description = "Hubris - Embedded OS for ARM Cortex-M microcontrollers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    # Humility debugger - using local path for development
    # For production, change to: humility.url = "github:oxidecomputer/humility";
    humility = {
      url = "path:/home/brittonr/git/humility";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    crane,
    flake-utils,
    humility,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [rust-overlay.overlays.default];
      };

      # Read toolchain from rust-toolchain.toml
      hubrisToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

      # Override crane to use our custom toolchain
      craneLib = (crane.mkLib pkgs).overrideToolchain (_: hubrisToolchain);

      # Common build inputs for Hubris development
      commonBuildInputs = with pkgs;
        [
          pkg-config
          libusb1
          libftdi1
        ]
        ++ lib.optionals stdenv.isLinux [
          udev
        ];

      # Debug and flash tools
      debugTools = with pkgs; [
        # Use regular gdb - it has multi-arch support built in on most systems
        # For dedicated ARM debugging, use: pkgsCross.arm-embedded.buildPackages.gdb
        gdb
        openocd
        probe-rs-tools
      ];

      # Fake rustup wrapper that just returns paths to Nix-provided tools
      # This is needed because Hubris's call_rustfmt crate uses `rustup which rustfmt`
      fakeRustup = pkgs.writeShellScriptBin "rustup" ''
        if [ "$1" = "which" ] && [ "$2" = "rustfmt" ]; then
          echo "${hubrisToolchain}/bin/rustfmt"
        else
          echo "rustup shim: unsupported command: $@" >&2
          exit 1
        fi
      '';

      # Fake git wrapper that returns a fixed commit hash for Nix builds
      # This is needed because xtask calls `git rev-parse HEAD` and `git diff-index`
      # to record the git status in the build archive
      fakeGit = pkgs.writeShellScriptBin "git" ''
        if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
          echo "nix-build-0000000000000000000000000000000000000000"
        elif [ "$1" = "diff-index" ]; then
          # Return success (0) to indicate clean tree
          exit 0
        else
          echo "git shim: unsupported command: $@" >&2
          exit 1
        fi
      '';

      # Clean source for Nix builds (exclude build artifacts, etc.)
      hubrisSrc = pkgs.lib.cleanSourceWith {
        src = ./.;
        filter = path: type: let
          baseName = baseNameOf path;
          # Exclude common build artifacts and IDE files
          excluded = [
            "target"
            ".git"
            "result"
            ".direnv"
          ];
        in
          !(builtins.elem baseName excluded);
      };

      # Common args for crane builds
      commonCraneArgs = {
        src = hubrisSrc;
        strictDeps = true;

        nativeBuildInputs = with pkgs; [
          pkg-config
        ];

        buildInputs =
          commonBuildInputs
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
      };

      # Vendor all cargo dependencies (including git sources) for offline builds
      cargoVendorDir = craneLib.vendorCargoDeps {
        src = hubrisSrc;
      };

      # Build cargo dependencies separately for caching
      cargoArtifacts = craneLib.buildDepsOnly (commonCraneArgs
        // {
          pname = "hubris-deps";
          # Build xtask deps first since that's our main entry point
          cargoExtraArgs = "-p xtask";
        });

      # Build xtask binary
      hubris-xtask = craneLib.buildPackage (commonCraneArgs
        // {
          inherit cargoArtifacts;
          pname = "xtask";
          cargoExtraArgs = "-p xtask";
        });

      # Humility debugger - uses stable Rust
      humilityCraneLib = crane.mkLib pkgs;
      humilityVendorDir = humilityCraneLib.vendorCargoDeps {
        src = humility;
      };
      humilityPackage = humilityCraneLib.buildPackage {
        pname = "humility";
        version = "0.0.0";
        src = humility;
        strictDeps = true;

        cargoExtraArgs = "-p humility-bin";

        nativeBuildInputs = with pkgs; [
          pkg-config
          cmake
        ];

        buildInputs = with pkgs;
          [
            libusb1
            libftdi1
            hidapi
          ]
          ++ lib.optionals stdenv.isLinux [
            udev
          ]
          ++ lib.optionals stdenv.isDarwin [
            darwin.apple_sdk.frameworks.Security
            darwin.apple_sdk.frameworks.SystemConfiguration
            darwin.apple_sdk.frameworks.IOKit
            darwin.apple_sdk.frameworks.AppKit
          ];

        # Override cargoVendorDir with our vendored dependencies
        cargoVendorDir = humilityVendorDir;
      };


      # Function to build a Hubris image from an app.toml
      mkHubrisImage = {
        appToml,
        name ? builtins.replaceStrings ["/"] ["-"] (pkgs.lib.removePrefix "app/" (pkgs.lib.removeSuffix "/app.toml" (pkgs.lib.removeSuffix ".toml" appToml))),
        version ? "0.1.0",
      }:
        pkgs.stdenv.mkDerivation {
          pname = "hubris-${name}";
          inherit version;

          src = hubrisSrc;

          nativeBuildInputs = [
            hubrisToolchain
            fakeRustup
            fakeGit
            pkgs.pkg-config
          ];

          buildInputs = commonBuildInputs;

          # Disable default phases
          dontConfigure = true;
          dontFixup = true;

          # The source is copied read-only, need to make it writable
          postUnpack = ''
            chmod -R u+w source
          '';

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export CARGO_HOME=$TMPDIR/cargo
            mkdir -p $CARGO_HOME

            # Append crane's vendoring config to the project's .cargo/config.toml
            cat ${cargoVendorDir}/config.toml >> .cargo/config.toml

            # Debug: show final cargo config
            echo "=== Final .cargo/config.toml ==="
            cat .cargo/config.toml
            echo "==================================="

            # Override git version info since we don't have .git in the sandbox
            export HUBRIS_CABOOSE_VERS="nix-${version}"

            # Run the dist build
            cargo xtask dist ${appToml}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out

            # Find and copy the build artifacts
            find target -name "*.zip" -path "*/dist/*" -exec cp {} $out/ \;
            find target -name "final.elf" -path "*/dist/*" -exec cp {} $out/ \;
            find target -name "final.bin" -path "*/dist/*" -exec cp {} $out/ \;

            runHook postInstall
          '';
        };
    in {
      packages = {
        default = self.packages.${system}.demo-stm32f4-discovery;

        # xtask build tool
        xtask = hubris-xtask;

        # Demo images
        demo-stm32f4-discovery = mkHubrisImage {
          appToml = "app/demo-stm32f4-discovery/app.toml";
        };

        demo-stm32h7-nucleo-h743 = mkHubrisImage {
          appToml = "app/demo-stm32h7-nucleo/app-h743.toml";
        };

        demo-stm32h7-nucleo-h753 = mkHubrisImage {
          appToml = "app/demo-stm32h7-nucleo/app-h753.toml";
        };

        lpc55xpresso = mkHubrisImage {
          appToml = "app/lpc55xpresso/app.toml";
        };

        # Humility debugger
        humility = humilityPackage;
      };

      devShells.default = craneLib.devShell {
        # Include cargo artifacts for faster rebuilds
        inputsFrom = [hubris-xtask];

        packages =
          [
            hubrisToolchain
            humilityPackage
          ]
          ++ commonBuildInputs
          ++ debugTools;

        # Environment setup
        PKG_CONFIG_PATH = pkgs.lib.makeSearchPath "lib/pkgconfig" [
          pkgs.libusb1.dev
          pkgs.libftdi1
        ];

        shellHook = ''
          echo "Hubris development environment"
          echo "Rust: $(rustc --version)"
          echo "Humility: $(humility --version 2>/dev/null || echo 'available')"
          echo ""
          echo "Available commands:"
          echo "  cargo xtask dist <app.toml>    - Build a distribution image"
          echo "  cargo xtask build <app.toml>   - Build single task(s)"
          echo "  cargo xtask flash <app.toml>   - Flash to hardware"
          echo "  cargo xtask clippy <app.toml>  - Run clippy"
          echo "  humility -a <archive> <cmd>    - Debug/inspect running Hubris"
          echo ""
          echo "Example:"
          echo "  cargo xtask dist app/demo-stm32f4-discovery/app.toml"
          echo "  cargo xtask flash app/demo-stm32f4-discovery/app.toml"
        '';
      };

      # Formatter for nix files
      formatter = pkgs.alejandra;
    });
}

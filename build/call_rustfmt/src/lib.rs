// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

use anyhow::{bail, Result};
use std::path::Path;
use std::process::Command;

/// Rewrites a file in-place using rustfmt.
///
/// Rustfmt likes to rewrite files in-place. If this concerns you, copy your
/// important file to a temporary file, and then call this on it.
pub fn rustfmt(path: impl AsRef<Path>) -> Result<()> {
    // Try to find rustfmt: first check PATH directly (works with Nix),
    // then fall back to rustup if available.
    let rustfmt_path = find_rustfmt()?;

    println!("will invoke: {rustfmt_path}");

    let fmt_status = Command::new(&rustfmt_path).arg(path.as_ref()).status()?;
    if !fmt_status.success() {
        bail!("rustfmt returned status {fmt_status}");
    }
    Ok(())
}

fn find_rustfmt() -> Result<String> {
    // First, try rustfmt directly from PATH (works in Nix environments)
    if let Ok(output) = Command::new("which").arg("rustfmt").output() {
        if output.status.success() {
            let path = std::str::from_utf8(&output.stdout)?.trim();
            if !path.is_empty() {
                return Ok(path.to_string());
            }
        }
    }

    // Fall back to rustup if available
    if let Ok(which_out) = Command::new("rustup").args(["which", "rustfmt"]).output() {
        if which_out.status.success() {
            let path = std::str::from_utf8(&which_out.stdout)?.trim();
            if !path.is_empty() {
                return Ok(path.to_string());
            }
        }
    }

    bail!("could not find rustfmt: neither 'which rustfmt' nor 'rustup which rustfmt' succeeded")
}

#!/bin/bash
set -e

rm -rf /root/tendril_src
sudo rm -f /usr/bin/tendril
hash -r

echo "󰴈 Breeding the Pruning Tendril (v2.4.0)..."

WORKSPACE="/root/tendril_src"
mkdir -p "$WORKSPACE/src"
cd "$WORKSPACE"
a
cat > Cargo.toml << 'EOF'
[package]
name = "tendril"
version = "2.4.0"
edition = "2021"

[dependencies]
clap = { version = "4.4", features = ["derive"] }
alpm = "5.0.2"
libc = "0.2"
EOF

cat > src/main.rs << 'EOF'
use clap::{Parser, Subcommand};
use alpm::{Alpm, SigLevel};
use std::process::{Command, Stdio};

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Grab { packages: Vec<String> },
    Shed { packages: Vec<String> },
    Water,
    Search { query: String },
    Info { package: String },
    /// Find and remove unused dependencies (orphans)
    Prune,
}

fn is_root() -> bool {
    unsafe { libc::getuid() == 0 }
}

fn main() {
    if !is_root() {
        println!("󰴈 \x1b[1;31mPermission Denied:\x1b[0m You must be the gardener (root) to use Tendril.");
        println!("   Try: sudo tendril <command>");
        std::process::exit(1);
    }

    let cli = Cli::parse();
    let handle = Alpm::new("/", "/var/lib/pacman").expect("󰴈 Failed to open DB");

    match cli.command {
        Commands::Prune => {
            println!("󰴈 Inspecting the garden for dead leaves (orphans)...");
            
            // Use pacman quietly just to get the list of orphan names
            let output = Command::new("pacman").arg("-Qdtq").output().expect("Failed to query orphans");
            let stdout = String::from_utf8_lossy(&output.stdout);
            let orphans: Vec<&str> = stdout.lines().filter(|l| !l.is_empty()).collect();

            if orphans.is_empty() {
                println!("󰴈 Your garden is perfectly pruned. No orphans found.");
                return;
            }

            // Natively query the local DB to calculate disk space
            let localdb = handle.localdb();
            let mut total_size_mb = 0.0;

            for &orphan in &orphans {
                if let Ok(pkg) = localdb.pkg(orphan) {
                    let size = pkg.isize() as f64 / 1024.0 / 1024.0;
                    total_size_mb += size;
                    println!("󰴈 \x1b[1;31mDead Leaf:\x1b[0m {} v{} ({:.2} MB)", pkg.name(), pkg.version(), size);
                }
            }

            println!("󰴈 Found {} orphans consuming {:.2} MB of soil.", orphans.len(), total_size_mb);
            println!("󰴈 Uprooting...");

            // Pass control back to pacman without --noconfirm so the user gets the final [Y/n] safety check
            Command::new("pacman")
                .arg("-Rns")
                .args(&orphans)
                .status()
                .expect("Failed to uproot orphans");
        }

        Commands::Info { package } => {
            let repos = vec!["core", "extra"];
            let mut found = false;
            for repo in repos {
                if let Ok(db) = handle.register_syncdb(repo, SigLevel::USE_DEFAULT) {
                    if let Ok(pkg) = db.pkg(package.as_str()) {
                        let licenses: Vec<&str> = pkg.licenses().iter().collect();
                        println!("󰴈 \x1b[1;32mPackage:\x1b[0m      {}", pkg.name());
                        println!("󰴈 \x1b[1;32mVersion:\x1b[0m      {}", pkg.version());
                        println!("󰴈 \x1b[1;32mDescription:\x1b[0m  {}", pkg.desc().unwrap_or("No description"));
                        println!("󰴈 \x1b[1;32mURL:\x1b[0m          {}", pkg.url().unwrap_or("None"));
                        println!("󰴈 \x1b[1;32mLicense:\x1b[0m      {}", licenses.join(", "));
                        println!("󰴈 \x1b[1;32mInstall Size:\x1b[0m {:.2} MB", pkg.isize() as f64 / 1024.0 / 1024.0);
                        found = true;
                        break;
                    }
                }
            }
            if !found { println!("󰴈 Could not find details for '{}'.", package); }
        }

        Commands::Search { query } => {
            println!("󰴈 Searching the Arbor thicket for '{}'...", query);
            let repos = vec!["core", "extra"];
            for repo in repos {
                if let Ok(db) = handle.register_syncdb(repo, SigLevel::USE_DEFAULT) {
                    for pkg in db.pkgs() {
                        if pkg.name().contains(&query) || pkg.desc().map_or(false, |d| d.contains(&query)) {
                            println!("󰴈 \x1b[1;32m{}\x1b[0m - {}", pkg.name(), pkg.version());
                        }
                    }
                }
            }
        }

        Commands::Grab { packages } => {
            println!("󰴈 Planting {}...", packages.join(", "));
            Command::new("pacman").arg("-S").arg("--noconfirm").arg("--needed").args(packages)
                .stdout(Stdio::null()).status().expect("Failed");
            println!("󰴈 Done!");
        }

        Commands::Shed { packages } => {
            println!("󰴈 Shedding {}...", packages.join(", "));
            Command::new("pacman").arg("-Rns").arg("--noconfirm").args(packages)
                .stdout(Stdio::null()).status().expect("Failed");
            println!("󰴈 Uprooted.");
        }

        Commands::Water => {
            println!("󰴈 Watering the garden...");
            Command::new("pacman").arg("-Syu").arg("--noconfirm")
                .stdout(Stdio::null()).status().expect("Failed");
            println!("󰴈 Flourishing.");
        }
    }
}
EOF

cargo build --release
cp target/release/tendril /usr/bin/tendril
chmod +x /usr/bin/tendril
cd /root && rm -rf "$WORKSPACE"
hash -r

echo "------------------------------------------------"
echo "󰴈 Tendril v2.4.0 is ready. Try: sudo tendril prune"
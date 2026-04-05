#!/bin/bash
set -e

rm -rf /root/tendril_src
sudo rm -f /usr/bin/tendril
hash -r

echo "󰴈 Breeding the Pruning Tendril (v3.0.0)..."

WORKSPACE="/root/tendril_src"
mkdir -p "$WORKSPACE/src"
cd "$WORKSPACE"

cat > Cargo.toml << 'EOF'
[package]
name = "tendril"
version = "3.0.0"
edition = "2021"

[dependencies]
clap = { version = "4.4", features = ["derive"] }
alpm = "5.0.2"
libc = "0.2"
EOF

cat > src/main.rs << 'EOF'
use alpm::{Alpm, SigLevel, TransFlag};
use clap::{Parser, Subcommand};

// ─── Mirror & repo config ────────────────────────────────────────────────────
const MIRROR: &str = "https://london.mirror.pkgbuild.com";
const REPOS: &[&str] = &["core", "extra"];
const DB_PATH: &str = "/var/lib/pacman";
const ROOT: &str = "/";

// ─── CLI ─────────────────────────────────────────────────────────────────────
#[derive(Parser)]
#[command(name = "tendril", about = "󰴈 The Pruning Tendril — a pacman-free package manager")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Install packages
    Grab { packages: Vec<String> },
    /// Remove packages and their unneeded dependencies
    Shed { packages: Vec<String> },
    /// Sync databases and upgrade all packages
    Water,
    /// Sync package databases from mirror
    Sync,
    /// Search for a package by name or description
    Search { query: String },
    /// Show detailed info about a package
    Info { package: String },
    /// Remove orphaned packages (unused dependencies)
    Prune,
    /// List all installed packages
    List,
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
fn is_root() -> bool {
    unsafe { libc::getuid() == 0 }
}

/// Build an Alpm handle with all sync repos registered and their mirror URLs set.
fn make_handle() -> Alpm {
    let mut handle = Alpm::new(ROOT, DB_PATH).expect("󰴈 Failed to open pacman DB");
    for repo in REPOS {
        let mut db = handle
            .register_syncdb_mut(repo, SigLevel::NONE)
            .unwrap_or_else(|_| panic!("󰴈 Failed to register repo '{}'", repo));
        db.add_server(format!("{}/{}/os/x86_64", MIRROR, repo))
            .unwrap_or_else(|_| panic!("󰴈 Failed to add mirror for '{}'", repo));
    }
    handle
}

/// Print a pretty divider
fn divider() {
    println!("󰴈 ─────────────────────────────────────────");
}

// ─── Commands ────────────────────────────────────────────────────────────────

fn cmd_sync() {
    println!("󰴈 Syncing package databases...");
    let mut handle = make_handle();

    // Set download/progress callbacks so the user sees activity
    handle.set_dl_cb((), |_ctx, filename, event| {
        use alpm::AnyDownloadEvent;
        match event.as_any() {
            AnyDownloadEvent::Init(e) => {
                if e.optional() {
                    print!("  Checking {}... ", filename);
                } else {
                    print!("  Downloading {}... ", filename);
                }
            }
            AnyDownloadEvent::Completed(_) => println!("done"),
            _ => {}
        }
    });

    for mut db in handle.syncdbs_mut() {
        db.update(false)
            .unwrap_or_else(|e| panic!("󰴈 Failed to sync '{}': {}", db.name(), e));
    }
    println!("󰴈 Databases are up to date.");
}

fn cmd_grab(packages: Vec<String>) {
    if packages.is_empty() {
        println!("󰴈 No packages specified.");
        return;
    }
    println!("󰴈 Planting: {}", packages.join(", "));

    let mut handle = make_handle();

    // Wire up event + progress + download callbacks for visible output
    handle.set_event_cb((), |_ctx, event| {
        use alpm::AnyEvent;
        match event.as_any() {
            AnyEvent::PackageOperation(e) => {
                use alpm::PackageOperationEventType::*;
                let label = match e.event_type() {
                    Install => "Installing",
                    Upgrade => "Upgrading",
                    Reinstall => "Reinstalling",
                    Downgrade => "Downgrading",
                    Remove => "Removing",
                };
                println!(
                    "  {} {} {}...",
                    label,
                    e.new_pkg().name(),
                    e.new_pkg().version()
                );
            }
            _ => {}
        }
    });

    handle.set_dl_cb((), |_ctx, filename, event| {
        use alpm::AnyDownloadEvent;
        match event.as_any() {
            AnyDownloadEvent::Init(_) => print!("  Fetching {}... ", filename),
            AnyDownloadEvent::Completed(_) => println!("done"),
            _ => {}
        }
    });

    // Collect package structs from sync DBs
    handle.trans_init(TransFlag::NONE).expect("󰴈 Failed to init transaction");

    // We need to look packages up before borrowing handle for trans operations
    let mut to_add: Vec<alpm::Package> = Vec::new();
    for name in &packages {
        let mut found = false;
        for db in handle.syncdbs() {
            if let Ok(pkg) = db.pkg(name.as_str()) {
                to_add.push(pkg);
                found = true;
                break;
            }
        }
        if !found {
            println!("󰴈 \x1b[1;31mNot found:\x1b[0m '{}'", name);
        }
    }

    for pkg in to_add {
        handle.trans_add_pkg(pkg).expect("󰴈 Failed to add package to transaction");
    }

    handle.trans_prepare().expect("󰴈 Failed to prepare transaction");

    // Show what will be installed
    let add_list = handle.trans_add();
    if add_list.is_empty() {
        println!("󰴈 Nothing to do — all packages are already installed.");
        handle.trans_release().ok();
        return;
    }
    println!("󰴈 Packages to install:");
    for pkg in add_list {
        println!(
            "   \x1b[1;32m{}\x1b[0m {} ({:.2} MB)",
            pkg.name(),
            pkg.version(),
            pkg.download_size() as f64 / 1024.0 / 1024.0
        );
    }

    handle.trans_commit().expect("󰴈 Transaction failed");
    handle.trans_release().ok();
    divider();
    println!("󰴈 Done! Garden is flourishing.");
}

fn cmd_shed(packages: Vec<String>) {
    if packages.is_empty() {
        println!("󰴈 No packages specified.");
        return;
    }
    println!("󰴈 Shedding: {}", packages.join(", "));

    let mut handle = make_handle();

    handle.set_event_cb((), |_ctx, event| {
        use alpm::AnyEvent;
        if let AnyEvent::PackageOperation(e) = event.as_any() {
            if matches!(e.event_type(), alpm::PackageOperationEventType::Remove) {
                println!("  Removing {} {}...", e.old_pkg().name(), e.old_pkg().version());
            }
        }
    });

    handle
        .trans_init(TransFlag::RECURSE | TransFlag::UNNEEDED)
        .expect("󰴈 Failed to init transaction");

    let localdb = handle.localdb();
    for name in &packages {
        match localdb.pkg(name.as_str()) {
            Ok(pkg) => handle
                .trans_remove_pkg(pkg)
                .expect("󰴈 Failed to queue removal"),
            Err(_) => println!("󰴈 \x1b[1;33mNot installed:\x1b[0m '{}'", name),
        }
    }

    handle.trans_prepare().expect("󰴈 Failed to prepare transaction");

    let remove_list = handle.trans_remove();
    if remove_list.is_empty() {
        println!("󰴈 Nothing to remove.");
        handle.trans_release().ok();
        return;
    }
    println!("󰴈 Packages to remove:");
    for pkg in remove_list {
        println!("   \x1b[1;31m{}\x1b[0m {}", pkg.name(), pkg.version());
    }

    handle.trans_commit().expect("󰴈 Transaction failed");
    handle.trans_release().ok();
    divider();
    println!("󰴈 Uprooted.");
}

fn cmd_water() {
    println!("󰴈 Watering the garden (sync + full upgrade)...");
    cmd_sync();

    let mut handle = make_handle();

    handle.set_event_cb((), |_ctx, event| {
        use alpm::AnyEvent;
        if let AnyEvent::PackageOperation(e) = event.as_any() {
            use alpm::PackageOperationEventType::*;
            let label = match e.event_type() {
                Upgrade => "Upgrading",
                Install => "Installing",
                Reinstall => "Reinstalling",
                Downgrade => "Downgrading",
                Remove => "Removing",
            };
            println!(
                "  {} {} {} → {}...",
                label,
                e.new_pkg().name(),
                e.old_pkg().version(),
                e.new_pkg().version()
            );
        }
    });

    handle.set_dl_cb((), |_ctx, filename, event| {
        use alpm::AnyDownloadEvent;
        match event.as_any() {
            AnyDownloadEvent::Init(_) => print!("  Fetching {}... ", filename),
            AnyDownloadEvent::Completed(_) => println!("done"),
            _ => {}
        }
    });

    handle.trans_init(TransFlag::NONE).expect("󰴈 Failed to init transaction");
    handle.sync_sysupgrade(false).expect("󰴈 Failed to queue upgrades");
    handle.trans_prepare().expect("󰴈 Failed to prepare transaction");

    let upgrades = handle.trans_add();
    if upgrades.is_empty() {
        println!("󰴈 Everything is up to date. Garden is pristine.");
        handle.trans_release().ok();
        return;
    }
    println!("󰴈 {} package(s) to upgrade:", upgrades.len());

    handle.trans_commit().expect("󰴈 Transaction failed");
    handle.trans_release().ok();
    divider();
    println!("󰴈 Flourishing.");
}

fn cmd_search(query: String) {
    println!("󰴈 Searching for '{}'...", query);
    let handle = make_handle();
    let localdb = handle.localdb();
    let mut found = 0;

    for db in handle.syncdbs() {
        for pkg in db.pkgs() {
            let name_match = pkg.name().contains(&query);
            let desc_match = pkg.desc().map_or(false, |d| d.contains(&query));
            if name_match || desc_match {
                let installed = localdb.pkg(pkg.name()).is_ok();
                let tag = if installed {
                    "\x1b[1;34m[installed]\x1b[0m "
                } else {
                    ""
                };
                println!(
                    "  \x1b[1;32m{}\x1b[0m {} {}— {}",
                    pkg.name(),
                    pkg.version(),
                    tag,
                    pkg.desc().unwrap_or("no description")
                );
                found += 1;
            }
        }
    }

    if found == 0 {
        println!("󰴈 No packages found matching '{}'.", query);
    } else {
        println!("󰴈 Found {} result(s).", found);
    }
}

fn cmd_info(package: String) {
    let handle = make_handle();

    // Check sync DBs first
    for db in handle.syncdbs() {
        if let Ok(pkg) = db.pkg(package.as_str()) {
            let localdb = handle.localdb();
            let installed = localdb.pkg(package.as_str()).is_ok();
            let licenses: Vec<&str> = pkg.licenses().iter().collect();
            divider();
            println!("󰴈 \x1b[1;32mPackage:\x1b[0m      {}", pkg.name());
            println!("󰴈 \x1b[1;32mVersion:\x1b[0m      {}", pkg.version());
            println!("󰴈 \x1b[1;32mRepo:\x1b[0m         {}", db.name());
            println!(
                "󰴈 \x1b[1;32mDescription:\x1b[0m  {}",
                pkg.desc().unwrap_or("No description")
            );
            println!("󰴈 \x1b[1;32mURL:\x1b[0m          {}", pkg.url().unwrap_or("None"));
            println!("󰴈 \x1b[1;32mLicense:\x1b[0m      {}", licenses.join(", "));
            println!(
                "󰴈 \x1b[1;32mInstall Size:\x1b[0m {:.2} MB",
                pkg.isize() as f64 / 1024.0 / 1024.0
            );
            println!(
                "󰴈 \x1b[1;32mDownload Size:\x1b[0m {:.2} MB",
                pkg.download_size() as f64 / 1024.0 / 1024.0
            );
            let deps: Vec<&str> = pkg.depends().iter().map(|d| d.name()).collect();
            if !deps.is_empty() {
                println!("󰴈 \x1b[1;32mDepends On:\x1b[0m   {}", deps.join(", "));
            }
            println!(
                "󰴈 \x1b[1;32mInstalled:\x1b[0m    {}",
                if installed { "Yes" } else { "No" }
            );
            divider();
            return;
        }
    }

    // Fall back to local DB (installed but maybe not in sync DBs)
    let localdb = handle.localdb();
    if let Ok(pkg) = localdb.pkg(package.as_str()) {
        let licenses: Vec<&str> = pkg.licenses().iter().collect();
        divider();
        println!("󰴈 \x1b[1;32mPackage:\x1b[0m      {} (local only)", pkg.name());
        println!("󰴈 \x1b[1;32mVersion:\x1b[0m      {}", pkg.version());
        println!(
            "󰴈 \x1b[1;32mDescription:\x1b[0m  {}",
            pkg.desc().unwrap_or("No description")
        );
        println!("󰴈 \x1b[1;32mLicense:\x1b[0m      {}", licenses.join(", "));
        println!(
            "󰴈 \x1b[1;32mInstall Size:\x1b[0m {:.2} MB",
            pkg.isize() as f64 / 1024.0 / 1024.0
        );
        divider();
        return;
    }

    println!("󰴈 Package '{}' not found.", package);
}

fn cmd_prune() {
    println!("󰴈 Inspecting the garden for dead leaves (orphans)...");
    let mut handle = make_handle();
    let localdb = handle.localdb();

    // An orphan is: installed, not explicitly installed, and nothing depends on it
    let orphans: Vec<String> = localdb
        .pkgs()
        .iter()
        .filter(|pkg| {
            pkg.reason() == alpm::PackageReason::Depend
                && localdb
                    .pkgs()
                    .iter()
                    .all(|other| !other.depends().iter().any(|dep| dep.name() == pkg.name()))
        })
        .map(|pkg| {
            let size = pkg.isize() as f64 / 1024.0 / 1024.0;
            println!(
                "  \x1b[1;31mDead Leaf:\x1b[0m {} v{} ({:.2} MB)",
                pkg.name(),
                pkg.version(),
                size
            );
            pkg.name().to_string()
        })
        .collect();

    if orphans.is_empty() {
        println!("󰴈 Your garden is perfectly pruned. No orphans found.");
        return;
    }

    let total: f64 = orphans.iter().filter_map(|name| {
        localdb.pkg(name.as_str()).ok().map(|p| p.isize() as f64 / 1024.0 / 1024.0)
    }).sum();

    println!(
        "󰴈 Found {} orphan(s) consuming {:.2} MB of soil.",
        orphans.len(),
        total
    );

    // Confirm
    print!("󰴈 Uproot them? [y/N] ");
    use std::io::{self, BufRead, Write};
    io::stdout().flush().ok();
    let mut input = String::new();
    io::stdin().lock().read_line(&mut input).ok();
    if !input.trim().eq_ignore_ascii_case("y") {
        println!("󰴈 Aborted.");
        return;
    }

    handle.set_event_cb((), |_ctx, event| {
        use alpm::AnyEvent;
        if let AnyEvent::PackageOperation(e) = event.as_any() {
            if matches!(e.event_type(), alpm::PackageOperationEventType::Remove) {
                println!("  Removing {} {}...", e.old_pkg().name(), e.old_pkg().version());
            }
        }
    });

    handle
        .trans_init(TransFlag::RECURSE)
        .expect("󰴈 Failed to init transaction");

    let localdb = handle.localdb();
    for name in &orphans {
        if let Ok(pkg) = localdb.pkg(name.as_str()) {
            handle.trans_remove_pkg(pkg).expect("󰴈 Failed to queue removal");
        }
    }

    handle.trans_prepare().expect("󰴈 Failed to prepare transaction");
    handle.trans_commit().expect("󰴈 Transaction failed");
    handle.trans_release().ok();
    divider();
    println!("󰴈 Garden pruned.");
}

fn cmd_list() {
    let handle = Alpm::new(ROOT, DB_PATH).expect("󰴈 Failed to open DB");
    let localdb = handle.localdb();
    let mut pkgs: Vec<_> = localdb.pkgs().iter().collect();
    pkgs.sort_by(|a, b| a.name().cmp(b.name()));
    println!("󰴈 Installed packages ({}):", pkgs.len());
    for pkg in pkgs {
        println!("  \x1b[1;32m{}\x1b[0m {}", pkg.name(), pkg.version());
    }
}

// ─── Entry point ─────────────────────────────────────────────────────────────
fn main() {
    let cli = Cli::parse();

    // Commands that modify the system require root
    let needs_root = matches!(
        cli.command,
        Commands::Grab { .. }
            | Commands::Shed { .. }
            | Commands::Water
            | Commands::Sync
            | Commands::Prune
    );

    if needs_root && !is_root() {
        eprintln!("󰴈 \x1b[1;31mPermission Denied:\x1b[0m You must be the gardener (root) to use this command.");
        eprintln!("   Try: sudo tendril <command>");
        std::process::exit(1);
    }

    match cli.command {
        Commands::Grab { packages } => cmd_grab(packages),
        Commands::Shed { packages } => cmd_shed(packages),
        Commands::Water => cmd_water(),
        Commands::Sync => cmd_sync(),
        Commands::Search { query } => cmd_search(query),
        Commands::Info { package } => cmd_info(package),
        Commands::Prune => cmd_prune(),
        Commands::List => cmd_list(),
    }
}
EOF

cargo build --release
cp target/release/tendril /usr/bin/tendril
chmod +x /usr/bin/tendril
cd /root && rm -rf "$WORKSPACE"
hash -r

echo "------------------------------------------------"
echo "󰴈 Tendril v3.0.0 ready."
echo "   tendril sync           — sync package databases"
echo "   tendril grab <pkg>     — install packages"
echo "   tendril shed <pkg>     — remove packages"
echo "   tendril water          — sync + full upgrade"
echo "   tendril search <query> — search packages"
echo "   tendril info <pkg>     — package details"
echo "   tendril prune          — remove orphans"
echo "   tendril list           — list installed"

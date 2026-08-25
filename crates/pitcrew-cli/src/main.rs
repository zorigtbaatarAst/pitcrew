//! `pitcrew` — a config-driven local dev-stack launcher for multi-service monorepos.
//!
//! Phase 0 skeleton: argument surface only. Subcommands are implemented as their
//! phase lands (see the plan). Until then each one says so rather than doing
//! something surprising — errors never pass silently, including this one.

mod doctor;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "pitcrew",
    version,
    about = "A config-driven local dev-stack launcher for multi-service monorepos."
)]
struct Cli {
    /// Use the project rooted at this directory.
    #[arg(short = 'C', value_name = "DIR", global = true)]
    dir: Option<std::path::PathBuf>,

    /// Use a registered project by name.
    #[arg(short = 'p', value_name = "NAME", global = true)]
    project: Option<String>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// One-shot state of every component.
    Status {
        /// Emit the machine-readable state object instead of a table.
        #[arg(long)]
        json: bool,
    },
    /// Stream the state object, one JSON document per line.
    Json {
        /// Keep streaming rather than emitting one document.
        #[arg(long)]
        watch: bool,
        /// Seconds between documents.
        #[arg(long, default_value = "1")]
        interval: f64,
    },
    /// Is this environment able to run pitcrew?
    Doctor {
        #[arg(long)]
        json: bool,
    },
    /// Is this stack healthy right now?
    Diagnose {
        #[arg(long)]
        json: bool,
    },
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();

    let Some(command) = cli.command else {
        eprintln!("pitcrew: the dashboard is not ported yet (phase 5). Try --help.");
        return std::process::ExitCode::FAILURE;
    };

    match command {
        // The environment half only needs the platform layer, so it works now.
        // Its project-specific half arrives with the config model in phase 2,
        // and the report says so.
        Command::Doctor { json } => cmd_doctor(json),
        Command::Status { .. } | Command::Json { .. } | Command::Diagnose { .. } => {
            eprintln!("pitcrew: not ported yet — phase 4 (diagnostics and JSON output).");
            std::process::ExitCode::FAILURE
        }
    }
}

/// Exits non-zero when anything is wrong, so `doctor` can BE a CI gate rather
/// than needing one wrapped around it. That property is inherited from the bash
/// version and scripts already rely on it.
fn cmd_doctor(json: bool) -> std::process::ExitCode {
    let checks = doctor::run();
    let bad = checks.iter().any(|c| c.level == doctor::Level::Warn);

    if json {
        eprintln!("pitcrew: doctor --json is not ported yet — phase 4.");
        return std::process::ExitCode::FAILURE;
    }
    for check in &checks {
        let mark = match check.level {
            doctor::Level::Ok => "ok  ",
            doctor::Level::Warn => "warn",
        };
        println!("{mark}   {}", check.line);
    }
    if bad {
        std::process::ExitCode::FAILURE
    } else {
        std::process::ExitCode::SUCCESS
    }
}

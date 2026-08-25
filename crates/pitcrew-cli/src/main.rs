//! `pitcrew` — a config-driven local dev-stack launcher for multi-service monorepos.
//!
//! Phase 0 skeleton: argument surface only. Subcommands are implemented as their
//! phase lands (see the plan). Until then each one says so rather than doing
//! something surprising — errors never pass silently, including this one.

mod check;
mod doctor;
mod project;
mod report;
mod run;

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
    /// Start components. With no targets, starts everything.
    Start { targets: Vec<String> },
    /// Stop components. With no targets, stops everything.
    Stop { targets: Vec<String> },
    /// Stop then start.
    Restart { targets: Vec<String> },
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
    /// Load a config and report what is wrong with it.
    Check {
        /// A config file or a project directory. Defaults to walking up from here.
        target: Option<std::path::PathBuf>,
    },
    /// Every URL this project serves.
    Urls,
    /// Which port belongs to what, across every registered project.
    Ports,
    /// Projects pitcrew knows about.
    Projects,
    /// Each component's RAM cap, and where it came from.
    Limits,
    /// Saved sets of targets.
    Profile {
        #[command(subcommand)]
        action: Option<ProfileAction>,
    },
}

#[derive(Subcommand)]
enum ProfileAction {
    /// Show every profile and what it covers today.
    List,
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
        Command::Check { target } => cmd_check(
            target.as_deref().or(cli.dir.as_deref()),
            cli.project.as_deref(),
        ),
        Command::Urls => report::urls(cli.dir.as_deref(), cli.project.as_deref()),
        Command::Ports => report::ports(),
        Command::Projects => report::projects(),
        Command::Limits => report::caps(cli.dir.as_deref(), cli.project.as_deref()),
        Command::Profile { action } => match action {
            None | Some(ProfileAction::List) => {
                report::profiles(cli.dir.as_deref(), cli.project.as_deref())
            }
        },
        Command::Status { json } => {
            if json {
                eprintln!("pitcrew: status --json is not ported yet — phase 4.");
                return std::process::ExitCode::FAILURE;
            }
            run::status(cli.dir.as_deref(), cli.project.as_deref())
        }
        Command::Start { targets } => {
            run::start(cli.dir.as_deref(), cli.project.as_deref(), &targets)
        }
        Command::Stop { targets } => {
            run::stop(cli.dir.as_deref(), cli.project.as_deref(), &targets)
        }
        Command::Restart { targets } => {
            run::restart(cli.dir.as_deref(), cli.project.as_deref(), &targets)
        }
        Command::Json { .. } | Command::Diagnose { .. } => {
            eprintln!("pitcrew: not ported yet — phase 4 (diagnostics and JSON output).");
            std::process::ExitCode::FAILURE
        }
    }
}

/// Exits non-zero on anything worth a person's attention, so this works as a
/// pre-commit hook without a wrapper deciding what counts.
fn cmd_check(target: Option<&std::path::Path>, name: Option<&str>) -> std::process::ExitCode {
    match check::check(target, name) {
        check::Outcome::Clean(summary) => {
            println!("ok     {summary}");
            std::process::ExitCode::SUCCESS
        }
        check::Outcome::Warned { summary, warnings } => {
            println!("ok     {summary}");
            for w in &warnings {
                println!("warn   {w}");
            }
            std::process::ExitCode::FAILURE
        }
        check::Outcome::Refused(e) => {
            eprintln!("error  {e}");
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

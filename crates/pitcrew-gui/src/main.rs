//! `pitcrew-gui` — the desktop app.
//!
//! A renderer over the CLI's JSON contract, and nothing more. It never reads
//! `/proc`, never runs `ps`, and never decides for itself whether a stack is
//! healthy — see [`runner`] for why that boundary is load-bearing rather than
//! stylistic.

mod logview;
mod runner;
mod style;
mod views;
mod widgets;
mod window;

use adw::prelude::*;
use gtk::glib;

const APP_ID: &str = "mn.zb.PitcrewGui";

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).build();
    // Handled here rather than through clap: a desktop app is launched by a
    // double-click far more often than with arguments, and GTK owns argv.
    let project = std::env::args()
        .skip(1)
        .skip_while(|a| a != "-p" && a != "--project")
        .nth(1);

    // In `startup`, not before `run`: libadwaita refuses to answer any question
    // until GTK is initialized, and asking early is a panic rather than an
    // answer. This is the earliest point where the question is legal AND still
    // before any widget exists.
    let too_old = std::rc::Rc::new(std::cell::Cell::new(false));
    let flag = too_old.clone();
    app.connect_startup(move |_| {
        if let Err(why) = check_adwaita() {
            eprintln!("pitcrew-gui: {why}");
            flag.set(true);
            return;
        }
        style::load();
    });
    app.connect_activate(move |app| {
        // The version the app was BUILT against is not the one it runs against,
        // and a widget from a newer libadwaita does not raise — GTK ABORTS the
        // process. Saying so plainly beats a crash somebody has to bisect.
        if too_old.get() {
            app.quit();
            return;
        }
        let ui = window::build(app, project.clone());
        ui.window.present();
    });
    // GTK would otherwise try to parse our own flags and refuse them.
    app.run_with_args::<&str>(&[])
}

/// libadwaita 1.5 is the floor: what Ubuntu 24.04 LTS ships.
fn check_adwaita() -> Result<(), String> {
    let (major, minor) = (adw::major_version(), adw::minor_version());
    if (major, minor) < (1, 5) {
        return Err(format!(
            "needs libadwaita 1.5 or newer, found {major}.{minor} — \
             this is the version Ubuntu 24.04 LTS ships, and older ones abort \
             rather than degrade"
        ));
    }
    Ok(())
}

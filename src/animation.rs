//! Native progress and a short, rolling preview of the local transcription.

use gtk::prelude::*;

pub struct TranscribeAnimation {
    page: gtk::ScrolledWindow,
    stage: gtk::Label,
    progress: gtk::ProgressBar,
    lines: gtk::Box,
}

impl TranscribeAnimation {
    pub fn new() -> Self {
        let stage = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .wrap(true)
            .build();
        let status = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        status.append(&gtk::Spinner::builder().spinning(true).build());
        status.append(&stage);

        let progress = gtk::ProgressBar::builder().show_text(true).build();
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(18)
            .css_classes(["monitor-panel"])
            .build();
        panel.append(
            &gtk::Label::builder()
                .label("Preparing transcript")
                .xalign(0.0)
                .css_classes(["session-title"])
                .build(),
        );
        panel.append(&status);
        panel.append(&progress);

        let lines = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .build();
        let column = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(16)
            .margin_start(24)
            .margin_end(24)
            .margin_top(32)
            .margin_bottom(24)
            .build();
        column.append(&panel);
        column.append(&lines);
        let clamp = adw::Clamp::builder()
            .maximum_size(520)
            .child(&column)
            .build();
        let page = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&clamp)
            .build();
        Self {
            page,
            stage,
            progress,
            lines,
        }
    }

    pub fn widget(&self) -> &gtk::ScrolledWindow {
        &self.page
    }

    pub fn set_progress(&self, progress: f64) {
        self.progress.set_fraction(progress.clamp(0.0, 1.0));
    }

    pub fn set_stage(&self, stage: &str) {
        self.stage.set_label(stage);
    }

    pub fn push_text(&self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        if self.lines.observe_children().n_items() >= 3
            && let Some(oldest) = self.lines.first_child()
        {
            self.lines.remove(&oldest);
        }
        self.lines.append(
            &gtk::Label::builder()
                .label(line)
                .xalign(0.0)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .lines(3)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .css_classes(["preview-turn"])
                .build(),
        );
    }

    pub fn reset(&self) {
        self.set_progress(0.0);
        self.set_stage("");
        while let Some(line) = self.lines.first_child() {
            self.lines.remove(&line);
        }
    }
}

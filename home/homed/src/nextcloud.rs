use std::collections::HashSet;
use std::path::{Path, PathBuf};

use thiserror::Error;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::config::NextcloudConfig;
use crate::watcher::FileEvent;

#[derive(Debug, Error)]
pub enum NextcloudError {
    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),
}

/// Translates a host filesystem path to a Nextcloud internal path.
///
/// Example:
///   Host: /mnt/hot/nextcloud-data/admin/files/Photos/2026/2026-02/IMG_20260203_122134.jpg
///   Internal: /admin/files/Photos/2026/2026-02/IMG_20250203_122938.jpg
pub fn translate_path(host_path: &Path, config: &NextcloudConfig) -> Option<String> {
    let relative = host_path.strip_prefix(&config.data_dir).ok()?;
    let username_prefix = format!("{}/files/", config.username);
    let relative_str = relative.to_str()?;

    if let Some(stripped) = relative_str.strip_prefix(&username_prefix) {
        Some(format!("{}/{}", config.internal_prefix, stripped))
    } else {
        Some(format!("{}/{}", config.internal_prefix, relative_str))
    }
}

/// Runs `occ files:scan --path=<path>` via docker exec.
async fn run_occ_scan(config: &NextcloudConfig, path: &str) -> Result<(), NextcloudError> {
    let output = tokio::process::Command::new("docker")
        .args([
            "exec",
            "--user",
            "www-data",
            &config.container_name,
            "php",
            "occ",
            "files:scan",
        ])
        .arg(format!("--path={}", path))
        .output()
        .await?;

    if !output.status.success() {
        warn!(
            exit_code = ?output.status.code(),
            stderr = %String::from_utf8_lossy(&output.stderr),
            "occ files:scan failed"
        );
    }

    Ok(())
}

/// Scans multiple directories in Nextcloud after batch processing completes.
/// Deduplicates paths by using parent directories.
pub async fn scan_directories(config: &NextcloudConfig, paths: &HashSet<PathBuf>) {
    if !config.enabled || paths.is_empty() {
        return;
    }

    let mut internal_paths: HashSet<String> = HashSet::new();
    for path in paths {
        if let Some(internal) = translate_path(path, config) {
            internal_paths.insert(internal);
        }
    }

    info!(count = internal_paths.len(), "scanning directories in nextcloud");

    for path in &internal_paths {
        if let Err(e) = run_occ_scan(config, path).await {
            warn!(path = %path, error = %e, "nextcloud scan failed");
        }
    }
}

pub async fn run_nextcloud(
    _config: NextcloudConfig,
    mut rx: mpsc::Receiver<FileEvent>,
    tx: mpsc::Sender<FileEvent>,
    mut shutdown: tokio::sync::broadcast::Receiver<()>,
) -> Result<(), NextcloudError> {
    loop {
        let event = tokio::select! {
            Some(event) = rx.recv() => event,
            _ = shutdown.recv() => break,
            else => break,
        };
        let _ = tx.send(event).await;
    }

    Ok(())
}

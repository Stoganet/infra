use crate::config::AlertsConfig;
use tracing::warn;

pub async fn send_alert(
    client: &reqwest::Client,
    config: &AlertsConfig,
    message: &str,
) -> Result<(), reqwest::Error> {
    client
        .post(format!("{}/{}", config.url, config.topic))
        .bearer_auth(&config.token)
        .body(message.to_string())
        .send()
        .await?
        .error_for_status()?;

    Ok(())
}

pub async fn send_batch_alert(
    client: &reqwest::Client,
    config: &AlertsConfig,
    organized: usize,
    unsorted: usize,
    failed: &[(String, String)],
) {
    if !config.enabled {
        return;
    }

    if organized == 0 && unsorted == 0 && failed.is_empty() {
        return;
    }

    let mut parts = Vec::new();
    if organized > 0 {
        parts.push(format!("{} organized", organized));
    }
    if unsorted > 0 {
        parts.push(format!("{} unsorted", unsorted));
    }
    if !failed.is_empty() {
        parts.push(format!("{} failed", failed.len()));
    }

    let mut message = format!("Photos: {}", parts.join(", "));

    if !failed.is_empty() {
        message.push_str("\n\nErrors:");
        for (path, error) in failed.iter().take(5) {
            message.push_str(&format!("\n• {}: {}", path, error));
        }
        if failed.len() > 5 {
            message.push_str(&format!("\n… and {} more", failed.len() - 5));
        }
    }

    if let Err(e) = send_alert(client, config, &message).await {
        warn!(error = %e, "failed to send ntfy alert");
    }
}

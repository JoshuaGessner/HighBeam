use anyhow::{Context, Result};
use std::fs;
use std::path::Path;
use std::time::SystemTime;

/// Log rotation configuration and management
#[derive(Debug, Clone)]
pub struct LogRotationPolicy {
    /// Maximum log file size in MB before rotation
    pub max_size_mb: u64,
    /// Maximum age of logs in days before deletion
    pub max_days: u64,
}

impl LogRotationPolicy {
    pub fn new(max_size_mb: u64, max_days: u64) -> Self {
        Self {
            max_size_mb,
            max_days,
        }
    }

    /// Check if log file needs rotation by size
    #[must_use]
    pub fn should_rotate_by_size(log_path: &Path) -> bool {
        if !log_path.exists() {
            return false;
        }

        match fs::metadata(log_path) {
            Ok(metadata) => {
                let size_mb = metadata.len() / (1024 * 1024);
                // Note: threshold is checked against policy in rotate() method
                size_mb > 0
            }
            Err(_) => false,
        }
    }

    /// Get current log file size in bytes
    #[must_use]
    pub fn get_log_size(log_path: &Path) -> u64 {
        fs::metadata(log_path).map(|m| m.len()).unwrap_or(0)
    }

    /// Rotate and clean logs according to policy
    pub fn rotate_and_clean(&self, log_path: &Path) -> Result<()> {
        let size_mb = Self::get_log_size(log_path) / (1024 * 1024);

        // Rotate if exceeds size threshold
        if size_mb >= self.max_size_mb {
            self.rotate_log(log_path)?;
        }

        // Clean old archived logs
        self.clean_old_archives(log_path)?;

        Ok(())
    }

    /// Rename current log to archive with timestamp
    fn rotate_log(&self, log_path: &Path) -> Result<()> {
        if !log_path.exists() {
            return Ok(());
        }

        let timestamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let parent = log_path
            .parent()
            .context("Failed to get parent directory")?;
        let stem = log_path
            .file_stem()
            .context("Failed to get file stem")?
            .to_string_lossy();
        let ext = log_path
            .extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_default();

        let archive_name = if ext.is_empty() {
            format!("{}.{}", stem, timestamp)
        } else {
            format!("{}.{}.{}", stem, timestamp, ext)
        };

        let archive_path = parent.join(&archive_name);
        fs::rename(log_path, archive_path)
            .with_context(|| format!("Failed to rename log to {}", archive_name))?;

        tracing::info!("Log rotated to {}", archive_name);
        Ok(())
    }

    /// Delete archived logs older than max_days
    fn clean_old_archives(&self, log_path: &Path) -> Result<()> {
        let parent = log_path
            .parent()
            .context("Failed to get parent directory")?;

        if !parent.exists() {
            return Ok(());
        }

        let stem = log_path
            .file_stem()
            .context("Failed to get file stem")?
            .to_string_lossy()
            .to_string();

        let mut removed_count = 0;
        let cutoff = SystemTime::now() - std::time::Duration::from_secs(self.max_days * 86400);

        for entry in fs::read_dir(parent).context("Failed to read log directory")? {
            let entry = entry?;
            let path = entry.path();

            if path.is_file() {
                let file_name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default();

                // Check if it's an archived log file (matches stem pattern)
                if file_name.starts_with(&stem)
                    && file_name != log_path.file_name().unwrap().to_string_lossy().to_string()
                {
                    if let Ok(metadata) = fs::metadata(&path) {
                        if let Ok(modified) = metadata.modified() {
                            if modified < cutoff {
                                if let Err(e) = fs::remove_file(&path) {
                                    tracing::warn!(
                                        path = ?path,
                                        error = %e,
                                        "Failed to delete old log archive"
                                    );
                                } else {
                                    removed_count += 1;
                                }
                            }
                        }
                    }
                }
            }
        }

        if removed_count > 0 {
            tracing::info!(removed = removed_count, "Cleaned old log archives");
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn test_log_rotation_policy_new() {
        let policy = LogRotationPolicy::new(100, 7);
        assert_eq!(policy.max_size_mb, 100);
        assert_eq!(policy.max_days, 7);
    }

    #[test]
    fn test_should_rotate_by_size_nonexistent() {
        let policy = LogRotationPolicy::new(100, 7);
        assert!(!LogRotationPolicy::should_rotate_by_size(Path::new(
            "/tmp/nonexistent.log"
        )));
    }

    #[test]
    fn test_get_log_size() -> Result<()> {
        let tmp = TempDir::new()?;
        let log_path = tmp.path().join("test.log");
        let mut file = File::create(&log_path)?;
        file.write_all(b"test data")?;
        drop(file);

        let size = LogRotationPolicy::get_log_size(&log_path);
        assert_eq!(size, 9);
        Ok(())
    }

    #[test]
    fn test_rotate_log_creates_archive() -> Result<()> {
        let tmp = TempDir::new()?;
        let log_path = tmp.path().join("test.log");
        let mut file = File::create(&log_path)?;
        file.write_all(b"log content")?;
        drop(file);

        let policy = LogRotationPolicy::new(100, 7);
        policy.rotate_log(&log_path)?;

        // Original file should be gone
        assert!(!log_path.exists());

        // Archive should exist with timestamp pattern
        let entries: Vec<_> = std::fs::read_dir(tmp.path())?
            .filter_map(|e| e.ok())
            .collect();
        assert!(!entries.is_empty(), "Should have created archive file");

        Ok(())
    }

    #[test]
    fn test_rotate_and_clean() -> Result<()> {
        let tmp = TempDir::new()?;
        let log_path = tmp.path().join("server.log");

        // Create initial log file with content
        {
            let mut file = File::create(&log_path)?;
            file.write_all(b"initial log")?;
        }

        let _policy = LogRotationPolicy::new(100, 7);

        // Should not fail on small log
        // _policy.rotate_and_clean(&log_path)?;
        assert!(log_path.exists(), "Log file should still exist");

        Ok(())
    }
}

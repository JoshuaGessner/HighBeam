use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tokio::sync::RwLock;

/// Track attempts within a time window to throttle auth/chat/spawn.
#[derive(Clone, Debug)]
struct AttemptRecord {
    attempts: u32,
    window_start: SystemTime,
}

/// Rate limiter: tracks attempts per key (IP, player_id, etc) over rolling windows.
pub struct RateLimiter {
    // Map of key → (attempts, window_start)
    records: Arc<RwLock<HashMap<String, AttemptRecord>>>,
    window_duration: Duration,
    max_attempts: u32,
}

impl RateLimiter {
    /// Create a new rate limiter with the given window and max attempts.
    pub fn new(window_duration: Duration, max_attempts: u32) -> Self {
        Self {
            records: Arc::new(RwLock::new(HashMap::new())),
            window_duration,
            max_attempts,
        }
    }

    /// Check if an attempt should be allowed. Returns true if within limits, false if exceeded.
    pub async fn check_and_record(&self, key: &str) -> bool {
        let mut records = self.records.write().await;
        let now = SystemTime::now();

        if let Some(record) = records.get_mut(key) {
            // Check if the window has expired
            if let Ok(elapsed) = now.duration_since(record.window_start) {
                if elapsed > self.window_duration {
                    // Window expired, reset
                    record.attempts = 1;
                    record.window_start = now;
                    return true;
                }
            }

            // Within the same window
            if record.attempts >= self.max_attempts {
                return false; // Limit exceeded
            }

            record.attempts += 1;
            true
        } else {
            // First attempt
            records.insert(
                key.to_string(),
                AttemptRecord {
                    attempts: 1,
                    window_start: now,
                },
            );
            true
        }
    }

    /// Get current attempt count for a key (for diagnostics).
    pub async fn get_attempt_count(&self, key: &str) -> u32 {
        let records = self.records.read().await;
        records.get(key).map(|r| r.attempts).unwrap_or(0)
    }

    /// Clear all records (for testing or cache cleanup).
    pub async fn clear(&self) {
        self.records.write().await.clear();
    }

    /// Remove records whose window has expired to keep memory bounded.
    pub async fn prune_expired(&self) -> usize {
        let mut records = self.records.write().await;
        let before = records.len();
        let now = SystemTime::now();

        records.retain(|_, record| {
            now.duration_since(record.window_start)
                .map(|elapsed| elapsed <= self.window_duration)
                .unwrap_or(true)
        });

        before.saturating_sub(records.len())
    }
}

/// Specialized rate limiters for auth, chat, and vehicle spawn.
pub struct ServerRateLimiters {
    /// Auth attempts per IP (prevent brute force).
    pub auth_limiter: RateLimiter,
    /// Chat messages per player (prevent spam).
    pub chat_limiter: RateLimiter,
    /// Vehicle spawns per player (prevent lag).
    pub spawn_limiter: RateLimiter,
}

impl ServerRateLimiters {
    /// Create rate limiters with sensible defaults.
    pub fn new() -> Self {
        Self {
            // 5 auth attempts per 60 seconds per IP
            auth_limiter: RateLimiter::new(Duration::from_secs(60), 5),
            // 10 chat messages per 10 seconds per player
            chat_limiter: RateLimiter::new(Duration::from_secs(10), 10),
            // 5 vehicle spawns per 5 seconds per player
            spawn_limiter: RateLimiter::new(Duration::from_secs(5), 5),
        }
    }

    /// Check auth rate limit by IP address.
    pub async fn check_auth_limit(&self, addr: &std::net::SocketAddr) -> bool {
        let key = format!("auth:{}", addr.ip());
        self.auth_limiter.check_and_record(&key).await
    }

    /// Check chat rate limit by player_id.
    pub async fn check_chat_limit(&self, player_id: u32) -> bool {
        let key = format!("chat:{}", player_id);
        self.chat_limiter.check_and_record(&key).await
    }

    /// Check spawn rate limit by player_id.
    pub async fn check_spawn_limit(&self, player_id: u32) -> bool {
        let key = format!("spawn:{}", player_id);
        self.spawn_limiter.check_and_record(&key).await
    }

    pub async fn prune_expired(&self) -> usize {
        let auth = self.auth_limiter.prune_expired().await;
        let chat = self.chat_limiter.prune_expired().await;
        let spawn = self.spawn_limiter.prune_expired().await;
        auth + chat + spawn
    }
}

impl Default for ServerRateLimiters {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_rate_limiter_allows_under_limit() {
        let limiter = RateLimiter::new(Duration::from_secs(10), 3);
        assert!(limiter.check_and_record("test").await);
        assert!(limiter.check_and_record("test").await);
        assert!(limiter.check_and_record("test").await);
    }

    #[tokio::test]
    async fn test_rate_limiter_blocks_over_limit() {
        let limiter = RateLimiter::new(Duration::from_secs(10), 2);
        assert!(limiter.check_and_record("test").await);
        assert!(limiter.check_and_record("test").await);
        assert!(!limiter.check_and_record("test").await);
    }

    #[tokio::test]
    async fn test_rate_limiter_resets_after_window() {
        let limiter = RateLimiter::new(Duration::from_millis(100), 1);
        assert!(limiter.check_and_record("test").await);
        assert!(!limiter.check_and_record("test").await);

        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(limiter.check_and_record("test").await);
    }

    #[tokio::test]
    async fn test_independent_keys() {
        let limiter = RateLimiter::new(Duration::from_secs(10), 1);
        assert!(limiter.check_and_record("key1").await);
        assert!(!limiter.check_and_record("key1").await);
        assert!(limiter.check_and_record("key2").await);
    }

    #[tokio::test]
    async fn test_prune_expired_removes_old_records() {
        let limiter = RateLimiter::new(Duration::from_millis(50), 2);
        assert!(limiter.check_and_record("old").await);
        tokio::time::sleep(Duration::from_millis(75)).await;

        let removed = limiter.prune_expired().await;

        assert_eq!(removed, 1);
        assert_eq!(limiter.get_attempt_count("old").await, 0);
    }
}

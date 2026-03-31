use anyhow::Context;
use anyhow::Result;
use rustls_pemfile::{certs, private_key};
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::TlsAcceptor;

/// TLS configuration wrapper
#[derive(Debug, Clone)]
pub struct TlsConfig {
    pub cert_path: PathBuf,
    pub key_path: PathBuf,
    pub auto_generate: bool,
}

impl TlsConfig {
    pub fn new(cert_path: impl AsRef<Path>, key_path: impl AsRef<Path>) -> Self {
        Self {
            cert_path: cert_path.as_ref().into(),
            key_path: key_path.as_ref().into(),
            auto_generate: false,
        }
    }

    pub fn with_autogenerate(mut self, auto_generate: bool) -> Self {
        self.auto_generate = auto_generate;
        self
    }
}

/// Load TLS acceptor from configuration
pub fn load_or_generate_acceptor(config: &TlsConfig) -> Result<TlsAcceptor> {
    if config.cert_path.exists() && config.key_path.exists() {
        tracing::info!(
            cert = ?config.cert_path,
            key = ?config.key_path,
            "Loading TLS certificates"
        );
        load_acceptor(&config.cert_path, &config.key_path)
    } else if config.auto_generate {
        anyhow::bail!(
            "Auto-generation of TLS certificates not yet implemented. \
            Please provide certificate and key files:\n  \
            Cert: {}\n  Key: {}",
            config.cert_path.display(),
            config.key_path.display()
        );
    } else {
        anyhow::bail!(
            "TLS certificates not found and auto-generate is disabled.\n  \
            Cert: {}\n  Key: {}",
            config.cert_path.display(),
            config.key_path.display()
        );
    }
}

/// Load TLS certificates from files
fn load_acceptor(cert_path: &Path, key_path: &Path) -> Result<TlsAcceptor> {
    let cert_bytes = std::fs::read(cert_path)
        .with_context(|| format!("Failed to read certificate: {}", cert_path.display()))?;
    let key_bytes = std::fs::read(key_path)
        .with_context(|| format!("Failed to read key: {}", key_path.display()))?;

    // Parse certificates
    let cert_der: Vec<_> = certs(&mut Cursor::new(&cert_bytes))
        .collect::<Result<Vec<_>, _>>()
        .context("Failed to parse certificates")?;

    if cert_der.is_empty() {
        anyhow::bail!("No certificates found in {}", cert_path.display());
    }

    // Parse private key
    let key_der = private_key(&mut Cursor::new(&key_bytes))
        .context("Failed to parse private key")?
        .context("No private key found")?;

    // Build Rustls server config
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(cert_der, key_der)
        .context("Failed to create Rustls config")?;

    Ok(TlsAcceptor::from(Arc::new(config)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_missing_certs_fails() {
        let config = TlsConfig::new("/tmp/nonexistent/cert.pem", "/tmp/nonexistent/key.pem")
            .with_autogenerate(false);
        let result = load_or_generate_acceptor(&config);
        assert!(result.is_err());
    }

    #[test]
    fn test_autogenerate_not_implemented() {
        let config = TlsConfig::new("/tmp/nonexistent/cert2.pem", "/tmp/nonexistent/key2.pem")
            .with_autogenerate(true);
        let result = load_or_generate_acceptor(&config);
        assert!(result.is_err());
    }
}

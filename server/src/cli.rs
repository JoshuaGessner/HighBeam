use anyhow::{bail, Result};

#[derive(Debug, Clone)]
pub struct CliArgs {
    pub config_path: String,
    pub headless: bool,
}

impl CliArgs {
    pub fn parse() -> Result<Self> {
        let mut config_path = String::from("ServerConfig.toml");
        let mut headless = false;

        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--headless" => {
                    headless = true;
                }
                "--config" | "-c" => {
                    let Some(path) = args.next() else {
                        bail!("Expected a path after {arg}");
                    };
                    config_path = path;
                }
                "--help" | "-h" => {
                    println!(
                        "HighBeam Server\n\nUsage:\n  highbeam-server [--config <path>] [--headless]\n\nOptions:\n  -c, --config <path>  Path to ServerConfig.toml\n      --headless       Run without future GUI features\n  -h, --help           Show this help message"
                    );
                    std::process::exit(0);
                }
                value if value.starts_with('-') => {
                    bail!("Unknown argument: {value}");
                }
                value => {
                    config_path = value.to_string();
                }
            }
        }

        Ok(Self {
            config_path,
            headless,
        })
    }
}

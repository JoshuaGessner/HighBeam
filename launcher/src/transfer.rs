use anyhow::{anyhow, Result};

#[derive(Debug, Clone)]
pub struct FileFrameHeader {
    pub name: String,
    pub file_size: u64,
}

pub fn encode_header(name: &str, file_size: u64) -> Result<Vec<u8>> {
    let name_bytes = name.as_bytes();
    let name_len = u16::try_from(name_bytes.len())
        .map_err(|_| anyhow!("mod file name is too long for u16 length prefix"))?;

    let mut out = Vec::with_capacity(2 + name_bytes.len() + 8);
    out.extend_from_slice(&name_len.to_le_bytes());
    out.extend_from_slice(name_bytes);
    out.extend_from_slice(&file_size.to_le_bytes());
    Ok(out)
}

pub fn decode_header(buf: &[u8]) -> Result<(FileFrameHeader, usize)> {
    if buf.len() < 2 {
        return Err(anyhow!("header too short for name length"));
    }
    let name_len = u16::from_le_bytes([buf[0], buf[1]]) as usize;
    let required = 2 + name_len + 8;
    if buf.len() < required {
        return Err(anyhow!("header too short for full frame"));
    }

    let name_start = 2;
    let name_end = name_start + name_len;
    let name = std::str::from_utf8(&buf[name_start..name_end])?.to_string();
    let size_start = name_end;
    let file_size = u64::from_le_bytes([
        buf[size_start],
        buf[size_start + 1],
        buf[size_start + 2],
        buf[size_start + 3],
        buf[size_start + 4],
        buf[size_start + 5],
        buf[size_start + 6],
        buf[size_start + 7],
    ]);

    Ok((FileFrameHeader { name, file_size }, required))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_header_round_trip() {
        let encoded = encode_header("map_pack.zip", 1234).unwrap();
        let (decoded, consumed) = decode_header(&encoded).unwrap();
        assert_eq!(decoded.name, "map_pack.zip");
        assert_eq!(decoded.file_size, 1234);
        assert_eq!(consumed, encoded.len());
    }
}

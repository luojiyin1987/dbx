use std::env;
use std::ffi::{OsStr, OsString};
use std::process::{self, Command};

fn crate_name(arguments: &[OsString]) -> Option<&OsStr> {
    for pair in arguments.windows(2) {
        if pair[0] == "--crate-name" {
            return Some(&pair[1]);
        }
    }

    arguments
        .iter()
        .find_map(|argument| argument.to_str().and_then(|value| value.strip_prefix("--crate-name=")).map(OsStr::new))
}

fn capture_environment(crate_name: &OsStr) -> Result<(), String> {
    if crate_name != "dbx_lib" && crate_name != "psm" {
        return Ok(());
    }

    let script = env::var_os("DBX_SCCACHE_INPUT_SCRIPT").ok_or("DBX_SCCACHE_INPUT_SCRIPT is not set")?;
    let status = Command::new("powershell.exe")
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(script)
        .arg("-CaptureEnvironment")
        .arg("-Crate")
        .arg(crate_name)
        .status()
        .map_err(|error| format!("failed to start the input recorder: {error}"))?;
    if !status.success() {
        return Err(format!("input recorder failed with {status}"));
    }
    Ok(())
}

fn main() {
    let arguments: Vec<OsString> = env::args_os().skip(1).collect();
    if arguments.is_empty() {
        eprintln!("missing rustc command");
        process::exit(1);
    }

    if let Some(name) = crate_name(&arguments[1..]) {
        if let Err(error) = capture_environment(name) {
            eprintln!("{error}");
            process::exit(1);
        }
    }

    let wrapper = env::var_os("DBX_SCCACHE_REAL_WRAPPER").unwrap_or_else(|| "sccache".into());
    match Command::new(wrapper).args(&arguments).status() {
        Ok(status) => process::exit(status.code().unwrap_or(1)),
        Err(error) => {
            eprintln!("failed to start sccache: {error}");
            process::exit(1);
        }
    }
}

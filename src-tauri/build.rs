use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

fn swift_sources(directory: &Path, files: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(directory).expect("Read native source directory") {
        let path = entry.expect("Read source entry").path();
        if path.is_dir() {
            swift_sources(&path, files);
        } else if path.extension().and_then(|s| s.to_str()) == Some("swift") {
            files.push(path);
        }
    }
}

fn main() {
    match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") => build_swift_bridge(),
        Ok("windows") => {}
        _ => panic!("Transpose currently supports macOS and Windows."),
    }
    tauri_build::build();
}

fn build_swift_bridge() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let source = manifest.join("../native/Sources/TransposeNative");
    println!("cargo:rerun-if-changed={}", source.display());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let mut files = Vec::new();
    swift_sources(&source, &mut files);
    files.sort();
    for file in &files {
        println!("cargo:rerun-if-changed={}", file.display());
    }
    let sdk = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        .expect("Find macOS SDK");
    assert!(sdk.status.success(), "Install Xcode Command Line Tools");
    let sdk = String::from_utf8(sdk.stdout).unwrap().trim().to_owned();
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => panic!("Unsupported architecture: {other}"),
    };
    let result = Command::new("xcrun")
        .args([
            "swiftc",
            "-parse-as-library",
            "-emit-library",
            "-static",
            "-swift-version",
            "5",
            "-O",
            "-module-name",
            "TransposeNative",
            "-target",
            &format!("{arch}-apple-macosx14.0"),
            "-sdk",
            &sdk,
        ])
        .args(&files)
        .arg("-o")
        .arg(out.join("libTransposeNative.a"))
        .status()
        .expect("Compile Swift native bridge");
    assert!(result.success(), "Swift native bridge failed to compile");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=TransposeNative");
    let info = Command::new("xcrun")
        .args(["swiftc", "-print-target-info"])
        .output()
        .expect("Read Swift runtime paths");
    let text = String::from_utf8(info.stdout).unwrap();
    // Swift emits Mach-O auto-link directives; make its runtime libraries discoverable.
    for line in text.lines().map(str::trim) {
        if line.starts_with('"') && line.contains("/lib/swift") && !line.contains(":") {
            let path = line.trim_end_matches(',').trim_matches('"');
            println!("cargo:rustc-link-search=native={path}");
        }
    }
    println!("cargo:rustc-link-search=native={sdk}/usr/lib/swift");
    // Swift's newer availability thunks use the Clang platform-version builtin.
    // rustc does not add compiler-rt on behalf of a statically linked Swift archive.
    let clang = Command::new("xcrun")
        .args(["clang", "--print-resource-dir"])
        .output()
        .expect("Find Clang runtime");
    assert!(clang.status.success(), "Could not find the Clang runtime");
    let clang = String::from_utf8(clang.stdout).unwrap();
    println!("cargo:rustc-link-search=native={}/lib/darwin", clang.trim());
    println!("cargo:rustc-link-lib=static=clang_rt.osx");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    for framework in [
        "AppKit",
        "Foundation",
        "ApplicationServices",
        "Carbon",
        "Vision",
        "NaturalLanguage",
        "Security",
        "LocalAuthentication",
        "ServiceManagement",
        "WebKit",
        "SwiftUI",
        "CoreGraphics",
        "QuartzCore",
        "CryptoKit",
        "ScreenCaptureKit",
        "UniformTypeIdentifiers",
        "Combine",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rustc-link-arg=-Wl,-weak_framework,Translation");
}

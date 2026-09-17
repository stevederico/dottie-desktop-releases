fn main() {
    println!("cargo:rustc-link-lib=sqlite3");
    println!("cargo:rustc-link-lib=curl");
    println!("cargo:rustc-link-lib=framework=Security");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
}

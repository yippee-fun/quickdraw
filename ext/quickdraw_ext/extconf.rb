# frozen_string_literal: true

require "rbconfig"

# Builds the optional Rust native extension when `cargo` is available.
# If `cargo` isn't installed, writes a no-op Makefile so installation succeeds
# and Quickdraw falls back to pure Ruby automatically.
ext_dir = __dir__
dlext = RbConfig::CONFIG["DLEXT"]
target_lib = RUBY_PLATFORM.include?("darwin") ? "libquickdraw_ext.dylib" : "libquickdraw_ext.so"
rustflags = RUBY_PLATFORM.include?("darwin") ? "RUSTFLAGS='-C link-arg=-Wl,-undefined,dynamic_lookup'" : ""
cargo = system("cargo", "--version", out: File::NULL, err: File::NULL)

if cargo
	File.write(File.join(ext_dir, "Makefile"), <<~MAKEFILE)
		all:
			cd #{ext_dir} && #{rustflags} cargo build --release
			cp #{ext_dir}/target/release/#{target_lib} #{ext_dir}/quickdraw_ext.#{dlext}

		install: all
			mkdir -p $(RUBYARCHDIR)/quickdraw
			cp #{ext_dir}/quickdraw_ext.#{dlext} $(RUBYARCHDIR)/quickdraw/quickdraw_ext.#{dlext}

		clean:
			rm -rf #{ext_dir}/target #{ext_dir}/quickdraw_ext.#{dlext}
	MAKEFILE
else
	File.write(File.join(ext_dir, "Makefile"), <<~MAKEFILE)
		all:
			@echo "Quickdraw: cargo not found; skipping optional Rust extension (using pure-Ruby fallback)."

		install: all

		clean:
	MAKEFILE
end

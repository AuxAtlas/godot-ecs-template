@tool
extends EditorPlugin

const WIZARD_SCENE_PATH = "res://addons/godot-ecs/wizard/project_wizard.tscn"
const AUTOLOAD_NAME = "BevyAppSingleton"
const AUTOLOAD_PATH = "res://addons/godot-ecs/bevy_app_singleton.tscn"

var wizard_dialog: Window
var _should_restart_after_build: bool = false

func _enable_plugin():
	# Automatically register the BevyApp singleton when plugin is enabled
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	print("godot-ecs: BevyAppSingleton autoload registered")

func _disable_plugin():
	# Remove the autoload when plugin is disabled
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("godot-ecs: BevyAppSingleton autoload removed")

func _enter_tree():
	# Add menu items
	add_tool_menu_item("Setup godot-ecs Project", _on_setup_project)
	add_tool_menu_item("Build Rust Project", _on_build_rust)

	print("godot-ecs plugin activated!")

func _exit_tree():
	# Remove menu items
	remove_tool_menu_item("Setup godot-ecs Project")
	remove_tool_menu_item("Build Rust Project")

	if wizard_dialog:
		wizard_dialog.queue_free()

func _on_setup_project():
	# Show project wizard dialog
	if not wizard_dialog:
		var wizard_scene = load(WIZARD_SCENE_PATH)
		if wizard_scene:
			wizard_dialog = wizard_scene.instantiate()
			wizard_dialog.project_created.connect(_on_project_created)
			EditorInterface.get_base_control().add_child(wizard_dialog)
		else:
			push_error("Failed to load wizard scene")

	wizard_dialog.popup_centered()


func _on_project_created(project_info: Dictionary):
	# Handle the project creation based on wizard input
	_scaffold_rust_project(project_info)
	
	# Automatically build the Rust project and restart after
	var is_release = project_info.get("release_build", false)
	_should_restart_after_build = true
	_build_rust_project(is_release)

func _scaffold_rust_project(info: Dictionary):
	var base_path = ProjectSettings.globalize_path("res://")
	var rust_path = base_path.path_join("rust")
	var cargo_toml_path = base_path.path_join("Cargo.toml")

	# Check if Rust project already exists
	if FileAccess.file_exists(cargo_toml_path):
		push_warning("Rust project already exists at 'res://' directory. Skipping Rust scaffolding.")
		print("Found existing Cargo.toml at: ", cargo_toml_path)
		return

	# Debug: Print the info dictionary
	print("Project info received: ", info)
	print("Project name value: '", info.get("project_name", "KEY_NOT_FOUND"), "'")

	# Validate project name
	var project_name = info.project_name.strip_edges()
	if project_name.is_empty():
		project_name = "my_game"
		push_warning("Empty project name, using default: my_game")

	# Create directory structure
	DirAccess.make_dir_recursive_absolute(rust_path.path_join("src"))

	# Create Cargo.toml
	var cargo_content = """[package]
name = "%s"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]
path = "rust/src/lib.rs"

[[bin]]
path = "./run_godot.rs"
name = "godot"

[dependencies]
bevy = { version = "0.16", default-features = false, features = ["bevy_state"] }
godot = "0.4"
godot-bevy = { version = "%s", features = ["default"] }
bevy_quinnet = { version = "0.18.1", features = ["bincode-messages"] }
bevy_asset_loader = "0.23.0"
which = "8.0.0"

[workspace]
# Empty workspace table to make this a standalone project

[profile.dev]
opt-level = 1

[profile.dev.package."*"]
opt-level = 3

[lints.rust.unexpected_cfgs]
level = "warn"
check-cfg = ['cfg(feature, values("trace_tracy"))']
""" % [project_name.to_snake_case(), info.godot_bevy_version]

	_save_file(cargo_toml_path, cargo_content)

	# Always use GodotDefaultPlugins for bootstrapping
	# Users can customize plugin selection in their generated code
	var plugin_config = """app.add_plugins(GodotDefaultPlugins);
    app.init_state::<GameState>();
    """

	# Create lib.rs
	var lib_content = """use godot::prelude::*;
use bevy::prelude::*;
use godot_bevy::prelude::*;
use bevy::state::app::StatesPlugin;

#[bevy_app]
fn build_app(app: &mut App) {
	%s
}

#[derive(States, Clone, Copy, Default, Eq, PartialEq, Hash, Debug)]
enum GameState {
    #[default]
    Loading,
    InGame,
}
""" % [plugin_config]

	_save_file(rust_path.path_join("src/lib.rs"), lib_content)

	# Create .gdextension file
	var gdextension_content = """[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.1
reloadable = true

[libraries]
linux.debug.x86_64 = "res://rust/target/debug/lib%s.so"
linux.release.x86_64 = "res://rust/target/release/lib%s.so"
windows.debug.x86_64 = "res://rust/target/debug/%s.dll"
windows.release.x86_64 = "res://rust/target/release/%s.dll"
macos.debug = "res://rust/target/debug/lib%s.dylib"
macos.release = "res://rust/target/release/lib%s.dylib"
macos.debug.arm64 = "res://rust/target/debug/lib%s.dylib"
macos.release.arm64 = "res://rust/target/release/lib%s.dylib"
""" % [
		project_name.to_snake_case(),
		project_name.to_snake_case(),
		project_name.to_snake_case(),
		project_name.to_snake_case(),
		project_name.to_snake_case(),
		project_name.to_snake_case(),
		project_name.to_snake_case(),
		project_name.to_snake_case(),
	]

	_save_file(base_path.path_join("rust.gdextension"), gdextension_content)

    var run_content = """use std::env;
use std::process::{Command, Stdio};

fn main() {
    let run_dir = format!("{}/", env!("CARGO_MANIFEST_DIR"));
    let godot_global_binary = which::which("godot")
        .map(|x| Some(x.to_string_lossy().to_string()))
        .unwrap_or_else(|_| None);

    let godot_local_binary = option_env!("GODOT").map(|x| x.to_string());

    let mut godot_binary_optional: Option<String> = None;
    if godot_global_binary.is_some() {
        godot_binary_optional = Some(godot_global_binary.unwrap());
    } else if godot_local_binary.is_some() {
        godot_binary_optional = godot_local_binary;
    }

    let godot_binary = godot_binary_optional.expect(
        "`GODOT` cli command not configured. Please set the `GODOT` environmental variable.",
    );

    Command::new(&godot_binary)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .current_dir(&run_dir)
        .output()
        .unwrap_or_else(|_| {
            panic!(
                "tried running `{}` to edit this project and failed.",
                &godot_binary
            )
        });
}
"""

	push_warning("Rust project scaffolded successfully! Building now...")

func _on_build_rust():
	# Build the Rust project (called from menu)
	_should_restart_after_build = false  # Don't restart for manual builds
	_build_rust_project(false)  # Default to debug build

func _build_rust_project(release_build: bool):
	var base_path = ProjectSettings.globalize_path("res://")
	var rust_path = base_path.path_join("rust")

	# Check if rust directory exists
	if not DirAccess.dir_exists_absolute(rust_path):
		push_error("No Rust project found! Run 'Setup godot-ecs Project' first.")
		return

	# Prepare cargo command with working directory
	var args = ["build", "--manifest-path", base_path.path_join("Cargo.toml")]
	if release_build:
		args.append("--release")

	print("Building Rust project...")
	print("Running: cargo ", " ".join(args))

	# Execute cargo build
	var output = []
	var exit_code = OS.execute("cargo", args, output, true, true)

	# Process results
	if exit_code == 0:
		var build_type = "debug" if not release_build else "release"
		push_warning("Rust build completed successfully! (%s)" % build_type)
		print("Build output:")
		for line in output:
			print("  ", line)

		# Restart editor if this was called from project setup
		if _should_restart_after_build:
			push_warning("Restarting editor to apply autoload changes...")
			EditorInterface.restart_editor()
	else:
		push_error("Rust build failed with exit code: %d" % exit_code)
		print("Build errors:")
		for line in output:
			print("  ", line)

func _save_file(path: String, content: String):
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		print("Created: ", path)
	else:
		push_error("Failed to create file: " + path)
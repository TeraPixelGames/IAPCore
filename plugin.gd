@tool
extends EditorPlugin

var _autoload_name := "IapManager"
var _google_plugin: EditorPlugin

func _enter_tree() -> void:
	# Keep the public name stable for existing code.
	if not ProjectSettings.has_setting("autoload/%s" % _autoload_name):
		add_autoload_singleton(_autoload_name, "res://addons/iap_core/iap.gd")
	else:
		# If already registered, ensure path points to the plugin version.
		var existing_path := ProjectSettings.get_setting("autoload/%s" % _autoload_name)
		if String(existing_path) != "res://addons/iap_core/iap.gd":
			remove_autoload_singleton(_autoload_name)
			add_autoload_singleton(_autoload_name, "res://addons/iap_core/iap.gd")
	_enable_google_billing()


func _exit_tree() -> void:
	if ProjectSettings.has_setting("autoload/%s" % _autoload_name):
		var existing_path := ProjectSettings.get_setting("autoload/%s" % _autoload_name)
		if String(existing_path) == "res://addons/iap_core/iap.gd":
			remove_autoload_singleton(_autoload_name)
	_disable_google_billing()


func _enable_google_billing() -> void:
	var path := "res://addons/iap_core/GodotGooglePlayBilling/export_plugin.gd"
	if not FileAccess.file_exists(path):
		push_warning("IapCore: Google Play Billing addon not found at %s; Android IAP will run in stub mode." % path)
		return
	var script := load(path)
	if script == null:
		push_warning("IapCore: Failed to load %s; Android IAP will run in stub mode." % path)
		return
	_google_plugin = script.new()
	if _google_plugin:
		add_child(_google_plugin)


func _disable_google_billing() -> void:
	if _google_plugin and is_instance_valid(_google_plugin):
		remove_child(_google_plugin)
		_google_plugin.queue_free()
		_google_plugin = null

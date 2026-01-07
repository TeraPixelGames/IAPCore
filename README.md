# IapCore addon

Shared IAP bridge for Android (Google Play Billing), iOS (StoreKit), and stub fallback. It autoloads as `IapManager` to stay compatible with existing game code.

## Submodule dependencies
- Google Play Billing plugin (Android): add as submodule at `addons/iap_core/GodotGooglePlayBilling`
- iOS StoreKit plugin: add as submodule at `addons/iap_core/ios-in-app-purchase-v0.1.2`

Example:
```sh
git submodule add https://github.com/Poing-Studios/GodotGooglePlayBilling.git addons/iap_core/GodotGooglePlayBilling
git submodule add https://github.com/naithar/godot-ios-in-app-purchase.git addons/iap_core/ios-in-app-purchase-v0.1.2
git submodule update --init --recursive
```

Enable the IapCore plugin in the editor; it registers the `IapManager` autoload pointing at `res://addons/iap_core/iap.gd` and auto-enables the embedded Google Play Billing export plugin when present.

extends Node

# Shared IAP bridge for Android (Google Play Billing), iOS StoreKit, and stub fallback.
# Derived from the prior project autoload to keep the same signals and API surface.

var is_android := OS.get_name() == "Android"
var is_ios := OS.get_name() == "iOS"

const PRODUCTS_ANDROID := {
	"small": "coins_small",
	"medium": "coins_medium",
	"large": "coins_large",
	"ultra": "coins_ultra"
}

const PRODUCTS_IOS := {
	"small": "com.mygame.coins_small",
	"medium": "com.mygame.coins_medium",
	"large": "com.mygame.coins_large",
	"ultra": "com.mygame.coins_ultra"
}

var _android_billing: BillingClient
var _ios_iap: Object
var _android_product_for_token: Dictionary = {} # token -> product_id for ack/consume callbacks
var _android_pending_product_id: String = ""
var _product_prices: Dictionary = {} # product_id -> formatted price string
var _force_stub: bool = false

signal purchase_started(product_id: String)
signal purchase_succeeded(product_id: String)
signal purchase_failed(product_id: String, reason: String)
signal product_price_updated(product_id: String, price: String)


func _ready() -> void:
	if Config.should_mock_iap():
		_force_stub = true
		_emit_stub_prices()
		print("IapManager: running in mock mode.")
		return
	# Ensure wallet is loaded before any purchase callbacks land.
	if Engine.has_singleton("CoinWallet") and Engine.get_singleton("CoinWallet").has_method("load_from_disk"):
		Engine.get_singleton("CoinWallet").load_from_disk()
	elif "CoinWallet" in get_tree().get_root():
		var wallet := get_tree().get_root().get_node("CoinWallet")
		if wallet and wallet.has_method("load_from_disk"):
			wallet.load_from_disk()

	if is_android:
		_setup_android_billing()
	elif is_ios:
		_setup_ios_storekit()
	else:
		print("IapManager: Platform", OS.get_name(), "does not support IAP; running stub mode.")
		_emit_stub_prices()


func buy_small_pack() -> void:
	_buy("small")


func buy_medium_pack() -> void:
	_buy("medium")


func buy_large_pack() -> void:
	_buy("large")


func buy_ultra_pack() -> void:
	_buy("ultra")


func _buy(key: String) -> void:
	if _force_stub:
		_buy_stub(PRODUCTS_ANDROID.get(key, PRODUCTS_IOS.get(key, "")))
		return
	if is_android:
		_buy_android(PRODUCTS_ANDROID.get(key, ""))
	elif is_ios:
		_buy_ios(PRODUCTS_IOS.get(key, ""))
	else:
		_buy_stub(PRODUCTS_ANDROID.get(key, PRODUCTS_IOS.get(key, "")))


# --- Android (Google Play Billing) ---

func _setup_android_billing() -> void:
	if not Engine.has_singleton("GodotGooglePlayBilling"):
		push_warning("IapManager: Google Play Billing plugin not found.")
		return

	_android_billing = BillingClient.new()
	add_child(_android_billing)

	_android_billing.connected.connect(_on_android_connected)
	_android_billing.disconnected.connect(func() -> void:
		push_warning("IapManager(Android): Billing service disconnected.")
	)
	_android_billing.connect_error.connect(func(code: int, message: String) -> void:
		push_warning("IapManager(Android): Billing connect error %s - %s" % [code, message])
	)
	_android_billing.on_purchase_updated.connect(_on_android_purchase_updated)
	_android_billing.acknowledge_purchase_response.connect(_on_android_ack_response)
	_android_billing.consume_purchase_response.connect(_on_android_consume_response)
	_android_billing.query_product_details_response.connect(_on_android_product_details)

	_android_billing.start_connection()


func _buy_android(product_id: String) -> void:
	if product_id == "":
		push_warning("IapManager(Android): Unknown product id.")
		return
	if not _android_billing:
		push_warning("IapManager(Android): Billing client unavailable.")
		return

	if _android_billing.get_connection_state() != BillingClient.ConnectionState.CONNECTED:
		_android_pending_product_id = product_id
		_android_billing.start_connection()
		print("IapManager(Android): Connection not ready, queued %s until connected." % product_id)
		return

	_purchase_android_now(product_id)


func _purchase_android_now(product_id: String) -> void:
	purchase_started.emit(product_id)
	var result: Dictionary = _android_billing.purchase(product_id)
	var response_code: int = int(result.get("response_code", BillingClient.BillingResponseCode.ERROR))
	if response_code != BillingClient.BillingResponseCode.OK:
		_on_android_purchase_fail(product_id, "request_response_%s" % response_code)
	else:
		print("IapManager(Android): Purchase requested for %s" % product_id)


func _on_android_purchase_updated(response: Dictionary) -> void:
	var code: int = int(response.get("response_code", BillingClient.BillingResponseCode.ERROR))
	var debug_message: String = String(response.get("debug_message", ""))
	print("IapManager(Android): Purchase update code=%s msg=%s" % [code, debug_message])

	if code != BillingClient.BillingResponseCode.OK:
		for purchase in response.get("purchases", []):
			var product_ids: Array = purchase.get("product_ids", [])
			var product_id: String =  String(product_ids[0]) if product_ids.size() > 0 else ""
			_on_android_purchase_fail(product_id, "update_response_%s" % code)
		return

	for purchase in response.get("purchases", []):
		var product_ids: Array = purchase.get("product_ids", [])
		if product_ids.is_empty():
			continue
		var product_id: String = String(product_ids[0])
		var token: String = String(purchase.get("purchase_token", ""))
		var acknowledged: bool = bool(purchase.get("is_acknowledged", false))
		_android_product_for_token[token] = product_id

		_on_android_purchase_success(product_id)

		if not acknowledged and token != "":
			_android_billing.acknowledge_purchase(token)
		else:
			_on_android_purchase_acknowledged(product_id)
			if token != "":
				_android_billing.consume_purchase(token)


func _on_android_ack_response(response: Dictionary) -> void:
	var code: int = int(response.get("response_code", BillingClient.BillingResponseCode.ERROR))
	var token: String = String(response.get("token", ""))
	var product_id: String = String(_android_product_for_token.get(token, ""))

	print("IapManager(Android): Ack response code=%s token=%s product=%s" % [code, token, product_id])

	if code == BillingClient.BillingResponseCode.OK:
		_on_android_purchase_acknowledged(product_id)
		if token != "":
			_android_billing.consume_purchase(token)
	else:
		_on_android_purchase_fail(product_id, "ack_response_%s" % code)


func _on_android_consume_response(response: Dictionary) -> void:
	var code: int = int(response.get("response_code", BillingClient.BillingResponseCode.ERROR))
	var token: String = String(response.get("token", ""))
	var product_id: String = String(_android_product_for_token.get(token, ""))
	print("IapManager(Android): Consume response code=%s token=%s product=%s" % [code, token, product_id])


func _on_android_purchase_success(product_id: String) -> void:
	print("IapManager(Android): Purchase success for %s" % product_id)
	grant_coins_for_product(product_id)
	purchase_succeeded.emit(product_id)


func _on_android_purchase_fail(product_id: String, error: String) -> void:
	push_warning("IapManager(Android): Purchase failed for %s (%s)" % [product_id, error])
	purchase_failed.emit(product_id, error)


func _on_android_purchase_acknowledged(product_id: String) -> void:
	print("IapManager(Android): Purchase acknowledged for %s" % product_id)


func _on_android_connected() -> void:
	print("IapManager(Android): Billing service connected.")
	_fetch_android_products()
	if _android_pending_product_id != "":
		var product_id := _android_pending_product_id
		_android_pending_product_id = ""
		_purchase_android_now(product_id)


func _fetch_android_products() -> void:
	if not _android_billing:
		return
	var ids := PackedStringArray()
	for id in PRODUCTS_ANDROID.values():
		ids.append(id)
	_android_billing.query_product_details(ids, BillingClient.ProductType.INAPP)


func _on_android_product_details(response: Dictionary) -> void:
	var code: int = int(response.get("response_code", BillingClient.BillingResponseCode.ERROR))
	if code != BillingClient.BillingResponseCode.OK:
		push_warning("IapManager(Android): Product query failed %s" % code)
		return

	for detail in response.get("product_details", []):
		var product_id: String = String(detail.get("product_id", detail.get("productId", "")))
		if product_id == "":
			continue
		var price := ""
		if detail.has("one_time_purchase_offer_details"):
			var offer : Dictionary = detail["one_time_purchase_offer_details"]
			price = String(offer.get("formatted_price", ""))
		if price == "" and detail.has("formatted_price"):
			price = String(detail.get("formatted_price"))
		if price == "" and detail.has("price"):
			price = String(detail.get("price"))
		if price != "":
			_product_prices[product_id] = price
			product_price_updated.emit(product_id, price)


# --- iOS (StoreKit) ---

func _setup_ios_storekit() -> void:
	if not Engine.has_singleton("InAppStore"):
		push_warning("IapManager: iOS StoreKit plugin not found.")
		return
	_ios_iap = Engine.get_singleton("InAppStore")
	if _ios_iap == null:
		push_warning("IapManager: Failed to fetch iOS IAP singleton.")
		return
	if _ios_iap.has_signal("products_request_completed"):
		_ios_iap.products_request_completed.connect(func(products: Array) -> void:
			for product in products:
				var pid := String(product.get("product_id", ""))
				var price := String(product.get("price", ""))
				if pid != "" and price != "":
					_product_prices[pid] = price
					product_price_updated.emit(pid, price)
		)
	if _ios_iap.has_signal("purchase_success"):
		_ios_iap.purchase_success.connect(func(product_id: String) -> void:
			print("IapManager(iOS): Purchase success for %s" % product_id)
			grant_coins_for_product(product_id)
			purchase_succeeded.emit(product_id)
		)
	if _ios_iap.has_signal("purchase_fail"):
		_ios_iap.purchase_fail.connect(func(product_id: String, message: String) -> void:
			push_warning("IapManager(iOS): Purchase failed for %s (%s)" % [product_id, message])
			purchase_failed.emit(product_id, message)
		)
	if _ios_iap.has_signal("purchase_restored"):
		_ios_iap.purchase_restored.connect(func(product_id: String) -> void:
			print("IapManager(iOS): Purchase restored for %s" % product_id)
		)
	print("IapManager(iOS): StoreKit signals connected.")
	_request_ios_products()


func _request_ios_products() -> void:
	if _ios_iap == null:
		push_warning("IapManager(iOS): StoreKit unavailable.")
		return
	var ids := PackedStringArray()
	for id in PRODUCTS_IOS.values():
		ids.append(id)
	_ios_iap.request_product_info(ids)


func _buy_ios(product_id: String) -> void:
	if _ios_iap == null:
		push_warning("IapManager(iOS): StoreKit unavailable.")
		return
	if product_id == "":
		push_warning("IapManager(iOS): Unknown product id.")
		return
	print("IapManager(iOS): Starting purchase for %s" % product_id)
	purchase_started.emit(product_id)
	_ios_iap.purchase(product_id)


# --- Stub / desktop fallback ---

func _buy_stub(product_id: String) -> void:
	if product_id == "":
		push_warning("IapManager: Stub purchase requested with no product id.")
		return
	print("IapManager(Stub): Simulating purchase for %s" % product_id)
	purchase_started.emit(product_id)
	grant_coins_for_product(product_id)
	purchase_succeeded.emit(product_id)


func _emit_stub_prices() -> void:
	for pid in PRODUCTS_ANDROID.values():
		product_price_updated.emit(pid, "$0.99")


# --- Helpers ---

func get_product_price(product_id: String) -> String:
	return _product_prices.get(product_id, "")

func grant_coins_for_product(product_id: String) -> void:
	match product_id:
		"coins_small", "com.mygame.coins_small":
			_grant(1000)
		"coins_medium", "com.mygame.coins_medium":
			_grant(5000)
		"coins_large", "com.mygame.coins_large":
			_grant(12000)
		"coins_ultra", "com.mygame.coins_ultra":
			_grant(30000)
		_:
			push_warning("IapManager: Unknown product for granting coins (%s)" % product_id)

func _grant(amount: int) -> void:
	if amount == 0:
		return
	var applied := false
	if GameState != null and GameState.has_method("add_coins"):
		GameState.add_coins(amount)
		applied = true
	if ShopManager != null:
		if applied and ShopManager.has_method("_sync_from_game_state"):
			ShopManager._sync_from_game_state(true)
		elif ShopManager.has_method("add_coins"):
			ShopManager.add_coins(amount)

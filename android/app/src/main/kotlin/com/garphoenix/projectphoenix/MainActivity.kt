package com.garphoenix.projectphoenix

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME =
            "com.garphoenix.projectphoenix/native_update_installer"
        private const val DEEP_LINK_CHANNEL_NAME =
            "com.garphoenix.projectphoenix/deep_links"
        private const val PASSKEY_CHANNEL_NAME =
            "com.garphoenix.projectphoenix/passkeys"
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 6104
    }

    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var initialDeepLink: String? = null
    private var latestDeepLink: String? = null
    private val credentialManager: CredentialManager by lazy {
        CredentialManager.create(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialDeepLink = intent?.dataString
        latestDeepLink = initialDeepLink
        ensureNotificationChannels()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        latestDeepLink = intent.dataString
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startManagedUpdateDownload" -> {
                    val payloadJson = call.argument<String>("payloadJson")?.trim().orEmpty()
                    if (payloadJson.isEmpty()) {
                        result.error(
                            "invalid_args",
                            "payloadJson is required",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    try {
                        PhoenixManagedUpdateEngine.startOrResume(applicationContext, payloadJson)
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("managed_update_start_failed", t.message, null)
                    }
                }

                "getManagedUpdateStatus" -> {
                    try {
                        result.success(PhoenixManagedUpdateEngine.currentStatus(applicationContext))
                    } catch (t: Throwable) {
                        result.error("managed_update_status_failed", t.message, null)
                    }
                }

                "installManagedUpdate" -> {
                    try {
                        result.success(
                            PhoenixManagedUpdateEngine.installPreparedUpdate(applicationContext),
                        )
                    } catch (t: Throwable) {
                        result.error("managed_update_install_failed", t.message, null)
                    }
                }

                "clearManagedUpdateState" -> {
                    try {
                        PhoenixManagedUpdateEngine.clearState(applicationContext)
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("managed_update_clear_failed", t.message, null)
                    }
                }

                "canRequestPackageInstalls" -> {
                    try {
                        result.success(
                            PhoenixManagedUpdateEngine.canRequestPackageInstalls(applicationContext),
                        )
                    } catch (t: Throwable) {
                        result.error("install_permission_check_failed", t.message, null)
                    }
                }

                "openUnknownAppSourcesSettings" -> {
                    try {
                        PhoenixManagedUpdateEngine.openUnknownAppSourcesSettings(this)
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("install_settings_open_failed", t.message, null)
                    }
                }

                "canPostNotifications" -> {
                    result.success(canPostNotifications())
                }

                "requestNotificationPermission" -> {
                    if (canPostNotifications()) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    if (pendingNotificationPermissionResult != null) {
                        result.error(
                            "permission_request_busy",
                            "Another notification permission request is already in progress",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    pendingNotificationPermissionResult = result
                    requestPermissions(
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        NOTIFICATION_PERMISSION_REQUEST_CODE,
                    )
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEP_LINK_CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> result.success(initialDeepLink ?: "")
                "consumeLatestLink" -> {
                    val value = latestDeepLink ?: ""
                    latestDeepLink = null
                    result.success(value)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PASSKEY_CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                "create" -> createPasskey(call.arguments as? String, result)
                "get" -> getPasskey(call.arguments as? String, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun createPasskey(optionsJson: String?, result: MethodChannel.Result) {
        val requestJson = optionsJson?.trim().orEmpty()
        if (requestJson.isEmpty()) {
            result.error("invalid_args", "options json is required", null)
            return
        }
        try {
            val request = CreatePublicKeyCredentialRequest(requestJson)
            credentialManager.createCredentialAsync(
                this,
                request,
                CancellationSignal(),
                ContextCompat.getMainExecutor(this),
                object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                    override fun onResult(response: CreateCredentialResponse) {
                        val publicKeyResponse = response as? CreatePublicKeyCredentialResponse
                        if (publicKeyResponse == null) {
                            result.error("passkey_create_failed", "Unexpected passkey response", null)
                            return
                        }
                        result.success(publicKeyResponse.registrationResponseJson)
                    }

                    override fun onError(e: CreateCredentialException) {
                        result.error("passkey_create_failed", e.message, null)
                    }
                },
            )
        } catch (t: Throwable) {
            result.error("passkey_create_failed", t.message, null)
        }
    }

    private fun getPasskey(optionsJson: String?, result: MethodChannel.Result) {
        val requestJson = optionsJson?.trim().orEmpty()
        if (requestJson.isEmpty()) {
            result.error("invalid_args", "options json is required", null)
            return
        }
        try {
            val request = GetCredentialRequest(
                listOf(GetPublicKeyCredentialOption(requestJson)),
            )
            credentialManager.getCredentialAsync(
                this,
                request,
                CancellationSignal(),
                ContextCompat.getMainExecutor(this),
                object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                    override fun onResult(response: GetCredentialResponse) {
                        val publicKeyCredential = response.credential as? PublicKeyCredential
                        if (publicKeyCredential == null) {
                            result.error("passkey_get_failed", "Unexpected passkey response", null)
                            return
                        }
                        result.success(publicKeyCredential.authenticationResponseJson)
                    }

                    override fun onError(e: GetCredentialException) {
                        result.error("passkey_get_failed", e.message, null)
                    }
                },
            )
        } catch (t: Throwable) {
            result.error("passkey_get_failed", t.message, null)
        }
    }

    private fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) {
            return
        }
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermissionResult?.success(granted)
        pendingNotificationPermissionResult = null
    }

    private fun ensureNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channels = listOf(
            NotificationChannel(
                "phoenix_messages",
                "Личные сообщения",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Личные сообщения и каналы"
            },
            NotificationChannel(
                "phoenix_support",
                "Поддержка",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Поддержка и служебные ответы"
            },
            NotificationChannel(
                "phoenix_reserved",
                "Забронированный товар",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Забронированные товары и складские действия"
            },
            NotificationChannel(
                "phoenix_delivery",
                "Доставка",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Доставка и логистика"
            },
            NotificationChannel(
                "phoenix_promo",
                "Акции и промо",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Акции и маркетинговые уведомления"
            },
            NotificationChannel(
                "phoenix_updates",
                "Обновления",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Обновления приложения"
            },
            NotificationChannel(
                "phoenix_security",
                "Безопасность",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Входы, сбросы пароля и другие security-события"
            },
            NotificationChannel(
                "phoenix_messages_silent",
                "Личные сообщения (тихо)",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Личные сообщения и каналы без звука"
                setSound(null, null)
            },
            NotificationChannel(
                "phoenix_support_silent",
                "Поддержка (тихо)",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Поддержка и служебные ответы без звука"
                setSound(null, null)
            },
            NotificationChannel(
                "phoenix_reserved_silent",
                "Забронированный товар (тихо)",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Забронированные товары и складские действия без звука"
                setSound(null, null)
            },
            NotificationChannel(
                "phoenix_delivery_silent",
                "Доставка (тихо)",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Доставка и логистика без звука"
                setSound(null, null)
            },
            NotificationChannel(
                "phoenix_promo_silent",
                "Акции и промо (тихо)",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Акции и маркетинговые уведомления без звука"
                setSound(null, null)
            },
            NotificationChannel(
                "phoenix_updates_silent",
                "Обновления (тихо)",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Обновления приложения без звука"
                setSound(null, null)
            },
            NotificationChannel(
                "phoenix_security_silent",
                "Безопасность (тихо)",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Security-события без звука"
                setSound(null, null)
            },
        )
        manager.createNotificationChannels(channels)
    }
}

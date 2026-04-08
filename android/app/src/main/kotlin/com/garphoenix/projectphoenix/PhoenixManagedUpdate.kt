package com.garphoenix.projectphoenix

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.net.URI
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

private const val UPDATE_PREFS = "phoenix_managed_update"
private const val UPDATE_NOTIFICATION_ID = 64021
private const val UPDATE_CHANNEL_ID = "phoenix_updates"
private const val ACTION_START_OR_RESUME_UPDATE = "com.garphoenix.projectphoenix.action.START_OR_RESUME_UPDATE"
private const val ACTION_INSTALL_RESULT = "com.garphoenix.projectphoenix.action.INSTALL_RESULT"
private const val EXTRA_UPDATE_PAYLOAD_JSON = "update_payload_json"
private const val STATUS_IDLE = "idle"
private const val STATUS_CHECKING = "checking"
private const val STATUS_DOWNLOADING = "downloading"
private const val STATUS_PAUSED = "paused"
private const val STATUS_VERIFYING = "verifying"
private const val STATUS_READY_TO_INSTALL = "ready_to_install"
private const val STATUS_INSTALLING = "installing"
private const val STATUS_INSTALLED_PENDING_RESTART = "installed_pending_restart"
private const val STATUS_FAILED = "failed"
private const val PREF_STATUS = "status"
private const val PREF_STAGE = "stage"
private const val PREF_VERSION = "version_token"
private const val PREF_RECEIVED = "received_bytes"
private const val PREF_TOTAL = "total_bytes"
private const val PREF_SPEED = "speed_bytes_per_sec"
private const val PREF_ETA = "eta_seconds"
private const val PREF_FILE_PATH = "file_path"
private const val PREF_ERROR_CODE = "error_code"
private const val PREF_ERROR_MESSAGE = "error_message"
private const val PREF_REQUIRED = "required"
private const val PREF_PACKAGE_NAME = "package_name"
private const val PREF_KEY_ID = "key_id"
private const val PREF_PAYLOAD_JSON = "payload_json"
private const val PREF_SHA256 = "sha256"
private const val PREF_DOWNLOAD_URL = "download_url"
private const val PREF_TITLE = "title"
private const val PREF_LAST_UPDATED_AT = "last_updated_at"

data class ManagedUpdateEnvelope(
    val manifest: Map<String, Any?>,
    val signature: String,
    val keyId: String,
    val algorithm: String,
) {
    val versionToken: String
        get() {
            val version = manifestString("version")
            val build = manifestInt("build")
            return if (build > 0) "$version+$build" else version
        }

    val downloadUrl: String
        get() = manifestString("download_url")

    val expectedSha256: String
        get() = manifestString("sha256").lowercase(Locale.ROOT)

    val packageName: String
        get() = manifestString("package_name")

    val required: Boolean
        get() = manifestBoolean("required")

    val title: String
        get() = manifestString("title")

    fun manifestString(key: String): String {
        return (manifest[key] ?: "").toString().trim()
    }

    fun manifestInt(key: String): Int {
        val raw = manifest[key]
        return when (raw) {
            is Int -> raw
            is Long -> raw.toInt()
            is Double -> raw.toInt()
            is Float -> raw.toInt()
            else -> raw?.toString()?.trim()?.toIntOrNull() ?: 0
        }
    }

    fun manifestBoolean(key: String): Boolean {
        val raw = manifest[key]
        return when (raw) {
            is Boolean -> raw
            else -> raw?.toString()?.trim()?.lowercase(Locale.ROOT) == "true"
        }
    }
}

data class ManagedUpdateState(
    val status: String = STATUS_IDLE,
    val stage: String = "",
    val versionToken: String = "",
    val receivedBytes: Long = 0L,
    val totalBytes: Long = 0L,
    val speedBytesPerSec: Long = 0L,
    val etaSeconds: Long = -1L,
    val filePath: String = "",
    val errorCode: String = "",
    val errorMessage: String = "",
    val required: Boolean = false,
    val packageName: String = "",
    val keyId: String = "",
    val payloadJson: String = "",
    val sha256: String = "",
    val downloadUrl: String = "",
    val title: String = "",
    val lastUpdatedAtMs: Long = 0L,
) {
    fun asMap(): Map<String, Any?> {
        return mapOf(
            "status" to status,
            "stage" to stage,
            "versionToken" to versionToken,
            "receivedBytes" to receivedBytes,
            "totalBytes" to totalBytes,
            "speedBytesPerSec" to speedBytesPerSec,
            "etaSeconds" to etaSeconds,
            "filePath" to filePath,
            "errorCode" to errorCode,
            "errorMessage" to errorMessage,
            "required" to required,
            "packageName" to packageName,
            "keyId" to keyId,
            "payloadJson" to payloadJson,
            "sha256" to sha256,
            "downloadUrl" to downloadUrl,
            "title" to title,
            "lastUpdatedAtMs" to lastUpdatedAtMs,
            "readyToInstall" to (status == STATUS_READY_TO_INSTALL),
            "canResume" to (status == STATUS_PAUSED || status == STATUS_FAILED),
        )
    }
}

object PhoenixManagedUpdateStore {
    fun load(context: Context): ManagedUpdateState {
        val prefs = context.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
        return ManagedUpdateState(
            status = prefs.getString(PREF_STATUS, STATUS_IDLE).orEmpty().ifBlank { STATUS_IDLE },
            stage = prefs.getString(PREF_STAGE, "").orEmpty(),
            versionToken = prefs.getString(PREF_VERSION, "").orEmpty(),
            receivedBytes = prefs.getLong(PREF_RECEIVED, 0L),
            totalBytes = prefs.getLong(PREF_TOTAL, 0L),
            speedBytesPerSec = prefs.getLong(PREF_SPEED, 0L),
            etaSeconds = prefs.getLong(PREF_ETA, -1L),
            filePath = prefs.getString(PREF_FILE_PATH, "").orEmpty(),
            errorCode = prefs.getString(PREF_ERROR_CODE, "").orEmpty(),
            errorMessage = prefs.getString(PREF_ERROR_MESSAGE, "").orEmpty(),
            required = prefs.getBoolean(PREF_REQUIRED, false),
            packageName = prefs.getString(PREF_PACKAGE_NAME, "").orEmpty(),
            keyId = prefs.getString(PREF_KEY_ID, "").orEmpty(),
            payloadJson = prefs.getString(PREF_PAYLOAD_JSON, "").orEmpty(),
            sha256 = prefs.getString(PREF_SHA256, "").orEmpty(),
            downloadUrl = prefs.getString(PREF_DOWNLOAD_URL, "").orEmpty(),
            title = prefs.getString(PREF_TITLE, "").orEmpty(),
            lastUpdatedAtMs = prefs.getLong(PREF_LAST_UPDATED_AT, 0L),
        )
    }

    fun save(context: Context, state: ManagedUpdateState) {
        context.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PREF_STATUS, state.status)
            .putString(PREF_STAGE, state.stage)
            .putString(PREF_VERSION, state.versionToken)
            .putLong(PREF_RECEIVED, state.receivedBytes)
            .putLong(PREF_TOTAL, state.totalBytes)
            .putLong(PREF_SPEED, state.speedBytesPerSec)
            .putLong(PREF_ETA, state.etaSeconds)
            .putString(PREF_FILE_PATH, state.filePath)
            .putString(PREF_ERROR_CODE, state.errorCode)
            .putString(PREF_ERROR_MESSAGE, state.errorMessage)
            .putBoolean(PREF_REQUIRED, state.required)
            .putString(PREF_PACKAGE_NAME, state.packageName)
            .putString(PREF_KEY_ID, state.keyId)
            .putString(PREF_PAYLOAD_JSON, state.payloadJson)
            .putString(PREF_SHA256, state.sha256)
            .putString(PREF_DOWNLOAD_URL, state.downloadUrl)
            .putString(PREF_TITLE, state.title)
            .putLong(PREF_LAST_UPDATED_AT, state.lastUpdatedAtMs)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }
}

object PhoenixManagedUpdateEngine {
    private val executor = Executors.newSingleThreadExecutor()
    private val downloadRunning = AtomicBoolean(false)

    fun currentStatus(context: Context): Map<String, Any?> {
        return PhoenixManagedUpdateStore.load(context).asMap()
    }

    fun clearState(context: Context) {
        PhoenixManagedUpdateStore.clear(context)
    }

    fun canRequestPackageInstalls(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    fun openUnknownAppSourcesSettings(activity: MainActivity) {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            android.net.Uri.parse("package:${activity.packageName}"),
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        activity.startActivity(intent)
    }

    fun startOrResume(context: Context, payloadJson: String) {
        val intent = Intent(context, PhoenixManagedUpdateService::class.java).apply {
            action = ACTION_START_OR_RESUME_UPDATE
            putExtra(EXTRA_UPDATE_PAYLOAD_JSON, payloadJson)
        }
        ContextCompat.startForegroundService(context, intent)
    }

    fun installPreparedUpdate(context: Context): Boolean {
        val current = PhoenixManagedUpdateStore.load(context)
        val filePath = current.filePath.trim()
        if (filePath.isEmpty() || current.status != STATUS_READY_TO_INSTALL) return false
        if (!canRequestPackageInstalls(context)) {
            updateState(
                context = context,
                next = current.copy(
                    status = STATUS_READY_TO_INSTALL,
                    stage = "Нужно разрешить установку APK из Феникс.",
                    errorCode = "install_permission_required",
                    errorMessage = "Разрешите установку APK для Феникс в настройках Android.",
                    lastUpdatedAtMs = System.currentTimeMillis(),
                ),
            )
            return false
        }
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return false

        return try {
            val packageInstaller = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            ).apply {
                setAppPackageName(current.packageName.ifBlank { context.packageName })
            }
            val sessionId = packageInstaller.createSession(params)
            packageInstaller.openSession(sessionId).use { session ->
                FileInputStream(file).use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                updateState(
                    context = context,
                    next = current.copy(
                        status = STATUS_INSTALLING,
                        stage = "Открываем системную установку Android...",
                        errorCode = "",
                        errorMessage = "",
                        lastUpdatedAtMs = System.currentTimeMillis(),
                    ),
                )
                val callbackIntent = Intent(context, PhoenixManagedUpdateInstallReceiver::class.java).apply {
                    action = ACTION_INSTALL_RESULT
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
                val pendingIntent = PendingIntent.getBroadcast(
                    context,
                    sessionId,
                    callbackIntent,
                    flags,
                )
                session.commit(pendingIntent.intentSender)
            }
            true
        } catch (t: Throwable) {
            fail(
                context = context,
                current = current,
                code = "install_failed",
                message = t.message ?: "Не удалось открыть установку Android",
            )
            false
        }
    }

    fun handleServiceStart(service: PhoenixManagedUpdateService, payloadJson: String) {
        val payload = payloadJson.trim()
        if (payload.isEmpty()) {
            fail(
                context = service.applicationContext,
                current = PhoenixManagedUpdateStore.load(service.applicationContext),
                code = "manifest_missing",
                message = "Пустой update manifest",
            )
            service.stopSelf()
            return
        }
        if (downloadRunning.getAndSet(true)) {
            service.promoteWithState(PhoenixManagedUpdateStore.load(service.applicationContext))
            return
        }

        executor.execute {
            try {
                performDownload(service, payload)
            } finally {
                downloadRunning.set(false)
                service.stopSelf()
            }
        }
    }

    private fun performDownload(service: PhoenixManagedUpdateService, payloadJson: String) {
        val context = service.applicationContext
        val envelope = parseEnvelope(payloadJson)
        if (envelope == null) {
            fail(
                context = context,
                current = PhoenixManagedUpdateStore.load(context),
                code = "manifest_invalid",
                message = "Update manifest повреждён",
            )
            return
        }

        val checking = ManagedUpdateState(
            status = STATUS_CHECKING,
            stage = "Проверяем обновление Феникс...",
            versionToken = envelope.versionToken,
            required = envelope.required,
            packageName = envelope.packageName.ifBlank { context.packageName },
            keyId = envelope.keyId,
            payloadJson = payloadJson,
            sha256 = envelope.expectedSha256,
            downloadUrl = envelope.downloadUrl,
            title = envelope.title,
            lastUpdatedAtMs = System.currentTimeMillis(),
        )
        updateState(context, checking, service)

        if (!verifyEnvelope(envelope)) {
            fail(
                context = context,
                current = checking,
                code = "manifest_signature_invalid",
                message = "Подпись update manifest не прошла проверку",
                service = service,
            )
            return
        }

        if (!isAllowedDownloadUrl(envelope.downloadUrl)) {
            fail(
                context = context,
                current = checking,
                code = "download_url_rejected",
                message = "Manifest содержит недопустимую ссылку на APK",
                service = service,
            )
            return
        }

        val updatesDir = File(context.filesDir, "updates")
        if (!updatesDir.exists()) updatesDir.mkdirs()
        val finalFile = File(updatesDir, "${envelope.versionToken}.apk")
        val partFile = File(updatesDir, "${envelope.versionToken}.apk.part")

        if (finalFile.exists()) {
            if (verifyDownloadedFile(context, envelope, finalFile, checking, service)) {
                return
            }
            finalFile.delete()
        }

        var attempt = 0
        var lastFailure: Throwable? = null
        while (attempt < 3) {
            attempt += 1
            try {
                downloadFile(context, service, envelope, partFile, checking)
                partFile.copyTo(finalFile, overwrite = true)
                if (verifyDownloadedFile(context, envelope, finalFile, checking, service)) {
                    partFile.delete()
                    return
                }
                finalFile.delete()
                return
            } catch (t: Throwable) {
                lastFailure = t
                if (attempt >= 3) {
                    updateState(
                        context = context,
                        next = checking.copy(
                            status = STATUS_PAUSED,
                            stage = "Загрузка прервана. Можно продолжить позже.",
                            receivedBytes = partFile.takeIf { it.exists() }?.length() ?: 0L,
                            totalBytes = max(checking.totalBytes, checking.receivedBytes),
                            errorCode = "download_interrupted",
                            errorMessage = t.message ?: "Сеть прервала загрузку APK",
                            filePath = partFile.absolutePath,
                            lastUpdatedAtMs = System.currentTimeMillis(),
                        ),
                        service = service,
                    )
                    return
                }
                Thread.sleep((attempt * 1200L).coerceAtMost(3500L))
            }
        }

        fail(
            context = context,
            current = checking,
            code = "download_failed",
            message = lastFailure?.message ?: "Не удалось скачать APK",
            service = service,
        )
    }

    private fun downloadFile(
        context: Context,
        service: PhoenixManagedUpdateService,
        envelope: ManagedUpdateEnvelope,
        targetPartFile: File,
        baseState: ManagedUpdateState,
    ) {
        val expectedUrl = envelope.downloadUrl
        val existingBytes = if (targetPartFile.exists()) targetPartFile.length() else 0L
        var connection = URL(expectedUrl).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 15000
        connection.readTimeout = 30000
        connection.setRequestProperty("Accept", "application/vnd.android.package-archive")
        if (existingBytes > 0L) {
            connection.setRequestProperty("Range", "bytes=$existingBytes-")
        }
        connection.connect()

        val responseCode = connection.responseCode
        val resumed = responseCode == HttpURLConnection.HTTP_PARTIAL && existingBytes > 0L
        if (responseCode !in listOf(HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_PARTIAL)) {
            throw IllegalStateException("HTTP $responseCode while downloading APK")
        }

        val totalBytes = when {
            resumed -> {
                val contentLength = connection.getHeaderFieldLong("Content-Length", -1L)
                if (contentLength > 0L) contentLength + existingBytes else -1L
            }
            else -> connection.getHeaderFieldLong("Content-Length", -1L)
        }

        if (!resumed && targetPartFile.exists()) {
            targetPartFile.delete()
        }
        targetPartFile.parentFile?.mkdirs()

        RandomAccessFile(targetPartFile, "rw").use { output ->
            if (resumed) {
                output.seek(existingBytes)
            } else {
                output.setLength(0L)
            }
            connection.inputStream.use { input ->
                val buffer = ByteArray(64 * 1024)
                var receivedBytes = if (resumed) existingBytes else 0L
                var bytesSinceLast = 0L
                var lastUpdateAt = System.currentTimeMillis()
                var lastSpeedAt = lastUpdateAt
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    receivedBytes += read.toLong()
                    bytesSinceLast += read.toLong()
                    val now = System.currentTimeMillis()
                    if (now - lastUpdateAt >= 350L) {
                        val elapsedMs = max(1L, now - lastSpeedAt)
                        val speed = ((bytesSinceLast * 1000L) / elapsedMs).coerceAtLeast(0L)
                        val eta = if (totalBytes > 0L && speed > 0L) {
                            max(0L, (totalBytes - receivedBytes) / speed)
                        } else {
                            -1L
                        }
                        updateState(
                            context = context,
                            next = baseState.copy(
                                status = STATUS_DOWNLOADING,
                                stage = if (resumed) "Возобновляем загрузку APK..." else "Скачиваем APK Феникс...",
                                receivedBytes = receivedBytes,
                                totalBytes = totalBytes,
                                speedBytesPerSec = speed,
                                etaSeconds = eta,
                                filePath = targetPartFile.absolutePath,
                                errorCode = "",
                                errorMessage = "",
                                lastUpdatedAtMs = now,
                            ),
                            service = service,
                        )
                        bytesSinceLast = 0L
                        lastSpeedAt = now
                        lastUpdateAt = now
                    }
                }
                updateState(
                    context = context,
                    next = baseState.copy(
                        status = STATUS_DOWNLOADING,
                        stage = "Загрузка APK завершена, проверяем файл...",
                        receivedBytes = receivedBytes,
                        totalBytes = if (totalBytes > 0L) totalBytes else receivedBytes,
                        speedBytesPerSec = 0L,
                        etaSeconds = 0L,
                        filePath = targetPartFile.absolutePath,
                        errorCode = "",
                        errorMessage = "",
                        lastUpdatedAtMs = System.currentTimeMillis(),
                    ),
                    service = service,
                )
            }
        }
        connection.disconnect()
    }

    private fun verifyDownloadedFile(
        context: Context,
        envelope: ManagedUpdateEnvelope,
        downloadedFile: File,
        baseState: ManagedUpdateState,
        service: PhoenixManagedUpdateService,
    ): Boolean {
        updateState(
            context = context,
            next = baseState.copy(
                status = STATUS_VERIFYING,
                stage = "Проверяем APK перед установкой...",
                receivedBytes = downloadedFile.length(),
                totalBytes = downloadedFile.length(),
                speedBytesPerSec = 0L,
                etaSeconds = 0L,
                filePath = downloadedFile.absolutePath,
                errorCode = "",
                errorMessage = "",
                lastUpdatedAtMs = System.currentTimeMillis(),
            ),
            service = service,
        )

        val fileDigest = sha256Of(downloadedFile)
        if (!fileDigest.equals(envelope.expectedSha256, ignoreCase = true)) {
            fail(
                context = context,
                current = baseState,
                code = "apk_checksum_mismatch",
                message = "Контрольная сумма APK не совпала",
                service = service,
            )
            return false
        }

        val archivePackage = readArchivePackageName(context, downloadedFile)
        val expectedPackage = envelope.packageName.ifBlank { context.packageName }
        if (archivePackage.isBlank() || archivePackage != expectedPackage) {
            fail(
                context = context,
                current = baseState,
                code = "apk_package_mismatch",
                message = "APK не совпадает с пакетом Феникс",
                service = service,
            )
            return false
        }

        val ready = baseState.copy(
            status = STATUS_READY_TO_INSTALL,
            stage = "Обновление готово к установке.",
            receivedBytes = downloadedFile.length(),
            totalBytes = downloadedFile.length(),
            speedBytesPerSec = 0L,
            etaSeconds = 0L,
            filePath = downloadedFile.absolutePath,
            errorCode = "",
            errorMessage = "",
            lastUpdatedAtMs = System.currentTimeMillis(),
        )
        updateState(context, ready, service)
        notifyReadyToInstall(context, ready)
        return true
    }

    private fun fail(
        context: Context,
        current: ManagedUpdateState,
        code: String,
        message: String,
        service: PhoenixManagedUpdateService? = null,
    ) {
        updateState(
            context = context,
            next = current.copy(
                status = STATUS_FAILED,
                stage = "Обновление прервано.",
                errorCode = code,
                errorMessage = message,
                speedBytesPerSec = 0L,
                etaSeconds = -1L,
                lastUpdatedAtMs = System.currentTimeMillis(),
            ),
            service = service,
        )
    }

    private fun updateState(
        context: Context,
        next: ManagedUpdateState,
        service: PhoenixManagedUpdateService? = null,
    ) {
        PhoenixManagedUpdateStore.save(context, next)
        if (service != null) {
            service.promoteWithState(next)
        }
    }

    private fun parseEnvelope(payloadJson: String): ManagedUpdateEnvelope? {
        return try {
            val root = JSONObject(payloadJson)
            val manifestRaw = root.optJSONObject("manifest") ?: return null
            val manifest = jsonObjectToMap(manifestRaw)
            ManagedUpdateEnvelope(
                manifest = manifest,
                signature = root.optString("signature", "").trim(),
                keyId = root.optString("key_id", "").trim(),
                algorithm = root.optString("algorithm", "").trim(),
            )
        } catch (_: Throwable) {
            null
        }
    }

    private fun verifyEnvelope(envelope: ManagedUpdateEnvelope): Boolean {
        if (!envelope.algorithm.equals("ed25519", ignoreCase = true)) return false
        if (envelope.signature.isBlank()) return false
        val expectedKeyId = BuildConfig.UPDATE_MANIFEST_KEY_ID.trim()
        if (expectedKeyId.isNotEmpty() && envelope.keyId.isNotBlank() && envelope.keyId != expectedKeyId) {
            return false
        }
        return try {
            val verifier = Signature.getInstance("Ed25519")
            verifier.initVerify(loadPublicKey())
            verifier.update(canonicalJson(envelope.manifest).toByteArray(Charsets.UTF_8))
            verifier.verify(Base64.decode(envelope.signature, Base64.DEFAULT))
        } catch (_: Throwable) {
            false
        }
    }

    private fun loadPublicKey(): java.security.PublicKey {
        val pem = BuildConfig.UPDATE_MANIFEST_PUBLIC_KEY
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .replace("\n", "")
            .trim()
        val keySpec = X509EncodedKeySpec(Base64.decode(pem, Base64.DEFAULT))
        return KeyFactory.getInstance("Ed25519").generatePublic(keySpec)
    }

    private fun isAllowedDownloadUrl(rawUrl: String): Boolean {
        val normalized = rawUrl.trim()
        if (normalized.isEmpty()) return false
        return try {
            val uri = URI(normalized)
            val scheme = uri.scheme?.lowercase(Locale.ROOT).orEmpty()
            val host = uri.host?.lowercase(Locale.ROOT).orEmpty()
            if (scheme == "https") return host.isNotEmpty()
            BuildConfig.DEBUG &&
                scheme == "http" &&
                (host == "127.0.0.1" || host == "localhost")
        } catch (_: Throwable) {
            false
        }
    }

    private fun canonicalJson(value: Any?): String {
        return when (value) {
            null -> "null"
            is Map<*, *> -> {
                val keys = value.keys.mapNotNull { it?.toString() }.sorted()
                keys.joinToString(prefix = "{", postfix = "}", separator = ",") { key ->
                    val child = value[key]
                    "${JSONObject.quote(key)}:${canonicalJson(child)}"
                }
            }
            is List<*> -> value.joinToString(prefix = "[", postfix = "]", separator = ",") { canonicalJson(it) }
            is String -> JSONObject.quote(value)
            is Boolean -> if (value) "true" else "false"
            is Number -> value.toString()
            else -> JSONObject.quote(value.toString())
        }
    }

    private fun jsonObjectToMap(source: JSONObject): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        val keys = source.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out[key] = jsonToValue(source.opt(key))
        }
        return out
    }

    private fun jsonToValue(raw: Any?): Any? {
        return when (raw) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(raw)
            is JSONArray -> List(raw.length()) { index -> jsonToValue(raw.opt(index)) }
            else -> raw
        }
    }

    private fun readArchivePackageName(context: Context, file: File): String {
        return try {
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageArchiveInfo(
                    file.absolutePath,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageArchiveInfo(file.absolutePath, 0)
            }
            packageInfo?.packageName.orEmpty()
        } catch (_: Throwable) {
            ""
        }
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun notifyReadyToInstall(context: Context, state: ManagedUpdateState) {
        val notification = buildNotification(context, state)
        val manager = ContextCompat.getSystemService(context, NotificationManager::class.java)
        manager?.notify(UPDATE_NOTIFICATION_ID, notification)
    }

    fun buildNotification(context: Context, state: ManagedUpdateState): Notification {
        val openAppIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP) }
        val contentIntent = if (openAppIntent != null) {
            PendingIntent.getActivity(
                context,
                UPDATE_NOTIFICATION_ID,
                openAppIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0,
            )
        } else {
            null
        }

        val builder = NotificationCompat.Builder(context, UPDATE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(state.title.ifBlank { "Обновление Феникс" })
            .setContentText(state.stage.ifBlank { "Подготавливаем обновление..." })
            .setOnlyAlertOnce(true)
            .setOngoing(state.status == STATUS_DOWNLOADING || state.status == STATUS_VERIFYING || state.status == STATUS_INSTALLING)
            .setAutoCancel(state.status == STATUS_READY_TO_INSTALL || state.status == STATUS_INSTALLED_PENDING_RESTART || state.status == STATUS_FAILED)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (contentIntent != null) {
            builder.setContentIntent(contentIntent)
        }

        when (state.status) {
            STATUS_DOWNLOADING -> {
                if (state.totalBytes > 0L) {
                    val percent = ((state.receivedBytes * 100L) / max(1L, state.totalBytes)).toInt().coerceIn(0, 100)
                    builder.setProgress(100, percent, false)
                        .setContentText("${state.stage} · $percent%")
                } else {
                    builder.setProgress(0, 0, true)
                }
            }
            STATUS_VERIFYING, STATUS_INSTALLING, STATUS_CHECKING -> builder.setProgress(0, 0, true)
            else -> builder.setProgress(0, 0, false)
        }
        if (state.status == STATUS_READY_TO_INSTALL) {
            builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentText("Обновление скачано. Откройте Феникс и нажмите «Установить».")
        }
        if (state.status == STATUS_FAILED) {
            builder.setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentText(state.errorMessage.ifBlank { "Не удалось обновить Феникс" })
        }
        if (state.status == STATUS_INSTALLED_PENDING_RESTART) {
            builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentText("Феникс обновлён. Откройте приложение снова.")
        }
        return builder.build()
    }
}

class PhoenixManagedUpdateService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val payload = intent?.getStringExtra(EXTRA_UPDATE_PAYLOAD_JSON)?.trim().orEmpty()
        if (intent?.action == ACTION_START_OR_RESUME_UPDATE && payload.isNotEmpty()) {
            promoteWithState(PhoenixManagedUpdateStore.load(applicationContext))
            PhoenixManagedUpdateEngine.handleServiceStart(this, payload)
        }
        return START_NOT_STICKY
    }

    fun promoteWithState(state: ManagedUpdateState) {
        startForeground(
            UPDATE_NOTIFICATION_ID,
            PhoenixManagedUpdateEngine.buildNotification(applicationContext, state),
        )
    }
}

class PhoenixManagedUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val current = PhoenixManagedUpdateStore.load(context)
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirmIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirmIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (confirmIntent != null) {
                    context.startActivity(confirmIntent)
                }
                PhoenixManagedUpdateStore.save(
                    context,
                    current.copy(
                        status = STATUS_INSTALLING,
                        stage = "Подтвердите установку в Android",
                        errorCode = "",
                        errorMessage = "",
                        lastUpdatedAtMs = System.currentTimeMillis(),
                    ),
                )
            }
            PackageInstaller.STATUS_SUCCESS -> {
                PhoenixManagedUpdateStore.save(
                    context,
                    current.copy(
                        status = STATUS_INSTALLED_PENDING_RESTART,
                        stage = "Обновление установлено. Перезапустите Феникс.",
                        errorCode = "",
                        errorMessage = "",
                        lastUpdatedAtMs = System.currentTimeMillis(),
                    ),
                )
            }
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    ?.trim()
                    .orEmpty()
                PhoenixManagedUpdateStore.save(
                    context,
                    current.copy(
                        status = STATUS_FAILED,
                        stage = "Установка Android не завершилась.",
                        errorCode = "install_result_$status",
                        errorMessage = if (message.isNotEmpty()) message else "Android отменил установку APK",
                        lastUpdatedAtMs = System.currentTimeMillis(),
                    ),
                )
            }
        }
    }
}

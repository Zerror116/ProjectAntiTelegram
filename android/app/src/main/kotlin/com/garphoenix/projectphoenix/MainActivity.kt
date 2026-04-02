package com.garphoenix.projectphoenix

import android.Manifest
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME =
            "com.garphoenix.projectphoenix/native_update_installer"
        private const val APK_MIME = "application/vnd.android.package-archive"
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 6104
    }

    private var pendingNotificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueueDownload" -> {
                    val rawUrl = call.argument<String>("url")?.trim().orEmpty()
                    val fileName = call.argument<String>("fileName")?.trim().orEmpty()
                    if (rawUrl.isEmpty() || fileName.isEmpty()) {
                        result.error(
                            "invalid_args",
                            "url and fileName are required",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        val request = DownloadManager.Request(Uri.parse(rawUrl)).apply {
                            setTitle("Обновление Феникс")
                            setDescription("Скачиваем обновление приложения")
                            setMimeType(APK_MIME)
                            setNotificationVisibility(
                                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                            )
                            setVisibleInDownloadsUi(true)
                            setAllowedOverMetered(true)
                            setAllowedOverRoaming(true)
                            val headers = call.argument<Map<String, Any?>>("headers")
                            headers?.forEach { (key, value) ->
                                val safeKey = key.trim()
                                val safeValue = value?.toString()?.trim().orEmpty()
                                if (safeKey.isNotEmpty() && safeValue.isNotEmpty()) {
                                    addRequestHeader(safeKey, safeValue)
                                }
                            }
                            deleteExistingDownloadTarget(fileName)
                            setDestinationInExternalPublicDir(
                                Environment.DIRECTORY_DOWNLOADS,
                                fileName,
                            )
                        }

                        val downloadId = downloadManager().enqueue(request)
                        result.success(downloadId.toString())
                    } catch (t: Throwable) {
                        result.error("enqueue_failed", t.message, null)
                    }
                }

                "queryDownloadStatus" -> {
                    val downloadId = call.argument<String>("downloadId")
                        ?.trim()
                        ?.toLongOrNull()
                    if (downloadId == null) {
                        result.success(mapOf("status" to "missing"))
                        return@setMethodCallHandler
                    }

                    try {
                        val query = DownloadManager.Query().setFilterById(downloadId)
                        downloadManager().query(query).use { cursor ->
                            if (cursor == null || !cursor.moveToFirst()) {
                                result.success(mapOf("status" to "missing"))
                                return@use
                            }

                            val status = cursor.getInt(
                                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                            )
                            val downloadedBytes = cursor.getLong(
                                cursor.getColumnIndexOrThrow(
                                    DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                                ),
                            )
                            val totalBytes = cursor.getLong(
                                cursor.getColumnIndexOrThrow(
                                    DownloadManager.COLUMN_TOTAL_SIZE_BYTES,
                                ),
                            )
                            val reason = cursor.getInt(
                                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
                            )
                            val localUri = cursor.getString(
                                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI),
                            )
                            val downloadedUri =
                                downloadManager().getUriForDownloadedFile(downloadId)?.toString()
                            result.success(
                                mapOf(
                                    "status" to mapDownloadStatus(status),
                                    "downloadedBytes" to downloadedBytes,
                                    "totalBytes" to totalBytes,
                                    "reason" to reason.toString(),
                                    "uri" to (downloadedUri ?: localUri.orEmpty()),
                                ),
                            )
                        }
                    } catch (t: Throwable) {
                        result.error("query_failed", t.message, null)
                    }
                }

                "openDownloadedUri" -> {
                    val rawUri = call.argument<String>("uri")?.trim().orEmpty()
                    if (rawUri.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }

                    try {
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(Uri.parse(rawUri), APK_MIME)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Throwable) {
                        result.success(false)
                    }
                }

                "openDownloadsUi" -> {
                    try {
                        val intent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Throwable) {
                        result.success(false)
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
    }

    private fun downloadManager(): DownloadManager {
        return getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    }

    private fun deleteExistingDownloadTarget(fileName: String) {
        runCatching {
            val downloadsDir =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val target = File(downloadsDir, fileName)
            if (target.exists()) {
                target.delete()
            }
        }
    }

    private fun mapDownloadStatus(status: Int): String {
        return when (status) {
            DownloadManager.STATUS_PENDING -> "pending"
            DownloadManager.STATUS_RUNNING -> "running"
            DownloadManager.STATUS_PAUSED -> "paused"
            DownloadManager.STATUS_SUCCESSFUL -> "successful"
            DownloadManager.STATUS_FAILED -> "failed"
            else -> "unknown"
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
}

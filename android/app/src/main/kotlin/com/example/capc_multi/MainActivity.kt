package com.example.capc_multi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val channelName = "co.capc.multiservicio/platform"
    private val createDocumentRequest = 7001
    private var pendingBytes: ByteArray? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> result.success(
                        "${Build.MANUFACTURER} ${Build.MODEL}".trim()
                    )
                    "openPlayStore" -> {
                        val market = Intent(
                            Intent.ACTION_VIEW,
                            Uri.parse("market://details?id=$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        val web = Intent(
                            Intent.ACTION_VIEW,
                            Uri.parse("https://play.google.com/store/apps/details?id=$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(market)
                            result.success(null)
                        } catch (_: Exception) {
                            try {
                                startActivity(web)
                                result.success(null)
                            } catch (error: Exception) {
                                result.error(
                                    "play_store_unavailable",
                                    "No se pudo abrir Google Play.",
                                    error.message,
                                )
                            }
                        }
                    }
                    "openExternalUrl" -> {
                        val value = call.argument<String>("url")
                        val uri = value?.let(Uri::parse)
                        if (uri == null || uri.scheme != "https") {
                            result.error("invalid_url", "CAPC solo abre enlaces HTTPS.", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, uri)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(null)
                        } catch (error: Exception) {
                            result.error(
                                "browser_unavailable",
                                "No se pudo abrir el navegador.",
                                error.message,
                            )
                        }
                    }
                    "saveDocument" -> {
                        if (pendingResult != null) {
                            result.error(
                                "export_in_progress",
                                "Ya hay una exportación en curso.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val bytes = call.argument<ByteArray>("bytes")
                        val suggestedName = call.argument<String>("suggestedName")
                        val mimeType = call.argument<String>("mimeType")
                        if (bytes == null || suggestedName.isNullOrBlank() || mimeType.isNullOrBlank()) {
                            result.error("invalid_export", "Faltan datos para exportar.", null)
                            return@setMethodCallHandler
                        }
                        pendingBytes = bytes
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mimeType
                            putExtra(Intent.EXTRA_TITLE, suggestedName)
                        }
                        try {
                            startActivityForResult(intent, createDocumentRequest)
                        } catch (error: Exception) {
                            clearPendingExport()
                            result.error(
                                "document_picker_unavailable",
                                "Android no pudo abrir el selector de documentos.",
                                error.message,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Android, required by FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != createDocumentRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        val bytes = pendingBytes
        if (result == null || bytes == null) {
            clearPendingExport()
            return
        }
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            clearPendingExport()
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            contentResolver.openOutputStream(uri, "w")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw IOException("No se pudo abrir el documento elegido.")
            clearPendingExport()
            result.success(uri.toString())
        } catch (error: Exception) {
            clearPendingExport()
            result.error(
                "document_write_failed",
                "No se pudo guardar el documento.",
                error.message,
            )
        }
    }

    private fun clearPendingExport() {
        pendingBytes = null
        pendingResult = null
    }
}

package com.example.dosamatic_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val saveChannelName = "dosamatic/save_file"
    private val saveGcodeRequest = 4207
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, saveChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveGcode" -> {
                        if (pendingSaveResult != null) {
                            result.error("BUSY", "A save operation is already open.", null)
                            return@setMethodCallHandler
                        }

                        val fileName = call.argument<String>("fileName")
                            ?.takeIf { it.isNotBlank() }
                            ?: "dosamatic.gcode"
                        val content = call.argument<String>("content") ?: ""
                        pendingSaveResult = result
                        pendingSaveContent = content

                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }

                        try {
                            startActivityForResult(intent, saveGcodeRequest)
                        } catch (e: ActivityNotFoundException) {
                            clearPendingSave()
                            result.error("NO_PICKER", "No document picker is available.", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Android API 35, still supported by FlutterActivity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != saveGcodeRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingSaveResult
        val content = pendingSaveContent
        clearPendingSave()

        if (result == null) return
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val uri: Uri? = data?.data
        if (uri == null || content == null) {
            result.error("NO_URI", "The document picker did not return a file URI.", null)
            return
        }

        try {
            contentResolver.openOutputStream(uri, "wt")?.use { stream ->
                stream.write(content.toByteArray(Charsets.UTF_8))
                stream.flush()
            } ?: run {
                result.error("OPEN_FAILED", "Could not open the selected document.", null)
                return
            }
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("WRITE_FAILED", e.message ?: "Could not write G-code.", null)
        }
    }

    private fun clearPendingSave() {
        pendingSaveResult = null
        pendingSaveContent = null
    }
}

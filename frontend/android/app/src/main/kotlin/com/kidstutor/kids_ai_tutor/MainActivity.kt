package com.kidstutor.kids_ai_tutor

import android.accounts.AccountManager
import android.app.Activity
import android.content.Intent
import android.media.MediaPlayer
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "com.kidstutor/tts_audio"
    private val pickAccountRequestCode = 9001
    private val pickPdfRequestCode = 9002
    private var mediaPlayer: MediaPlayer? = null
    private var pendingAccountResult: MethodChannel.Result? = null
    private var pendingPdfResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playWav" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("INVALID_PATH", "Audio path is empty", null)
                            return@setMethodCallHandler
                        }
                        stopPlayer()
                        try {
                            val player = MediaPlayer()
                            mediaPlayer = player
                            player.setDataSource(path)
                            player.setOnCompletionListener {
                                stopPlayer()
                                result.success(true)
                            }
                            player.setOnErrorListener { _, what, extra ->
                                stopPlayer()
                                result.error("PLAY_ERROR", "MediaPlayer error $what/$extra", null)
                                true
                            }
                            player.prepare()
                            player.start()
                        } catch (e: Exception) {
                            stopPlayer()
                            result.error("PLAY_EXCEPTION", e.message, null)
                        }
                    }
                    "stop" -> {
                        stopPlayer()
                        result.success(true)
                    }
                    "pickGoogleAccount" -> {
                        if (pendingAccountResult != null) {
                            result.error("BUSY", "Account picker already active", null)
                            return@setMethodCallHandler
                        }
                        pendingAccountResult = result
                        try {
                            @Suppress("DEPRECATION")
                            val intent = AccountManager.newChooseAccountIntent(
                                null,
                                null,
                                arrayOf("com.google"),
                                false,
                                null,
                                null,
                                null,
                                null
                            )
                            startActivityForResult(intent, pickAccountRequestCode)
                        } catch (e: Exception) {
                            pendingAccountResult = null
                            result.error("PICKER_ERROR", e.message, null)
                        }
                    }
                    "pickPdf" -> {
                        if (pendingPdfResult != null) {
                            result.error("BUSY", "File picker already active", null)
                            return@setMethodCallHandler
                        }
                        pendingPdfResult = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/pdf"
                            }
                            startActivityForResult(intent, pickPdfRequestCode)
                        } catch (e: Exception) {
                            pendingPdfResult = null
                            result.error("PDF_PICKER_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickAccountRequestCode) {
            val res = pendingAccountResult
            pendingAccountResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val email = data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
                res?.success(email)
            } else {
                res?.success(null)
            }
            return
        }

        if (requestCode == pickPdfRequestCode) {
            val res = pendingPdfResult
            pendingPdfResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                res?.success(null)
                return
            }
            try {
                val uri = data.data!!
                val displayName = resolveDisplayName(uri) ?: "lesson_${System.currentTimeMillis()}.pdf"
                val safeName = if (displayName.lowercase().endsWith(".pdf")) displayName else "$displayName.pdf"
                val outFile = File(cacheDir, "picked_${System.currentTimeMillis()}.pdf")

                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(outFile).use { output ->
                        input.copyTo(output)
                    }
                } ?: throw IllegalStateException("Unable to read selected PDF file")

                res?.success(mapOf("name" to safeName, "path" to outFile.absolutePath))
            } catch (e: Exception) {
                res?.error("PDF_READ_ERROR", e.message, null)
            }
        }
    }

    private fun resolveDisplayName(uri: Uri): String? {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrBlank()) return name
                    }
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment
    }

    private fun stopPlayer() {
        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        mediaPlayer = null
    }

    override fun onDestroy() {
        stopPlayer()
        super.onDestroy()
    }
}
